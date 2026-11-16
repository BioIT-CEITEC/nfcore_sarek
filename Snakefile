import os
import pandas as pd
import json
from snakemake.utils import min_version

min_version("5.18.0")
configfile: "config.json"

GLOBAL_REF_PATH = config["globalResources"]
GLOBAL_TMPD_PATH = config["globalTmpdPath"]

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
FASTQ_DIR = config.get("fastq_dir", "raw_fastq")


def samplesheet_value(row, column):
    """One field of one sample_tab row, as a string ready for the CSV."""
    sample_name = str(row["sample_name"])

    if column == "sample":
        return sample_name

    if column in ("fastq_1", "fastq_2"):  # "/" always: the CSV is read on the cluster, not here
        if column == "fastq_1":
            return FASTQ_DIR + "/" + sample_name + pair_tag[0] + ".fastq.gz"
        if len(pair_tag) == 1:  # single end, fastq_2 has to stay empty
            return ""
        return FASTQ_DIR + "/" + sample_name + pair_tag[1] + ".fastq.gz"

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


##### Target rules #####
rule all:
    input:  expand("mapped/{sample}.bam",sample = sample_tab.sample_name),
            expand("mapped/{sample}.bam.bai", sample = sample_tab.sample_name),
            "multiqc/multiqc_report.html"

##### Modules #####

include: "rules/nextflow-go-sarek.smk"

# Left over from the alignment_dna workflow this Snakefile was copied from; the rule file
# is not part of this repository, so sarek rules replace it.
#include: "rules/alignment_DNA.smk"

##### BioRoot utilities - prepare reference #####
module PR:
    snakefile: github("BioIT-CEITEC/bioroots_utilities", path="prepare_reference.smk",branch="master")
    config: config

use rule * from PR as other_*