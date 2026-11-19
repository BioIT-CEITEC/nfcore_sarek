import os
import pandas as pd
import json
from snakemake.utils import min_version

min_version("5.18.0")
configfile: "config.json"

GLOBAL_REF_PATH = config["globalResources"]
GLOBAL_TMPD_PATH = config["globalTmpdPath"]
# The task directory: where this Snakefile lives. workflow.basedir would be where snakemake was
# started from instead, which is not the same thing when the launcher runs it from elsewhere.
WORKDIR = os.path.abspath(os.path.dirname(workflow.snakefile))

os.makedirs(GLOBAL_TMPD_PATH, exist_ok=True)

##### BioRoot utilities #####
module BR:
    snakefile: github("BioIT-CEITEC/bioroots_utilities", path="bioroots_utilities.smk",branch="master")
    config: config

use rule * from BR as other_*

##### Config processing #####

sample_tab = BR.load_sample()

read_pair_tags = BR.set_read_pair_qc_tags() # ["SE"] / ["R1", "R2]
pair_tag = BR.set_read_pair_tags() # [""] / ["_R1", "_R2"]
paired = BR.set_paired_tags() # "SE" / "PE"

config = BR.load_organism()

##### Prepare samplesheet #####

SAMPLESHEET_PATH = "samplesheet.csv"
# sarek's own column set and order (sarek assets/schema_input.json)
SAMPLESHEET_COLUMNS = ["patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"]
FASTQ_DIR = os.path.join(WORKDIR, "raw_fastq")  # the staged FASTQs sit next to this Snakefile


def samplesheet_value(row, column):
    """One field of one sample_tab row, as a string ready for the CSV."""
    sample_name = str(row["sample_name"])

    if column == "sample":
        return sample_name

    if column in ("fastq_1", "fastq_2"):  # os.path separators, so render this on Linux: the CSV is read on the cluster
        if column == "fastq_1":
            return os.path.join(FASTQ_DIR, sample_name + pair_tag[0] + ".fastq.gz")
        if len(pair_tag) == 1:  # single end, fastq_2 has to stay empty
            return ""
        return os.path.join(FASTQ_DIR, sample_name + pair_tag[1] + ".fastq.gz")

    value = row.get(column)
    if pd.isna(value) or str(value).strip() == "":
        # Columns sample_tab may not carry at all; the defaults sarek itself falls back to.
        return {"patient": sample_name, "sex": "NA", "status": "0", "lane": "lane_1"}[column]
    if column == "status":  # the integer 0 = normal / 1 = tumor sarek expects
        return str(int(float(value)))
    return str(value)


def write_samplesheet(path = SAMPLESHEET_PATH):
    """Renders sample_tab into the CSV handed to sarek's --input, one row per sample."""
    # newline="" keeps LF endings: a \r would be read as part of the last fastq path on the cluster.
    with open(path, "w", newline="") as samplesheet:
        samplesheet.write(",".join(SAMPLESHEET_COLUMNS) + "\n")
        for _, row in sample_tab.iterrows():
            samplesheet.write(",".join(samplesheet_value(row, column) for column in SAMPLESHEET_COLUMNS) + "\n")
    print("wrote " + path + " for " + ", ".join(sample_tab.sample_name))


write_samplesheet()

##### Prepare missing parameters #####

config["input"] = os.path.join(WORKDIR,"samplesheet.csv")
config["output"] = os.path.join(WORKDIR,"sarek_output")
if not config["use_igenome"]:
    config["fasta"] = config["organism_fasta"]
    config["fasta_fai"] = config["organism_fasta"] + ".fai"
    config["genome"] = ""



##### Prepare params.yaml #####

