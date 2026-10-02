#!/bin/bash

# Script to cycle through a BIDS-like structure and submit SLURM jobs for degibbsing MPM data.
# For each subject/session (i.e. each sub-*/ses-*/anat directory), a single job is submitted
# that concatenates all image files matching the given contrast list into one 4D volume,
# degibbses it, and splits the result back into the original volumes.

usage() {
echo \
"
$(basename $0): Automatically finds and submits SLURM jobs for degibbsing all MPM images within a BIDS-like structure.

USAGE:
    $(basename $0) [options] <parent_directory> <output_directory>

OPTIONS:
    -h | --help: print help text and exit
    -c CONTRASTS | --contrasts CONTRASTS: comma-separated list (no spaces!) of contrast strings used to select the files to process (default: PDw,T1w,MTw)
    -p PATTERN | --pattern PATTERN: additional glob pattern the file stem must match. Important to include wildcards! (default: *_MPM)
    -t SECONDS | --delay SECONDS: delay between job submissions in seconds (default: 1)
    -sub SUBJECTS | --subjects SUBJECTS: comma-separated list (no spaces!) of subjects to process (e.g., sub-001,sub-002)
    -ses SESSIONS | --sessions SESSIONS: comma-separated list (no spaces!) of sessions to process (e.g., ses-01,ses-02)
                                        Note: -ses requires -sub to be specified
    -dep JOBID | --dependency JOBID: submit all jobs with dependency on successful completion of the specified job ID
    -job-name JOBNAME: specify a custom job name for the submitted job (only valid when submitting a single job)
    -log LOGFILEDIR | --logfiledir LOGFILEDIR: specify a custom log directory for SLURM job output (make sure to include a trailing slash, e.g., /path/to/logs/)
    -pw | --preserve-workdir: preserve scratch directories after processing
    --dry-run: show commands that would be executed without actually submitting jobs


ARGUMENTS:
    parent_directory: Parent directory containing BIDS-structured data
    output_directory: Output directory for processed results

DESCRIPTION:
    The script searches for directories matching the pattern: parent_directory/sub-*/ses-*/anat/
    and submits a single SLURM job for each of these directories. For each job, all image files
    whose stem contains at least one of the given contrast strings (and, if given, matches the
    -p/--pattern glob) are degibbsed collectively: they are concatenated into one 4D volume,
    degibbsed with mrdegibbs (mrdegibbs performs 2D degibbsing per slice, no global correction 
    across all volumes within the 4D volume), and split back into the individual volumes.

    The results are written into an output directory that mirrors the BIDS structure:
    output_directory/sub-xxx/ses-xx/anat/.

    Each output NIfTI keeps its input stem with \"_desc-degibbs\" inserted directly before the
    suffix (mostly \"_MPM\") and the \".nii\" extension. Corresponding JSON sidecars are copied
    over when present.

    If -sub is specified, only processes the specified subjects. If -ses is also specified,
    only processes the specified sessions for those subjects. Without these flags, processes
    all subjects and sessions found.

EXAMPLES:
    $(basename $0) /data/input /data/output
    $(basename $0) -c \"PDw,T1w\" /data/input /data/output
    $(basename $0) -sub \"sub-001,sub-002\" /data/input /data/output
    $(basename $0) -sub \"sub-001\" -ses \"ses-01,ses-02\" /data/input /data/output
    $(basename $0) --dry-run -t 10 /data/input /data/output
    $(basename $0) -dep 12345 /data/input /data/output
    $(basename $0) -log /path/to/logs/ /data/input /data/output

AUTHOR:
    Niklas Kuegler (kuegler@cbs.mpg.de)
"
}

# Load shared config from repo root
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$repo_root/config.sh"

# Default parameters
contrasts="PDw,T1w,MTw"
pattern="*_MPM"
delay=1
dry_run=false
preserve_workdir=false
parent_dir=""
output_dir=""
subjects=""
sessions=""
dependency_job_id=""
custom_job_name=""
custom_log_dir=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--contrasts)
            contrasts="$2"
            shift 2
            ;;
        -p|--pattern)
            pattern="$2"
            shift 2
            ;;
        -t|--delay)
            delay="$2"
            shift 2
            ;;
        -sub|--subjects)
            subjects="$2"
            shift 2
            ;;
        -ses|--sessions)
            sessions="$2"
            shift 2
            ;;
        -pw|--preserve-workdir)
            preserve_workdir=true
            shift
            ;;
        -dep|--dependency)
            dependency_job_id="$2"
            shift 2
            ;;
        -job-name)
            custom_job_name="$2"
            shift 2
            ;;
        -log|--logfiledir)
            custom_log_dir="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -*)
            echo "Error: Unknown option $1"
            usage
            exit 1
            ;;
        *)
            # Accept parent_directory then output_directory
            if [[ -z "$parent_dir" ]]; then
                parent_dir="$1"
                shift
            elif [[ -z "$output_dir" ]]; then
                output_dir="$1"
                shift
            else
                echo "Error: Too many arguments specified"
                usage
                exit 1
            fi
            ;;
    esac
