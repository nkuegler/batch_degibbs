#!/usr/bin/env bash

# Shared configuration for the degibbsing SLURM batch scripts.
# Should be sourced from the two scripts below (locating it relative to repo root).
#
# Adjust these paths to match your system.

export CONFIG_REPO_DIR="/data/u_kuegler_software/git/batch_degibbs/" # absolute path to the repository root
export CONFIG_DEGIBBS_SLURM_LOG_DIR="/data/u_kuegler_software/git/batch_degibbs/logs/"          # requires trailing slash



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
