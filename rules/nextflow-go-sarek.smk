# ###################################
# NEXTFLOW-GO SAREK RULES
#
rule nextflow_go_run:
  input: sheet = "samplesheet.csv",
         c2 = expand("singleCell_fastq/{lib}/{lib}_S{num}_L001_R2_001.fastq.gz", zip,  lib=LIBS, num=NUMS),
         tar = config["tool_dir"] + "/cellranger/cellranger-" + config['cellranger_version']+ ".tar.gz"
  output: "cell_ranger/outs/web_summary.html"
  params: sample = SAMPLES,
          libraries = config["entity_name"]+".lib.csv",
          wdir = GLOBAL_TMPD_PATH,
          outdir = "cell_ranger",
          bin_path = os.path.join(GLOBAL_REF_PATH + "resources","tools","nextflow-go","v0.6","bin","nextflow-go"),
          feature_ref_dir = config["tool_dir"] + "/cellranger/feature_ref_files",
          sc_hashtags = config["sc_hashtags"],
          library_types_dict = library_types_dict,
          transcriptome = config["organism_transcriptome"], #defined in bioroots utilities
  log:   "logs/all_samples/nextflow_go_run.log",
  threads: 40
  resources: mem = 100
  conda:   "../wrappers/nextflow_go_run/env.yaml"
  script:  "../wrappers/nextflow_go_run/script.py"