done

# Validation
if [[ -z "$parent_dir" ]]; then
    echo "Error: Parent directory must be specified"
    usage
    exit 1
fi

if [[ -z "$output_dir" ]]; then
    echo "Error: Output directory must be specified"
    usage
    exit 1
fi

if [[ ! -d "$parent_dir" ]]; then
    echo "Error: Parent directory does not exist: $parent_dir"
    exit 1
fi

# Validate sessions flag usage
if [[ -n "$sessions" && -z "$subjects" ]]; then
    echo "Error: -ses/--sessions flag requires -sub/--subjects to be specified"
    usage
    exit 1
fi

# Validate custom log directory if specified
if [[ -n "$custom_log_dir" ]]; then
    # Extract directory path by removing the last / and everything after it
    log_dir_path="${custom_log_dir%/*}/"
    if [[ ! -d "$log_dir_path" ]]; then
        echo "Error: Log directory does not exist: $log_dir_path"
        exit 1
    fi
fi

# Convert comma-separated contrasts to array
IFS=',' read -ra contrast_array <<< "$contrasts"

# Convert comma-separated subjects and sessions to arrays if specified
if [[ -n "$subjects" ]]; then
    IFS=',' read -ra subject_array <<< "$subjects"
else
    subject_array=()
fi

if [[ -n "$sessions" ]]; then
    IFS=',' read -ra session_array <<< "$sessions"
else
    session_array=()
fi

# Create output directory if it doesn't exist
if [[ ! -d "$output_dir" ]]; then
    echo "Creating output directory: $output_dir"
    if [[ "$dry_run" == "false" ]]; then
        mkdir -p "$output_dir"
    fi
fi

# Get the absolute path of the slurm script
slurm_script="$repo_root/degibbs_slurm.sh"

if [[ ! -f "$slurm_script" ]]; then
    echo "Error: SLURM script not found at $slurm_script"
    exit 1
fi

# Find all anat directories in the BIDS-like structure
echo "Searching for anat directories in: $parent_dir"

# Normalize parent_dir to ensure it ends with a slash for consistent path matching
parent_dir="${parent_dir%/}/"

if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Filtering for subjects: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Filtering for sessions: ${session_array[*]}"
    fi
fi

anat_dirs=()

