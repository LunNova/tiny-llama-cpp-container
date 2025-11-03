#!/usr/bin/env nix-shell
#!nix-shell -i bash -p docker jq gawk gnused coreutils

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
	echo "Usage: $0 <image-name-or-id>"
	echo "Example: $0 llama.cpp:server-rocm"
	echo "         $0 b31eafc65107"
	exit 1
}

human_readable() {
	local bytes=$1
	# Use decimal units (1000-based) to match docker images output
	if [ "$bytes" -lt 1000 ]; then
		echo "${bytes}B"
	elif [ "$bytes" -lt 1000000 ]; then
		echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1000}")kB"
	elif [ "$bytes" -lt 1000000000 ]; then
		echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1000000}")MB"
	else
		echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1000000000}")GB"
	fi
}

if [ $# -eq 0 ]; then
	usage
fi

IMAGE="$1"

# Check if image exists
if ! docker image inspect "$IMAGE" &>/dev/null; then
	echo -e "${RED}Error: Image '$IMAGE' not found${NC}"
	exit 1
fi

echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           DOCKER IMAGE SIZE ANALYSIS                                       ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
echo

# Get total image size
TOTAL_SIZE=$(docker image inspect "$IMAGE" --format='{{.Size}}')
TOTAL_SIZE_HUMAN=$(human_readable "$TOTAL_SIZE")

echo -e "${BLUE}Image:${NC} $IMAGE"
echo -e "${BLUE}Total Size:${NC} $TOTAL_SIZE_HUMAN ($TOTAL_SIZE bytes)"
echo

# Layer breakdown
echo -e "${BOLD}${GREEN}═══ LAYER BREAKDOWN ═══${NC}"
echo

# Get docker history and parse it
echo -e "${YELLOW}SIZE       %      CREATED BY${NC}"

# Process layers directly from docker history, sort by size (largest first)
layer_num=0
declare -a layer_sizes=()
declare -a layer_commands=()
declare -a layer_size_bytes=()

while IFS= read -r line; do
	size_str=$(echo "$line" | jq -r '.Size')
	created_by=$(echo "$line" | jq -r '.CreatedBy' | sed 's/\/bin\/sh -c #(nop) //g' | sed 's/\/bin\/sh -c //g')

	# Parse size to bytes (docker uses decimal units: 1000-based)
	size_bytes=0
	if [[ "$size_str" =~ ([0-9.]+)([kMG]?B) ]]; then
		num="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]}"
		case "$unit" in
		B) size_bytes=$(awk "BEGIN {printf \"%.0f\", $num}") ;;
		kB) size_bytes=$(awk "BEGIN {printf \"%.0f\", $num*1000}") ;;
		MB) size_bytes=$(awk "BEGIN {printf \"%.0f\", $num*1000000}") ;;
		GB) size_bytes=$(awk "BEGIN {printf \"%.0f\", $num*1000000000}") ;;
		esac
	fi

	layer_size_bytes+=("$size_bytes")
	layer_sizes+=("$size_str")
	layer_commands+=("$created_by")
	layer_num=$((layer_num + 1))
done < <(docker history "$IMAGE" --format='{{json .}}' --no-trunc)

# Sort by size and display top layers
indices=($(for i in "${!layer_size_bytes[@]}"; do echo "$i ${layer_size_bytes[$i]}"; done | sort -k2 -rn | cut -d' ' -f1))

