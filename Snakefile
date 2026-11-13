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

wildcard_constraints:
    sample = "|".join(sample_tab.sample_name),
    read_pair_tag = "(_R.)?"


##### Target rules #####
rule all:
    input:  expand("mapped/{sample}.bam",sample = sample_tab.sample_name),
            expand("mapped/{sample}.bam.bai", sample = sample_tab.sample_name),
            "qc_reports/all_samples/alignment_DNA_multiqc/multiqc.html"

##### Modules #####

include: "rules/alignment_DNA.smk"

##### BioRoot utilities - prepare reference #####
module PR:
    snakefile: github("BioIT-CEITEC/bioroots_utilities", path="prepare_reference.smk",branch="master")
    config: config

use rule * from PR as other_*