if [[ ${#subject_array[@]} -eq 0 ]]; then
    # No subject filter - find all anat directories
    while IFS= read -r -d '' anat_dir; do
        anat_dirs+=("$anat_dir")
    done < <(find "$parent_dir" -maxdepth 3 -type d -path "${parent_dir}sub-*/ses-*/anat" -print0 2>/dev/null)
else
    # Filter by specified subjects and optionally sessions
    for subject in "${subject_array[@]}"; do
        if [[ ${#session_array[@]} -eq 0 ]]; then
            # No session filter - find all sessions for this subject
            while IFS= read -r -d '' anat_dir; do
                anat_dirs+=("$anat_dir")
            done < <(find "$parent_dir" -maxdepth 3 -type d -path "${parent_dir}${subject}/ses-*/anat" -print0 2>/dev/null)
        else
            # Filter by specific sessions for this subject
            for session in "${session_array[@]}"; do
                while IFS= read -r -d '' anat_dir; do
                    anat_dirs+=("$anat_dir")
                done < <(find "$parent_dir" -maxdepth 3 -type d -path "${parent_dir}${subject}/${session}/anat" -print0 2>/dev/null)
            done
        fi
    done
fi

if [[ ${#anat_dirs[@]} -eq 0 ]]; then
    if [[ ${#subject_array[@]} -gt 0 ]]; then
        echo "Error: No anat directories found for specified subjects/sessions"
        echo "Subjects: ${subject_array[*]}"
        if [[ ${#session_array[@]} -gt 0 ]]; then
            echo "Sessions: ${session_array[*]}"
        fi
    else
        echo "Error: No anat directories found matching pattern: */sub-*/ses-*/anat"
    fi
    echo "Please check that the parent directory contains the expected BIDS-like structure"
    exit 1
fi

echo "Found ${#anat_dirs[@]} anat directories to process"
echo "Contrasts (file filter): ${contrast_array[*]}"
echo "Pattern: ${pattern}"
echo "Scratch cleanup: $(if [[ "$preserve_workdir" == "true" ]]; then echo "DISABLED"; else echo "ENABLED"; fi)"
if [[ -n "$dependency_job_id" ]]; then
    echo "Global job dependency: $dependency_job_id"
fi
if [[ ${#subject_array[@]} -gt 0 ]]; then
    echo "Subjects filter: ${subject_array[*]}"
    if [[ ${#session_array[@]} -gt 0 ]]; then
        echo "Sessions filter: ${session_array[*]}"
    fi
fi

echo "=========================================="
echo "Directories to be processed:"
for anat_path in "${anat_dirs[@]}"; do
    if [[ $anat_path =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
        subject="${BASH_REMATCH[1]}"
        session="${BASH_REMATCH[2]}"
        echo "${subject}/${session}/anat"
    fi
done
echo "=========================================="

# Counter for job numbering
job_counter=1
total_jobs=${#anat_dirs[@]}
skipped_jobs=0

# Validate custom job name usage
if [[ -n "$custom_job_name" && $total_jobs -gt 1 ]]; then
    echo "Error: -job-name can only be used when submitting a single job"
    echo "Current configuration would submit $total_jobs jobs"
    echo "Please use subject/session filters to limit to a single job, or remove -job-name"
    exit 1
fi

for anat_path in "${anat_dirs[@]}"; do
    echo
    echo "Processing anat directory: $anat_path"

    if [[ $anat_path =~ .*(sub-[^/]+)/(ses-[^/]+)/anat.* ]]; then
        subject="${BASH_REMATCH[1]}"
        session="${BASH_REMATCH[2]}"

        # Create corresponding directory structure in output
        target_output_dir="$output_dir/$subject/$session/anat"
        if [[ "$dry_run" == "false" ]]; then
            mkdir -p "$target_output_dir"
        fi

        # Collect all image files in the anat dir whose stem contains at least one
        # contrast string and, if given, matches the pattern (deduplicated).
        declare -A seen_files
        matching_files=()
        while IFS= read -r -d '' f; do
            base_noext="$(basename "$f")"
            base_noext="${base_noext%.nii.gz}"
            base_noext="${base_noext%.nii}"

            match=false
            for contrast in "${contrast_array[@]}"; do
                if [[ "$base_noext" == *"$contrast"* ]]; then
                    match=true
                    break
                fi
            done
            [[ "$match" == "true" ]] || continue

            if [[ -n "$pattern" ]]; then
                [[ "$base_noext" == $pattern ]] || continue
            fi

            if [[ -z "${seen_files[$f]}" ]]; then
                seen_files[$f]=1
                matching_files+=("$f")
            fi
        done < <(find "$anat_path" -maxdepth 1 -type f \( -name "*.nii" -o -name "*.nii.gz" \) -print0 2>/dev/null)

        if [[ ${#matching_files[@]} -eq 0 ]]; then
            echo "  WARNING: No files matching contrasts '${contrast_array[*]}' and pattern '$pattern' found in $anat_path. Skipping."
            ((skipped_jobs++))
            ((job_counter++))
            continue
        fi

        echo "  Found ${#matching_files[@]} matching files:"
        for f in "${matching_files[@]}"; do
            echo "    - $(basename "$f")"
        done

        # Check if output files already exist for this subject/session
        existing_output=$(find "$target_output_dir" -maxdepth 1 -type f -name "*desc-degibbs*" 2>/dev/null | wc -l)
        if [[ $existing_output -gt 0 ]]; then
            echo "  INFO: Degibbsed output files already exist in $target_output_dir. Skipping."
            ((skipped_jobs++))
            ((job_counter++))
            continue
        fi

        # Prepare the sbatch argument list
        sbatch_args=(-p short,group_servers,gr_weiskopf)
        if [[ -n "$custom_job_name" ]]; then
            sbatch_args+=(--job-name="$custom_job_name")
        else
            sbatch_args+=(--job-name="degibbs_${subject}_${session}")
        fi
        if [[ -n "$custom_log_dir" ]]; then
            sbatch_args+=(-o "${custom_log_dir}%j.out")
        else
            if [[ "$dry_run" == "false" ]]; then
                mkdir -p "$CONFIG_DEGIBBS_SLURM_LOG_DIR"
            fi
            sbatch_args+=(-o "${CONFIG_DEGIBBS_SLURM_LOG_DIR}%j.out")
        fi
        if [[ -n "$dependency_job_id" ]]; then
            sbatch_args+=(--dependency="afterok:${dependency_job_id}")
        fi

        # The script and its positional arguments (output_dir + the list of files)
        if [[ "$preserve_workdir" == "true" ]]; then
            sbatch_args+=("$slurm_script" --preserve-workdir)
        else
            sbatch_args+=("$slurm_script")
        fi
        sbatch_args+=("$target_output_dir" "${matching_files[@]}")

        if [[ "$dry_run" == "false" ]]; then
            out=$(sbatch "${sbatch_args[@]}")
            echo "  $out"

            if [[ $out =~ Submitted\ batch\ job\ ([0-9]+) ]]; then
                job_id="${BASH_REMATCH[1]}"
                echo "  Job $job_id submitted for $subject/$session"
            else
                echo "  Warning: Could not extract job ID from sbatch output"
            fi

            if [[ $job_counter -lt $total_jobs ]]; then
                echo "  Waiting ${delay}s before next submission..."
                sleep "$delay"
            fi
        else
            echo "  DRY RUN: Would submit job (with $(basename "$slurm_script")):"
            echo "    sbatch ${sbatch_args[*]}"
            echo "  DRY RUN: preserve workdir=$preserve_workdir"
        fi

        ((job_counter++))
    else
        echo "Warning: Could not extract subject/session from path: $anat_path"
        echo "Skipping this directory..."
        ((skipped_jobs++))
        continue
    fi
done

echo
echo "=========================================="
echo "Batch submission completed!"
echo "Total jobs expected: $total_jobs"
echo "Jobs skipped (no matching files or output exists): $skipped_jobs"
echo "Jobs submitted: $((total_jobs - skipped_jobs))"
if [[ "$dry_run" == "false" ]]; then
    echo "Check job status with: squeue -u \$USER"
    echo "Monitor logs in: $CONFIG_DEGIBBS_SLURM_LOG_DIR"
else
    echo "This was a dry run - no jobs were actually submitted"
fi
echo "=========================================="