count=0
for idx in "${indices[@]}"; do
	size_bytes="${layer_size_bytes[$idx]}"
	if [ "$size_bytes" -gt 0 ]; then
		size_human="${layer_sizes[$idx]}"
		command="${layer_commands[$idx]}"
		percent=$(awk "BEGIN {printf \"%.1f\", ($size_bytes/$TOTAL_SIZE)*100}")

		# Truncate command if too long
		if [ ${#command} -gt 100 ]; then
			command="${command:0:99}…"
		fi

		printf "%-10s %-6s %s\n" "$size_human" "$percent%" "$command"

		count=$((count + 1))
		if [ "$count" -ge 15 ]; then
			remaining=$((layer_num - 15))
			if [ "$remaining" -gt 0 ]; then
				echo "... and $remaining more layers"
			fi
			break
		fi
	fi
done

echo
echo -e "${BOLD}${GREEN}═══ DIRECTORY BREAKDOWN ═══${NC}"
echo

# For large images, container export is slow. Let's use a smarter approach.
echo -e "${YELLOW}Analyzing filesystem... (this may take a moment for large images)${NC}"
echo

CONTAINER_ID=$(docker create "$IMAGE" 2>/dev/null)

# Instead of full export, just get directory sizes using docker export and tar
echo -e "${YELLOW}SIZE       PATH${NC}"

# Use tar to list and calculate sizes without full extraction
docker export "$CONTAINER_ID" | tar -tvf - 2>/dev/null | awk '
BEGIN { min_size = 100000000 }  # 100 MB in bytes
{
    # Field 3 is size, field 6 is path
    size = $3
    path = $6

    # Extract up to 4 directory levels (paths are relative, no leading slash)
    # Match patterns like: dir, dir/subdir, dir/subdir/subsubdir, dir/subdir/subsubdir/level4
    if (match(path, /^([^\/]+)(\/[^\/]+)?(\/[^\/]+)?(\/[^\/]+)?\//, arr)) {
        # Build the path progressively
        dir1 = "/" arr[1]
        dir_sizes[dir1] += size

        if (arr[2] != "") {
            dir2 = "/" arr[1] arr[2]
            dir_sizes[dir2] += size
        }

        if (arr[3] != "") {
            dir3 = "/" arr[1] arr[2] arr[3]
            dir_sizes[dir3] += size
        }

        if (arr[4] != "") {
            dir4 = "/" arr[1] arr[2] arr[3] arr[4]
            dir_sizes[dir4] += size
        }
    } else if (match(path, /^([^\/]+)(\/[^\/]+)?(\/[^\/]+)?(\/[^\/]+)?$/, arr)) {
        # Also handle paths that are exactly 1, 2, 3, or 4 levels (no trailing /)
        dir1 = "/" arr[1]
        dir_sizes[dir1] += size

        if (arr[2] != "") {
            dir2 = "/" arr[1] arr[2]
            dir_sizes[dir2] += size
        }

        if (arr[3] != "") {
            dir3 = "/" arr[1] arr[2] arr[3]
            dir_sizes[dir3] += size
        }

        if (arr[4] != "") {
            dir4 = "/" arr[1] arr[2] arr[3] arr[4]
            dir_sizes[dir4] += size
        }
    }
}
END {
    for (dir in dir_sizes) {
        if (dir_sizes[dir] >= min_size) {
            print dir_sizes[dir], dir
        }
    }
}' | sort -rn | awk '{
    # Store the data
    sizes[NR] = $1
    paths[NR] = $2
    count = NR
}
END {
    # Sort paths lexicographically (not by size) for hierarchical display
    n = asort(paths, sorted_paths)

    # Create a mapping from sorted path to size
    for (i = 1; i <= count; i++) {
        path_to_size[paths[i]] = sizes[i]
    }

    # Print in hierarchical order
    for (i = 1; i <= n; i++) {
        path = sorted_paths[i]
        size = path_to_size[path]

        # Count depth by counting slashes (subtract 1 for leading /)
        depth = gsub(/\//, "/", path) - 1

        # Print with indentation
        indent = ""
        for (j = 0; j < depth; j++) {
            indent = indent "  "
        }

        print size, indent path
    }
}' | while read -r size path; do
	size_human=$(human_readable "$size")
	printf "%-10s %s\n" "$size_human" "$path"
done

docker rm "$CONTAINER_ID" &>/dev/null
