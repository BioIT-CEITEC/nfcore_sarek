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

command = snakemake.params.nfgo_bin + " run nf-core/sarek -r " + snakemake.params.sarek_version + " \
	-v 'pvc-scratch:/mnt/data/scratch' \
	-head-memory 4096Mi -head-cpus 1 \
	-head-image  cerit.io/nextflow/nextflow:25.10.2 \
	-w /mnt/data/scratch/temp \
	-c " + snakemake.input.sarek_conf + " \
	-C " + snakemake.input.nfgo_conf + " \
	-params-file " + snakemake.input.parameter + " \
	-with-report \
	-resume"

f = open(log_filename, 'at')
f.write("## COMMAND: "+command+"\n")
f.close()
shell(command)