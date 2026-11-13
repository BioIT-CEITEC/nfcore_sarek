##### nf-core/sarek: input samplesheet #####
#
# Turns the sample table the Snakefile already parsed (sample_tab = BR.load_sample(),
# i.e. config["samples"] carrying the gui_params.samples columns) into the CSV that
# nextflow-go passes to sarek through --input.
#
# Column set and order follow sarek's own samplesheets (assets/schema_input.json and
# tests/csv/3.0/*.csv upstream): patient, sex, status, sample, lane, fastq_1, fastq_2.
# Nothing else is written - sarek's samplesheet checks only know these columns, and the
# shell_scripts/samplesheet_align_test.csv form that runs on the cluster is a subset of them.

from snakemake.exceptions import WorkflowError

SAREK_SHEET_COLUMNS = ["patient", "sex", "status", "sample", "lane", "fastq_1", "fastq_2"]

# gui_params.samples submits the enum keys: sex = NA|XX|XY, status = 0|1 (labels are the
# human-readable NA|female|male and normal|tumor, which are accepted here as well).
SAREK_SEX_VALUES = ["NA", "XX", "XY"]
SAREK_STATUS_VALUES = {"0": 0, "1": 1, "normal": 0, "tumor": 1}


def sarek_field(row, key, default = ""):
    """One per-sample value from sample_tab; missing, blank or NaN falls back to default."""
    if key not in sample_tab.columns:
        return default
    value = row[key]
    if pd.isna(value) or not str(value).strip():
        return default
    return str(value).strip()


def sarek_fastq_paths(sample_name):
    """FASTQs as staged by the platform, relative to the workflow directory."""
    fastq_dir = config.get("fastq_dir", "raw_fastq")
    return [fastq_dir + "/" + sample_name + tag + ".fastq.gz" for tag in pair_tag]


def sarek_input_prefix():
    """
    Prefix put in front of every FASTQ path written into the samplesheet.

    sarek validates that these paths exist *from the Nextflow head pod*, not from here, so
    they must be reachable on the cluster. Set "sarek_input_prefix" in config.json to this
    task directory as seen on the PVCs (e.g. /storage2/<task>); without it the prefix is the
    absolute local workflow directory, which is only correct when the very same path exists
    on the cluster.
    """
    prefix = config.get("sarek_input_prefix")
    if prefix:
        return str(prefix).rstrip("/")
    return os.path.abspath(workflow.basedir)


def sarek_input_path(relative_path):
    return sarek_input_prefix() + "/" + relative_path


def sarek_sheet_rows():
    if config.get("step", "mapping") != "mapping":
        raise WorkflowError(
            "prepare_samplesheet only writes FASTQ samplesheets, but step is '{}'. Steps after "
            "mapping take aligned files (table/cram/crai/bam/bai) or VCFs instead of fastq_1/fastq_2 - "
            "until that variant is implemented here, sarek's own samplesheet from the previous run "
            "(<outdir>/csv/recalibrated.csv or <outdir>/csv/variantcalled.csv) can be passed through "
            "as --input.".format(config.get("step", "mapping")))

    if paired != "PE":
        raise WorkflowError(
            "sarek only takes paired FASTQ input: rows without fastq_2 fall through its "
            "samplesheet_to_channel check with 'Missing or unknown field in csv file header'. "
            "Single-end data has to be handed over as BAM/CRAM (step != mapping) or a decision on "
            "SE support has to be taken here.")

    rows = []
    for entity_name, row in sample_tab.iterrows():
        sample_name = sarek_field(row, "sample_name")
        patient = sarek_field(row, "patient", sample_name)
        # patient and sample are validated against ^\S+$ by sarek
        for value, key in [(sample_name, "sample_name"), (patient, "patient")]:
            if not value or value.split() != [value]:
                raise WorkflowError(
                    "Sample '{}': '{}' ('{}') must be a single word - sarek rejects patient and "
                    "sample IDs containing spaces.".format(entity_name, value, key))

        status = sarek_field(row, "status", "0")
        if status not in SAREK_STATUS_VALUES:
            raise WorkflowError("Sample '{}': status must be 0 (normal) or 1 (tumor), got '{}'.".format(sample_name, status))
        sex = sarek_field(row, "sex", "NA")
        if sex not in SAREK_SEX_VALUES:
            raise WorkflowError("Sample '{}': sex must be one of {}, got '{}'.".format(sample_name, SAREK_SEX_VALUES, sex))

        fastqs = sarek_fastq_paths(sample_name)
        rows.append({
            "patient": patient,
            "sex": sex,
            "status": SAREK_STATUS_VALUES[status],
            "sample": sample_name,
            # used by sarek in the read group and in the {sample}-{lane} id; one lane per
            # sample here, since config["samples"] holds one entry per sample
            "lane": sarek_field(row, "lane", "1"),
            "fastq_1": sarek_input_path(fastqs[0]),
            "fastq_2": sarek_input_path(fastqs[1]),
        })

    # Both of these abort sarek with a message pointing at the samplesheet; they are config
    # mistakes, so failing here is cheaper than failing on the cluster.
    seen = set()
    for row in rows:
        entry = (row["patient"], row["sample"], row["status"], row["lane"])
        if entry in seen:
            raise WorkflowError("Duplicate patient/sample/status/lane combination: {}/{}/{}/{}.".format(*entry))
        seen.add(entry)

    patients = {}
    for row in rows:
        patients.setdefault(row["sample"], set()).add(row["patient"])
    shared = sorted(sample for sample, owners in patients.items() if len(owners) > 1)
    if shared:
        raise WorkflowError("Sample id(s) used by more than one patient: {}. Sample ids must be unique per patient.".format(", ".join(shared)))

    return rows


def prepare_samplesheet_input(wildcards):
    """Staged FASTQs as dependencies, so a missing input is reported by Snakemake instead of sarek."""
    return [path for sample_name in sample_tab.sample_name for path in sarek_fastq_paths(sample_name)]


rule prepare_samplesheet:

    input:  prepare_samplesheet_input
    output: csv = "samplesheet.csv"
    log:    "logs/all_samples/prepare_samplesheet.log"
    params: step = config.get("step", "mapping"),
            prefix = sarek_input_prefix()
    run:
        rows = sarek_sheet_rows()
        lines = [",".join(SAREK_SHEET_COLUMNS)]
        lines += [",".join(str(row[column]) for column in SAREK_SHEET_COLUMNS) for row in rows]
        sheet = "\n".join(lines) + "\n"

        # line endings forced to LF: this file is parsed by Nextflow on Linux and a trailing
        # \r would end up inside the last path (fastq_2)
        with open(snakemake.output.csv, "w", newline = "\n") as handle:
            handle.write(sheet)

        with open(snakemake.log[0], "w") as handle:
            handle.write("step: {}\n".format(snakemake.params.step))
            handle.write("paths prefixed with: {}\n\n".format(snakemake.params.prefix))
            handle.write(sheet)
