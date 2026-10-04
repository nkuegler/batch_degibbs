#!/usr/bin/env bash

# Shared configuration for the degibbsing SLURM batch scripts.
# Should be sourced from the two scripts below (locating it relative to repo root).
#
# Adjust these paths to match your system.
#
# AUTHOR:
#   Niklas Kuegler (kuegler@cbs.mpg.de)
#
# LICENSE:
#   MIT License

export CONFIG_REPO_DIR="/data/u_kuegler_software/git/batch_degibbs/" # absolute path to the repository root
export CONFIG_DEGIBBS_SLURM_LOG_DIR="/data/u_kuegler_software/git/batch_degibbs/logs/"          # requires trailing slash

# MRtrix3 command prefix. Keep the trailing space for the container and the
# trailing slash for a local development-version bin directory.
export CONFIG_MRTRIX="/data/u_kuegler_software/git/mrtrix3/release/bin/"
# export CONFIG_MRTRIX="sc mrtrix 3.0.8 "

# Dimensionality used by the development version of mrdegibbs (2 or 3)
# Ignored when using the release version of mrtrix (sc mrtrix 3.0.8)
export CONFIG_MRTRIX_DIMENSIONALITY=3

# The mrtrix 3.0.8 container does not support -dimensionality. Set this to
# true only when CONFIG_MRTRIX is set to the container above.
export CONFIG_MRTRIX_NO_DIMENSIONALITY=false



### function defintions

check_partial_fourier() {
	jq -r '
		if type != "object" then
			error("JSON root is not an object")
		elif (has("PartialFourier") | not) then
			"missing"
		elif .PartialFourier == 1 then
			"valid"
		else
			"invalid"
		end
	' "$1" 2>/dev/null || printf '%s\n' "unreadable"
}
