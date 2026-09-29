#!/bin/bash
# degibbs_slurm.sh: SLURM batch job that concatenates all image files of a
# subject/session into a single 4D volume, degibbses it, and splits the result
# back into the individual (3D) volumes, storing them as NIfTI files.
#
# This script is normally submitted via call_slurm_batch_degibbs.sh, but it can
# also be run directly (see USAGE below).
#
# USAGE (arguments passed to the SLURM job):
#   degibbs_slurm.sh <output_dir> <file1> <file2> ... <fileN>
#
# ARGUMENTS:
#   output_dir: directory where the degibbsed files are written (BIDS sub/ses/anat)
#   file1..N:   the input image files to degibbs collectively (3D or 4D NIfTI)
#
# OUTPUT:
#   Each output NIfTI has the same stem as its input, with "_desc-degibbs"
#   inserted directly before the suffix (mostly "_MPM") and the ".nii" extension.
#   Corresponding JSON sidecars are copied over when present.
#
# REQUIRES:
#   - MRtrix3 utilities to be on the PATH
#   - FSL utilities to be on the PATH
#   - input files to be 3D or 4D image files with extensions recognised by FSL
#
# AUTHOR:
# 	Luke J. Edwards (ledwards@cbs.mpg.de)
#   Adapted for SLURM batch processing by Niklas Kuegler (kuegler@cbs.mpg.de)

#
#SBATCH -c 4                          # 4 cores
#SBATCH --mem 16G                     # estimated 16G RAM
#SBATCH --time 120                    # estimated 120 minutes maximum
#
## logfile output specified in call_slurm_batch_degibbs.sh

set -e

output_dir="$1"
shift
input_files=("$@")

echo "output_dir: $output_dir"
echo "--------------------------------"
echo "Inputs to degibbs:"
for f in "${input_files[@]}"; do
    echo "  - $f"
done
echo "--------------------------------"

if [[ -z "$output_dir" || ${#input_files[@]} -eq 0 ]]; then
    echo "Error: Not enough arguments supplied."
    echo "Usage: degibbs_slurm.sh <output_dir> <file1> <file2> ..."
    exit 1
fi

for f in "${input_files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: Input file does not exist: $f"
        exit 1
    fi
done

# Create the output directory (BIDS sub/ses/anat is already part of output_dir)
mkdir -p "$output_dir"

# Create a scratch directory inside the output directory (one per job, so that
# independent jobs writing to the same output dir do not collide)
scratch_dir="$output_dir/scratch_degibbs_$$"
mkdir -p "$scratch_dir"

echo ">>> Degibbsing ${#input_files[@]} file(s) together"
echo ">>> Scratch directory: $scratch_dir"

# Concatenate and degibbs all data together
mrcat "${input_files[@]}" - | mrdegibbs -mode 3d - "$scratch_dir"/degibbs.mif

# Report the matrix size of the concatenated volume so that the slice-encoding
# direction (axis 2, i.e. the 3rd dimension) can be verified: the spatial axes
# (0,1,2) should match the in-plane and slice dimensions of the input images.
echo ">>> Matrix size of concatenated volume (axis0 axis1 axis2 axis3): $(mrinfo "$scratch_dir"/degibbs.mif -size)"

idx=0
for m in "${input_files[@]}"; do
    noext=$(remove_ext "$m")
    base=$(basename "$noext")

    # Determine number of volumes in the input
    if [ "$(mrinfo "$m" -ndim)" = 3 ]; then
        nvol=1
    else
        nvol=$(mrinfo "$m" -size | cut -f 4 -d" ")
    fi
    idx_new=$((idx+nvol))

    # Insert "_desc-degibbs" directly before the suffix (mostly "_MPM")
    suffix="_${base##*_}"
    stem="${base%$suffix}"
    fname="${stem}_desc-degibbs${suffix}"

    echo "  >>> Splitting out $idx:$((idx_new-1)) -> $output_dir/${fname}.nii"

    # write degibbsed data to output folder
    mrconvert "$scratch_dir"/degibbs.mif -coord 3 ${idx}:$((idx_new-1)) "$output_dir"/"${fname}".nii

    # copy json sidecar files if present
    if [ -f "${noext}".json ]; then
        cp "${noext}".json "$output_dir"/"${fname}".json
        echo "      Copied JSON sidecar: ${fname}.json"
    fi

    idx=${idx_new}
done

# Remove the scratch directory if requested (via --d / --delete-scratch flag)
if [[ "${DELETE_SCRATCH:-false}" == "true" ]]; then
    echo ">>> Removing scratch directory: $scratch_dir"
    rm -rf "$scratch_dir"
else
    echo ">>> Scratch directory preserved: $scratch_dir"
fi

echo "Processing complete."
