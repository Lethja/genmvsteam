#!/bin/bash

if [ "$(id -u)" -eq 0 ]; then echo "Never run this script as root" >&2; exit 1; fi

# Check enough information was given to see a Steam game folder and a destination steamapps folder.
if [ "$#" -lt 2 ]; then printf "%s: Source directory(s) and destination steamapps directory required.\n" "$0" >&2; exit 1; fi

join_by () {
	local separator=$1
	shift

	local first=1
	local item

	for item in "$@"; do
		if [ "$first" -eq 1 ]; then
			printf '%s' "$item"
			first=0
		else
			printf '%s%s' "$separator" "$item"
		fi
	done
}

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

get_additional_folders_of_id() {
	local steamapps=$1
	local id

	for id in "${@:2}"; do
		if [ -d "$steamapps/compatdata/$id" ]; then echo "$steamapps/compatdata/$id"; fi
		if [ -d "$steamapps/workshop/content/$id" ]; then echo "$steamapps/workshop/content/$id"; fi
		if [ -f "$steamapps/workshop/appworkshop_$id.acf" ]; then echo "$steamapps/workshop/appworkshop_$id.acf"; fi
	done | awk '!seen[$0]++'
}

relative_to_steamapps() {
	local steamapps=$1
	local path=$2

	case "$path" in
		"$steamapps"/*)
			printf '%s\n' "${path#"$steamapps"/}"
			;;
		*)
			return 1
			;;
	esac
}

target_for_steamapps_path() {
	local source_steamapps=$1
	local destination_steamapps=$2
	local path=$3
	local relative

	relative=$(relative_to_steamapps "$source_steamapps" "$path") || return 1

	case "$relative" in
		compatdata/*)
			printf '%s\n' "$destination_steamapps/$relative"
			;;

		workshop/content/*)
			printf '%s\n' "$destination_steamapps/$relative"
			;;

		workshop/appworkshop_*.acf)
			printf '%s\n' "$destination_steamapps/$relative"
			;;

		appmanifest_*.acf)
			printf '%s\n' "$destination_steamapps/$relative"
			;;

		common/*)
			printf '%s\n' "$destination_steamapps/$relative"
			;;

		*)
			return 1
			;;
	esac
}

# These store the grouped move plan.
#
# game_keys keeps the groups in insertion order.
# moves_by_game maps each game key to a newline-separated list of move records.
#
# Each move record is:
#
# source<TAB>destination
#
game_keys=()
declare -A moves_by_game=()

add_game_group() {
	local game_key=$1

	game_keys+=("$game_key")
	moves_by_game["$game_key"]=""
}

add_game_move() {
	local game_key=$1
	local source=$2
	local target=$3

	moves_by_game["$game_key"]+="$source"$'\t'"$target"$'\n'
}

mkdir_already_covered() {
	local target_dir=$1
	local printed_dir

	for printed_dir in "${!printed_mkdirs[@]}"; do
		if [ "$target_dir" = "$printed_dir" ] || [[ "$printed_dir" == "$target_dir"/* ]]; then
			return 0
		fi
	done

	return 1
}

# Prevent destructive behaviour from user input error, never accept a destination directory we are not completely sure came from a Steam library path.
destination=$(realpath "${@: -1}")
if [ ! -d "$destination" ] || [ ! -d "$destination/common" ]; then printf "Warning: \'%s\' does not look like a 'steamapps' directory.\n" "$destination" >&2; exit 1; fi

printf "#!/bin/bash\n\nset -e\n\n# The following games will be moved to '%s':\n" "$destination/common"

for arg in "${@:1:(($#-1))}"; do
	source_game=$(realpath "$arg")
	source_common=$(realpath "$source_game/..")
	source_steamapps=$(realpath "$source_common/..")

	# Prevent destructive behaviour from user input error, never manipulate a source directory
	# we are not completely sure is a direct child of a Steam common directory.
	if [ ! -d "$source_game" ] || [ "$(basename "$source_common")" != "common" ] || [ ! -d "$source_steamapps/common" ]; then
		printf "Warning: '%s' does not look like a Steam game in a common directory.\n" "$arg" >&2
		continue
	fi

	game_name=$(basename "$source_game")
	game_key=$source_game

	mapfile -t metafiles < <(acf_of "$source_game")
	mapfile -t ids < <(get_ids "${metafiles[@]}")
	mapfile -t additional_paths < <(get_additional_folders_of_id "$source_steamapps" "${ids[@]}")

	add_game_group "$game_key"

	printf "# \t'%s' (id: %s)\n" "$source_game" "$(join_by ', ' "${ids[@]}")"

	# 1. Main game folder first.
	add_game_move "$game_key" "$source_game" "$destination/common/$game_name"

	# 2. Additional per-app data next.
	for path in "${additional_paths[@]}"; do
		target=$(target_for_steamapps_path "$source_steamapps" "$destination" "$path") || {
			printf "Warning: refusing unexpected Steam path '%s'\n" "$path" >&2
			continue
		}

		add_game_move "$game_key" "$path" "$target"
	done

	# 3. Main appmanifest files last.
	#
	# If a move fails midway, Steam is less likely to consider the destination
	# install complete before the payload data has arrived.
	for metafile in "${metafiles[@]}"; do
		target=$(target_for_steamapps_path "$source_steamapps" "$destination" "$metafile") || {
			printf "Warning: refusing unexpected manifest path '%s'\n" "$metafile" >&2
			continue
		}

		add_game_move "$game_key" "$metafile" "$target"
	done
done

declare -A printed_mkdirs=()

for game_key in "${game_keys[@]}"; do
	printf "\n# %s\n" "$game_key"

	while IFS=$'\t' read -r source target; do
		if [ -z "$source" ]; then continue; fi

		target_dir=$(dirname "$target")

		if ! mkdir_already_covered "$target_dir"; then
			printf "mkdir -p -- '%s'\n" "$target_dir"
			printed_mkdirs["$target_dir"]=1
		fi

		printf "mv -v -- '%s' '%s'\n" "$source" "$target"
	done <<< "${moves_by_game[$game_key]}"
done
