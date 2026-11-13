# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **BioRoots Snakemake workflow that wraps `nf-core/sarek`**. Snakemake handles samples, references,
and output collection; the heavy lifting is delegated to the Nextflow pipeline, launched with
[nextflow-go](https://github.com/CERIT-SC/nextflow-go) on the CERIT-SC Kubernetes cluster. The wrapper
exists so sarek can be offered through the BioRoots GUI/platform like every other workflow in the family.

**Current state: scaffold, not a working pipeline.**

- [Snakefile](Snakefile) is a verbatim copy of `../alignment_dna/Snakefile` (only the MultiQC target path differs),
  so `rule all` still asks for alignment outputs (`mapped/{sample}.bam`, `mapped/{sample}.bam.bai`, `multiqc/multiqc_report.html`).
- Its `include` of `rules/alignment_DNA.smk` (**no such file in this repo**) is commented out; the sarek rule file is included instead.
- [rules/nextflow-go-sarek.smk](rules/nextflow-go-sarek.smk) has `prepare_samplesheet`, which renders `config["samples"]`
  into sarek's `--input` CSV (see "Building the samplesheet" below). It is not in `rule all` yet — build it with
  `snakemake ... samplesheet.csv`.
- `wrappers/` is empty.

The work is to replace the copied DNA-alignment rule set with sarek rules: build a sarek samplesheet from
`config["samples"]`, invoke `nextflow-go` per pipeline step, and wire sarek's `--outdir` back into Snakemake outputs.

## Commands

```bash
# Dry run / inspect (config.json is NOT committed — see "Two config layers")
snakemake --snakefile Snakefile --configfile config.json --cores 1 --dryrun
snakemake --configfile config.json --list-targets

# Run
snakemake --snakefile Snakefile --configfile config.json --cores <N>
snakemake --configfile config.json <specific/output/path>   # build one target
```

Requires Snakemake >= 5.18.0 (`min_version` in the Snakefile) and conda. The `module ...: snakefile: github(...)`
blocks are fetched from GitHub at parse time, so DAG resolution needs network access.

Manual sarek runs (the reference implementation for what the rules must do) are launched from inside
`shell_scripts/`, e.g. `bash run_mapp.sh` — that directory must contain the configs the script references.

## Two config layers — understand this before touching anything

**[workflow.config.json](workflow.config.json) is the GUI schema. Snakemake never reads it.** It is consumed by
the BioRoots GUI/launcher, which renders a form from it and emits the runtime `config.json`.

- `workflow_description` — `inputs` glob, `outputs` patterns (`{sample}` templates), `report_index`, `reports`.
  These are a **contract with the platform**: the collector and the report link look for exactly these paths, so
  retargeting an output in a rule without updating this block silently breaks result delivery.
- `general_params` — columns every sample row carries (`entity_name`, `sample_name`).
- `requested_params` — workflow-level values the launcher must provide (`is_paired`).
- `gui_params.primary` / `.detailed` / `.samples` — become **top-level keys** in runtime `config.json`
  (primary = shown first, detailed = advanced, samples = per-sample columns that map onto the sarek
  samplesheet: `patient`, `sex`, `status`, `lane`).
- Param keys are intentionally named after sarek CLI flags (`step`, `trim_fastq`, `split_fastq`, `intervals`,
  `tools`, `wes`, `nucleotides_per_second`, …) and the `info` strings are copied from the sarek 3.8.1 docs —
  keep that 1:1 correspondence when adding a parameter, since config key → `--flag` is meant to be mechanical.
  `type` is one of `enum|int|string|bool`; `dynamicEnumName` (`organism`, `assembly`, `lib_ROI`) is resolved by
  the GUI from the reference metadata under `globalResources`, and `filters` chains those dropdowns together.

**`config.json` is runtime-only and untracked** (produced per task by the platform). Expect keys such as
`samples` (dict keyed by entity id, each with `sample_name` plus per-sample params), `globalResources`,
`globalTmpdPath`, `computing_type` (`local` | `kubernetes`), `is_paired`, `organism`/`assembly`/`reference`/`lib_ROI`,
and every `gui_params` key flattened at the top level. A sibling workflow's `config.json` is the best template.

## BioRoots utility modules

`BR` and `PR` are Snakemake modules pulled from `BioIT-CEITEC/bioroots_utilities@master`
(local checkout for reading: `../bioroots_utilities`). `use rule * from BR as other_*` is the house
convention for keeping imported rule names from colliding with local ones — don't drop the prefix.

- `BR.load_sample()` → DataFrame from `config["samples"]`, indexed by entity id. `sample_tab.sample_name`
  feeds every `expand()` and the `sample` wildcard constraint in the Snakefile.
- `BR.set_read_pair_qc_tags()` / `set_read_pair_tags()` / `set_paired_tags()` → the SE-vs-PE tag triples
  (`["SE"]`/`["R1","R2"]`, `[""]`/`["_R1","_R2"]`, `"SE"`/`"PE"`). They must stay consistent with each other.
- `BR.load_organism()` returns a **mutated global `config`** (`config = BR.load_organism()` in the Snakefile)
  populated with `organism_*` paths resolved from `globalResources/reference_info/{reference2.json, kegg_reference.json,
  organism_tab.tsv, lib_ROI.json}`. It supports two on-disk reference layouts selected by `check_resources()`:
  `bioda` (`…/references_backup`, files under `{organism}/{reference}/{index,other,annot}`) and
  `bioit` (`…/resources`, files under `references/{organism}/{assembly}/{seq,annot,tool_data,others}`).

This matters specifically for sarek: BioRoots hands you `organism_fasta`, `organism_dict`, `organism_chr_sizes`,
`organism_dna_panel`, while sarek wants `--genome` / `--igenomes_base` in iGenomes layout. Translating between the
two (or pre-staging an iGenomes-shaped directory and using `--igenomes_base`, or `--igenomes_ignore` + explicit
FASTA) is a design decision the sarek rules have to make.

## How sarek is driven

`shell_scripts/` is **gitignored** but is the proven record of real invocations — treat it as the spec:

| Script | `--step` | Notable flags |
| --- | --- | --- |
| `run_mapp.sh` | `mapping` | `--trim_fastq`, input = FASTQ samplesheet |
| `run_varcall.sh` | `variant_calling` | `--only_paired_variant_calling`, `--normalize_vcfs`, `--tools freebayes,mutect2,strelka,manta` |
| `run_annot.sh` | `annotate` | `--tools vep`, `--vep_cache <path>`, `-params-file params.yml` |

Shared invocation shape: `nextflow-go run nf-core/sarek -r <pinned commit> -v <pvc>:<mount> -head-* -w <shared work dir>
-c custom.config -C my_nextflow.config --input <csv> --outdir <dir> --genome GATK.GRCh38 --step <step> -with-report -resume`.

- **Three sequential steps** — `mapping` → `variant_calling` → `annotate` — each started from the samplesheet the
  previous step published under `<outdir>/csv/` (`recalibrated.csv`, `variantcalled.csv`). Pipeline stages chain
  through sarek's own CSVs, so the Snakemake rules map one-to-one onto sarek steps and `-resume` in a shared work
  directory does the caching *within* a step.
- `-r` pins a commit; the note in `shell_scripts/sarek_k8s.md` is explicit that `main`/`master` should be avoided.
- `my_nextflow.config` = k8s execution context (namespace, PVCs, `workDir`/`launchDir`/`projectDir`, `executor.queueSize`,
  per-process CPU/memory overrides scaled by `task.attempt`). `custom.config` = per-tool arguments targeted by full
  process names (`NFCORE_SAREK:SAREK:BAM_VARIANT_CALLING_SOMATIC_ALL:…:FREEBAYES`, `VCFS_NORM`). `-params-file` carries
  nested VEP settings.
- Outputs land one directory per stage (`preprocessing/`, `variant_calling/<caller>/`, `annotation/`, `reports/`,
  `multiqc/`, `pipeline_info/`), split by tool then by sample or by `tumor_vs_normal` pair.
- sarek samplesheet header: `patient,sample,lane,fastq_1,fastq_2` (see `shell_scripts/samplesheet_align_test.csv`,
  a tumor/normal pair under one `patient`). `status` (0 = normal, 1 = tumor) is what drives paired somatic calling.

## Building the samplesheet (`prepare_samplesheet`)

Renders `sample_tab` (pandas frame of `config["samples"]` from the Snakefile) into `samplesheet.csv`. Column set and
order are sarek's own — no others are written:

| sarek column | source | notes |
| --- | --- | --- |
| `patient` | per-sample `patient`, falls back to `sample_name` | groups a patient's tumor + normal; `^\S+$` |
| `sex` | per-sample `sex` | `XX`/`XY`/`NA`; must be real for ascat, controlfreec, varlociraptor |
| `status` | per-sample `status` | **integer** 0 = normal, 1 = tumor, default 0 |
| `sample` | `sample_name` | `^\S+$`, must belong to exactly one patient |
| `lane` | per-sample `lane`, default `1` | one entry per sample here; feeds sarek's `{sample}-{lane}` id and the read group |
| `fastq_1`, `fastq_2` | `{fastq_dir}/{sample_name}{_R1,_R2}.fastq.gz` | `fastq_dir` config key, default `raw_fastq` |

- FASTQ paths are prefixed with `sarek_input_prefix`, because sarek checks that they **exist from the Nextflow head
  pod**; unset, it falls back to the absolute local workflow dir (only right when the path matches on the cluster).
- FASTQs are declared as rule `input:` so a missing staged file is reported by Snakemake rather than by sarek.
- Refuses (with a reason) anything sarek would reject later on the cluster: `step != mapping`, single-end input
  (rows without `fastq_2` die in `samplesheet_to_channel`), spaces in `patient`/`sample`, duplicate
  patient/sample/status/lane rows, one sample id under two patients.
- Written with LF endings — a `\r` would land inside the last path when Nextflow parses it on Linux.

## Constraints that will bite

- **sarek 3.8.1 cannot save BAM** (`--save_output_as_bam` is broken), so alignment output is CRAM — while `rule all`
  currently requests `.bam` + `.bam.bai`. Either convert CRAM→BAM in a rule or retarget `rule all` and `workflow_description.outputs`.
- `sarek_k8s.md` warns that defining `pod` in `nextflow.config` overrides the launcher's k8s setup and breaks runs on
  Kubernetes — yet `shell_scripts/my_nextflow.config` still carries a `pod` entry for an extra PVC. Verify current
  behavior before copying that config as a template.
- `--genome GATK.GRCh38` lazily downloads references from AWS iGenomes on first use; for repeated runs, pre-stage the
  iGenomes tree and point at it with `--igenomes_base`.
- `/storage1`, `/storage2`, `/storage3` (and the sample FASTQ paths in `sarek_k8s.md` / the samplesheets) are
  cluster-side PVC mounts — unreachable from a workstation, so paths in these scripts are data, not testable inputs.

## Repo family

Siblings under the parent directory share this layout (`Snakefile` + `workflow.config.json` + `rules/*.smk` +
`wrappers/<step>/env.yaml` + wrapper script) and the same conventions:

- `../bioroots_utilities` — source of the `BR`/`PR` modules; read it rather than guessing the API.
- `e:\github\nf-core\sarek` — local clone of the pipeline itself (master / post-3.10, **newer than the commit the
  cluster pins**), with its own `CLAUDE.md`. Authoritative for samplesheet columns (`assets/schema_input.json`) and
  for what each `--step` accepts (`subworkflows/local/samplesheet_to_channel/main.nf`) — read it instead of assuming,
  but mind the version skew.
- `../alignment_dna` — where this Snakefile was copied from, and home of the `rules/alignment_DNA.smk` it used to include.
- Others: `alignment_rna`, `alignment_qc`, `raw_fastq_qc`, `processed_fastq_qc`, `count_feature_rna`,
  `differential_expression`, `enrichment_and_gsea`, `demultiplexing_short_read`. Several carry their own `AGENT.md`
  describing the same house patterns (per-step conda envs, `unpack()` + input factory functions for optional inputs,
  rules gated on `config` flags).
