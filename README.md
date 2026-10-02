# batch_degibbs

Batch processing scripts for Gibb's ringing removal (degibbsing) on MRI data using SLURM clusters.

Degibbsing is applied collectively per subject/session: all matching image files are concatenated with `mrcat` into a single 4D volume, degibbsed with `mrdegibbs -dimensionality 3`, and then split back into the individual volumes.

> [!NOTE] 
> Because `mrdegibbs` corrects each slice independently, a single 4D job per subject/session is sufficient (no need for per-contrast or per-part jobs).

## Important notes on degibbsing

Hints from the `mrdegibbs` documentation:

> [!WARNING]
> - Do **not** run this **before** denoising!
> - Do **not** run this **after** any kind of motion correction.
> - Only use if the data was acquired with **full k-space coverage** (no partial Fourier).

In the processing pipeline, degibbsing should be applied **before** gradient nonlinearity correction (GNLC) — "directly after it has been reconstructed by the scanner, before any interpolation of any kind has taken place". Note that the scanner itself may include gradient nonlinearity correction. "For best results, any form of filtering performed by the scanner should be disabled, whether performed in the image domain or k-space".

Degibbsing operates **per slice**: `mrdegibbs` corrects each slice independently (the development branch of MRtrix3 contains a dedicated `-dimensionality 3` version, which is used by these scripts). Because the correction is applied slice-by-slice, it is sufficient to concatenate all volumes of a subject/session into a single 4D volume and degibbs them together.

## Files

| File | Purpose |
| --- | --- |
| `call_slurm_batch_degibbs.sh` | **Main entry point.** Cycles through a BIDS-like structure and submits SLURM jobs. |
| `degibbs_slurm.sh` | The SLURM batch job that performs the actual degibbsing and splitting. |
| `config.sh` | Shared configuration (log directory, repo path) sourced by both scripts. |

## Installation / Requirements

- MRtrix3 utilities on the `PATH` (`mrcat`, `mrdegibbs`, `mrinfo`, `mrconvert`)
- FSL utilities on the `PATH`
- `jq` on the `PATH` (used to validate `PartialFourier` in JSON sidecars)
- SLURM scheduler (`sbatch`)

### MRtrix3 version

The `mrtrix 3.0.8` container is installed and can be run with `sc mrtrix 3.0.8`. It supports 2D, slice-wise degibbsing, but it does not provide the 3D functionality used by this batch workflow.

The MRtrix3 development version supports both 2D and 3D degibbsing. It must be compiled locally before it can be used. On the relevant system, build it as follows:

```bash
ssh mulde # only works on mulde!!!
git clone https://github.com/MRtrix3/mrtrix3.git
cd mrtrix3
git checkout dev
mkdir release
cd release
cmake -DMRTRIX_USE_QT5=true -DCMAKE_INSTALL_PREFIX=<sw_storage>/mrtrix3 ..
make -j5 install
```

The MRtrix command prefix and dimensionality are configured in `config.sh`. By default, the scripts use the compiled development version with `-dimensionality 3`. To use the `sc mrtrix 3.0.8` container instead, set `CONFIG_MRTRIX` to `sc mrtrix 3.0.8 ` and set `CONFIG_MRTRIX_NO_DIMENSIONALITY=true` (the dimensionality value is ignored when the no-dimensionality flag is enabled).

Optionally edit `config.sh` to change the location of the SLURM log directory
(`CONFIG_DEGIBBS_SLURM_LOG_DIR`) and the repository root (`CONFIG_REPO_DIR`).

## Required Data Structure

The scripts expect a BIDS-like layout:

```
parent_directory/
├── sub-001/
│   └── ses-01/
│       └── anat/
│           ├── sub-001_ses-01_acq-..._T1w_part-mag_MPM.nii
│           ├── sub-001_ses-01_acq-..._T1w_part-phase_MPM.nii
│           ├── sub-001_ses-01_acq-..._PDw_part-mag_MPM.nii
│           └── ...
├── sub-002/
│   └── ses-01/
│       └── anat/
│           └── ...
```

## How to Run

### Submitting jobs via SLURM

```bash
./call_slurm_batch_degibbs.sh /data/input /data/output
```

For every `sub-*/ses-*/anat` directory, **one job** is submitted. Each job:

