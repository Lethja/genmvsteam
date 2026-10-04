#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then echo "Never run this script as root" >&2; exit 1; fi

# Check enough information was given to see a Steam game folder.
if [ -z "$1" ]; then printf "%s: No directory(s) specified. Nothing to do" "$0" >&2; exit 1; fi

acf_of () {
	local name
	local dir
	local files

	name=$(basename "$1")
	dir=$(realpath "$1/../../")

	shopt -s nullglob
	files=("$dir"/appmanifest_*.acf)
	shopt -u nullglob

	if [ "${#files[@]}" -eq 0 ]; then
		return 1
	fi

	grep -rl "\"installdir\"[[:space:]]*\"$name\"" "${files[@]}"
}

get_ids() {
	for metafile in "$@"; do
		basename "$metafile" | sed -E 's/^appmanifest_([0-9]+)\.acf$/\1/'
	done | awk '!seen[$0]++'
}

# Prevent destructive behaviour from user input error, never accept a destination directory we are not completely sure came from a Steam library path.
destination=$(realpath "${@: -1}")
if [ ! -d "$destination" ] || [ ! -d "$destination/common" ]; then printf "Warning: \'%s\' does not look like a 'steamapps' directory.\n" "$destination" >&2; exit 1; fi

printf "The following games will be moved to '%s':\n" "$destination/common"

for arg in "${@:1:(($#-1))}"; do
	# Prevent destructive behaviour from user input error, never manipulate a source directory we are not completely sure came from a Steam library path.
	if [ ! -d "$arg" ] || [[ $(realpath "$arg") == *"steamapps/common/$arg" ]]; then printf "Warning: \'%s\' does not look like a Steam game in a common directory.\n" "$arg" >&2; continue; fi

	mapfile -t metafiles < <(acf_of "$arg")
	mapfile -t ids < <(get_ids "${metafiles[@]}")
	old_ifs=$IFS
  IFS=','
	printf "\t'%s' (%s)\n" "$arg" "${ids[*]}"
	IFS=$old_ifs
done
