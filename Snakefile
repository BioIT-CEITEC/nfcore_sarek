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


wildcard_constraints:
    sample = "|".join(sample_tab.sample_name),
    read_pair_tag = "(_R.)?"


##### Prepare params.yaml #####

PARAMS_PATH = "params.yaml"
# The GUI schema doubles as the list of sarek flags and their default values. Relative, like the other
# files this Snakefile writes and reads; overridable when the launcher runs from elsewhere.
WORKFLOW_CONFIG_PATH = config.get("workflow_config", "workflow.config.json")
# .samples is left out: those columns are per-sample and go to the samplesheet instead.
PARAM_SECTIONS = ["primary", "detailed"]
# Keys the launcher needs but sarek does not: sarek_version pins the revision for nextflow-go,
# organism/assembly pick the reference (sarek gets --genome / fasta paths in the rule), and
# lib_ROI only names a target BED, turned into `intervals` below.
NOT_SAREK_PARAMS = ["sarek_version", "organism", "assembly", "lib_ROI"]

with open(WORKFLOW_CONFIG_PATH) as workflow_config:
    GUI_PARAMS = json.load(workflow_config)["gui_params"]


def param_value(key, spec):
    """One param's value: the task config.json value when the GUI set it, else the schema default."""
    value = config[key] if key in config and config[key] is not None else spec.get("default")
    if value is None or (isinstance(value, str) and value.strip() == ""):
        return None  # neither chosen nor defaulted: leave it out and let sarek use its own value
    # Entries without a declared type keep the JSON type the value already has ("str" falls through below).
    param_type = spec.get("type") or type(value).__name__
    if param_type == "bool":  # the GUI may send "true"/"1", nextflow wants a real bool
        return str(value).strip().lower() in ["true", "1", "yes", "on"]
    if param_type == "int":
        return int(float(value))
    return str(value).strip()


def sarek_params():
    """{param: value} for -params-file; keys keep the sarek flag names workflow.config.json gives them."""
    params = {}
    for section in PARAM_SECTIONS:
        for key, spec in GUI_PARAMS[section].items():
            if key in NOT_SAREK_PARAMS:
                continue
            value = param_value(key, spec)
            if value is not None:
                params[key] = value

    # lib_ROI is the GUI's name for a panel/WES BED; sarek wants the BED itself in `intervals`, plus
    # `wes` so the targeted sequencing flags are set. Only BioRoots knows the path (load_organism above).
    dna_panel = config.get("organism_dna_panel")
    if dna_panel:
        params.setdefault("intervals", dna_panel)  # an explicit `intervals` from the GUI wins
        params["wes"] = True
    return params


def yaml_value(value):
    """One YAML scalar: bools and ints bare, everything else quoted so paths and commas stay data."""
    if isinstance(value, bool):  # before int, bool is an int in python
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_params(path = PARAMS_PATH):
    """Renders sarek_params() into the YAML handed to nextflow-go's -params-file."""
    params = sarek_params()
    # newline="" keeps LF endings, as in the samplesheet: the file is read on the cluster.
    with open(path, "w", newline="") as params_file:
        params_file.write("# Generated by the Snakefile from workflow.config.json + config.json, do not edit.\n")
        for section in PARAM_SECTIONS:
            keys = [key for key in GUI_PARAMS[section] if key in params]
            if keys:
                params_file.write("\n# " + section + "\n")
                params_file.writelines(key + ": " + yaml_value(params[key]) + "\n" for key in keys)
    print("wrote " + path + " with " + str(len(params)) + " parameters")


write_params()


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