######################################
# wrapper for rule: nextflow_go_run
######################################
import os
import uuid
from snakemake.shell import shell

shell.executable("/bin/bash")

pwd = os.getcwd()
log_filename = os.path.join(pwd,str(snakemake.log))

f = open(log_filename, 'wt')
f.write("\n##\n## RULE: nextflow_go_run \n##\n")
f.close()

version = str(subprocess.Popen("conda list ", shell=True, stdout=subprocess.PIPE).communicate()[0], 'utf-8')
f = open(log_filename, 'at')
f.write("## CONDA: "+version+"\n")
f.close()








command = "/storage1/shared_resources/nf/build/releases/version_v0.5/nextflow-go run nf-core/sarek -r 4bd2948 \
	-v 'pvc-beegfs:/storage2' -v 'pvc-medgen-plevova:/storage1' \
	-head-memory 4096Mi -head-cpus 1 \
	-head-image  cerit.io/nextflow/nextflow:25.10.2 \
	-w /storage2/sarek_ps3/temp \
	-c custom.config \
	-C my_nextflow.config \
	--input /storage2/sarek_ps3/samplesheets/samplesheet_mapping.csv \
	--outdir /storage2/sarek_ps3/Results_mapping_02_26_2026 \
	--genome GATK.GRCh38 \
	--step mapping \
	--trim_fastq \
	-with-report \
	-resume"

