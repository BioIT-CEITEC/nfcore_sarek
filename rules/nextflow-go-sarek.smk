# ###################################
# NEXTFLOW-GO SAREK RULES
#
rule nextflow_go_run:
  input: sheet = "samplesheet.csv",
         parameter = "params.yaml",
         sarek_process_conf = "sarek_conf.config",
         nextflowgo_conf = "nfgo_conf.config"
  output: report_html = "sarek_output/pipeline_info/pipeline_report.html",
          report_txt = "sarek_output/pipeline_info/pipeline_report.txt",
          software_version = "sarek_output/pipeline_info/software_versions.yml",
          multiqc_file =  "sarek_output/multiqc/multiqc_report.html"
  params: sarek_version = config["sarek_version"]
  log:   "logs/all_samples/nextflow_go_run.log",
  threads: 1
  resources: mem = 2
  conda:   "../wrappers/nextflow_go_run/env.yaml"
  script:  "../wrappers/nextflow_go_run/script.py"