PARAMS_PATH = "params.yaml"
# params.yaml comes straight out of the task config.json: the launcher flattens gui_params.primary + .detailed
# into it, so config already holds every sarek flag, in schema order, in its schema's JSON type. Everything the
# GUI did not put there has to be named to be left out — config carries the launcher's own bookkeeping and,
# after BR.load_organism() above, the reference paths on top of the parameters. A key the launcher starts
# sending later ends up in params.yaml until it is listed below; Nextflow only warns about params no process
# reads, so the symptom is a cluttered -params-file, not a failed run.
NOT_SAREK_PARAMS = [
    # The launcher's bookkeeping; the samples go to samplesheet.csv instead.
    "task_name", "entity_name", "is_paired", "samples", "sarek_input_prefix",
    # Reference choice: sarek_version pins the revision for nextflow-go, organism/assembly pick the reference
    # (sarek gets --genome / fasta paths in the rule), lib_ROI only names a target BED, turned into `intervals` below.
    "sarek_version", "organism", "assembly", "lib_ROI",
    # Cluster plumbing, and the credentials: a stray key here just shows up quoted in sarek's own pipeline report.
    "globalResources", "globalTmpdPath", "globalTaskPath", "computing_type",
    "Filesender_credential_file", "S3_credential_file", "aws_id", "aws_key",
    # BioRoots' own lookups; the organism_* reference paths are caught by prefix below.
    "reference", "reference_dir", "species_name", "species", "release", "material", "tooldir",
]
# BR.load_organism()'s reference paths. The rule passes on to sarek the few it actually asked for, explicitly.
NOT_SAREK_PREFIXES = ("organism_",)


def is_sarek_param(key, value):
    """False for the keys config carries on top of the sarek flags, listed above."""
    if key in NOT_SAREK_PARAMS or key.startswith(NOT_SAREK_PREFIXES):
        return False
    return not isinstance(value, (dict, list, tuple))  # nothing nested is a sarek flag


def param_value(value):
    """One param's value as config gives it: only empties need weeding, the GUI sends the schema's JSON type."""
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return None  # unset: leave it out and let sarek use its own value
    if isinstance(value, bool):  # before int, bool is an int in python
        return value
    if isinstance(value, (int, float)):
        return value
    return str(value).strip()


def sarek_params():
    """{param: value} for -params-file; keys, order and types are config's, which are the GUI schema's."""
    params = {}
    for key, value in config.items():
        if not is_sarek_param(key, value):
            continue
        value = param_value(value)
        if value is not None:
            params[key] = value

    # lib_ROI is the GUI's name for a panel/WES BED; sarek wants the BED itself in `intervals`, plus
    # `wes` so the targeted sequencing flags are set. Only BioRoots knows the path (load_organism above).
    # Check the value, not just the key: load_organism builds a DNA_ROI/<lib_ROI>/ path for any lib_ROI, and
    # "wgs" names no panel — pointing sarek at that BED would run a WGS sample as a targeted one.
    dna_panel = config.get("organism_dna_panel")
    if dna_panel and config.get("lib_ROI") not in (None, "", "wgs"):
        params.setdefault("intervals", dna_panel)  # an explicit `intervals` from the GUI wins
        params["wes"] = True
    return params


def yaml_value(value):
    """One YAML scalar: bools and numbers bare, everything else quoted so paths and commas stay data."""
    if isinstance(value, bool):  # before int, bool is an int in python
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_params(path = PARAMS_PATH):
    """Renders sarek_params() into the YAML handed to nextflow-go's -params-file, in config's own order."""
    params = sarek_params()
    # newline="" keeps LF endings, as in the samplesheet: the file is read on the cluster.
    with open(path, "w", newline="") as params_file:
        params_file.write("# Generated by the Snakefile from config.json, do not edit.\n")
        params_file.writelines(key + ": " + yaml_value(params[key]) + "\n" for key in params)
    print("wrote " + path + " with " + str(len(params)) + " parameters")


write_params()

##### Wildcards #####

wildcard_constraints:
    sample = "|".join(sample_tab.sample_name),
    read_pair_tag = "(_R.)?"

##### Target rules #####
rule all:
    input:  "sarek_output/pipeline_info/pipeline_report.html",
            "sarek_output/pipeline_info/pipeline_report.txt",
            "sarek_output/pipeline_info/software_versions.yml",
            "sarek_output/multiqc/multiqc_report.html"

##### Modules #####

include: "rules/nextflow-go-sarek.smk"

##### BioRoot utilities - prepare reference #####
module PR:
    snakefile: github("BioIT-CEITEC/bioroots_utilities", path="prepare_reference.smk",branch="master")
    config: config

use rule * from PR as prepref_*