1. Collects all image files in that anat directory whose stem contains at least one of the contrast strings given via `-c` (default `PDw,T1w,MTw`) and, if given, matches the pattern from `-p`.
2. Concatenates them into a single 4D volume (`mrcat`).
3. Degibbses the 4D volume with the configured MRtrix3 version. The development version uses `mrdegibbs -dimensionality 3` or `mrdegibbs -dimensionality 2` (see `CONFIG_MRTRIX_NO_DIMENSIONALITY`); the `sc mrtrix 3.0.8` container uses its default 2D slice-wise mode.
4. Splits it back into the individual volumes and writes them as NIfTI.

Results are written into an output directory that mirrors the BIDS hierarchy:

```
output_directory/sub-xxx/ses-xx/anat/<stem>_desc-degibbs_MPM.nii    (+ <stem>_desc-degibbs_MPM.json sidecar)
```

The filename of each output equals the input, with `_desc-degibbs` inserted directly before the suffix (mostly `_MPM`) and the `.nii` extension. Corresponding JSON sidecars are copied over when present.

### Options

| Option | Description |
| --- | --- |
| `-h`, `--help` | Print help text and exit |
| `-c STRINGS`, `--contrasts STRINGS` | Comma-separated contrast strings used to select files (default: `PDw,T1w,MTw`) |
| `-p PATTERN`, `--pattern PATTERN` | Additional glob pattern the file stem must match. Important to include wildcards. (default: `*_MPM`; pass `''` to disable) |
| `-t SECONDS`, `--delay SECONDS` | Delay between job submissions in seconds (default: `1`) |
| `-sub SUBJECTS`, `--subjects SUBJECTS` | Comma-separated list of subjects (e.g. `sub-001,sub-002`) |
| `-ses SESSIONS`, `--sessions SESSIONS` | Comma-separated list of sessions (requires `-sub`) |
| `-dep JOBID`, `--dependency JOBID` | Submit all jobs with dependency on successful completion of `JOBID` |
| `-job-name JOBNAME` | Custom job name for the submitted job (single-job submissions only) |
| `-log DIR`, `--logfiledir DIR` | Custom SLURM log output directory (include trailing slash) |
| `-pw`, `--preserve-workdir` | Preserve per-job scratch directories after processing (deleted by default) |
| `--dry-run` | Show commands that would be submitted without actually submitting jobs |

### Examples

```bash
# Process all subjects/sessions with default contrasts (PDw, T1w, MTw)
./call_slurm_batch_degibbs.sh /data/input /data/output

# Only T1w and PDw files
./call_slurm_batch_degibbs.sh -c "PDw,T1w" /data/input /data/output

# Only specific subjects
./call_slurm_batch_degibbs.sh -sub "sub-001,sub-002" /data/input /data/output

# Specific subjects and sessions
./call_slurm_batch_degibbs.sh -sub "sub-001" -ses "ses-01,ses-02" /data/input /data/output

# Dry run to preview the jobs that would be submitted
./call_slurm_batch_degibbs.sh --dry-run /data/input /data/output

# Wait for another job before starting, while preserving scratch directories
./call_slurm_batch_degibbs.sh -dep 12345 --preserve-workdir /data/input /data/output
```

> [!NOTE]
> Each job uses its own scratch directory inside the job's output directory
> (`scratch_degibbs_<pid>`). Scratch directories are removed after successful
> processing unless `--preserve-workdir` is used.

## Running a job standalone

The SLURM job itself (`degibbs_slurm.sh`) can also be run directly:

```bash
./degibbs_slurm.sh [--config <config_file>] <output_dir> <file1> <file2> ... <fileN>

# Example
./degibbs_slurm.sh /data/output/sub-001/ses-01/anat \
    /data/sub-001/ses-01/anat/*_part-mag_MPM.nii \
    /data/sub-001/ses-01/anat/*_part-phase_MPM.nii
```

When run directly from the repository, `config.sh` is used by default. Use
`--config` to provide an explicit configuration file, for example:

```bash
./degibbs_slurm.sh --config /path/to/config.sh \
    /data/output/sub-001/ses-01/anat \
    /data/sub-001/ses-01/anat/*_part-mag_MPM.nii
```

Use `--preserve-workdir` to keep the scratch directory after processing; it is
removed by default.

## Output

Degibbsed NIfTI files whose names equal the inputs with `_desc-degibbs` inserted before the suffix (e.g. `..._T1w_part-mag_MPM.nii` -> `..._T1w_part-mag_desc-degibbs_MPM.nii`), plus the corresponding JSON sidecars copied from the inputs (when present).
