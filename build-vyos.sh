#!/bin/bash
# Build a VyOS qcow2 from a pinned vyos-build upstream + the patches in
# services/vyos/patches/, emit it under services/vyos/output/, and (with --install)
# drop it into eve/pkg/lps/images/ so the next ./build.sh qemu bundles it
# into the LPS package.
#
# Usage:
#   ./build-vyos.sh [--install] [--skip-setup] [--build-cmd "..."]
#
# --install      After build, copy the qcow2 into eve/pkg/lps/images/
#                (eve checkout must already exist — run ./build.sh first).
# --skip-setup   Skip the clone/reset/patch step; reuse the existing
#                vyos-build/ checkout as-is.
# --build-cmd    Override the inside-container build command. Default
#                comes from services/vyos/config.yml `build_cmd`.

set -e

repo_root="$(cd "$(dirname "$0")" && pwd)"
vyos_dir="$repo_root/vyos-build"
patches_dir="$repo_root/services/vyos/patches"
output_dir="$repo_root/services/vyos/output"
eve_images_dir="$repo_root/eve/pkg/lps/images"
config_file="$repo_root/services/vyos/config.yml"

install=0
skip_setup=0
build_cmd_override=""

while [ $# -gt 0 ]; do
    case "$1" in
        --install)     install=1;             shift ;;
        --skip-setup)  skip_setup=1;          shift ;;
        --build-cmd)   build_cmd_override="$2"; shift 2 ;;
        -h|--help)     sed -n '2,15p' "$0";   exit 0 ;;
        *)             echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Read one key from config.yml (top-level only).
# Blank YAML values (e.g. `revision:`) come back as Python None — collapse to ''
# so callers can use ${var:-default} fallback patterns.
read_cfg() {
    python3 -c "import yaml; v=yaml.safe_load(open('$config_file')).get('$1') or ''; print(v.strip() if isinstance(v,str) else v)"
}

repo=$(read_cfg repo)
branch=$(read_cfg branch)
revision=$(read_cfg revision)
docker_image=$(read_cfg docker_image)
build_cmd=$(read_cfg build_cmd)
output_glob=$(read_cfg output_glob)
output_name=$(read_cfg output_name)

[ -n "$build_cmd_override" ] && build_cmd="$build_cmd_override"

if [ -z "$repo" ] || [ -z "$branch" ] || [ -z "$docker_image" ] || \
   [ -z "$build_cmd" ] || [ -z "$output_glob" ] || [ -z "$output_name" ]; then
    echo "[vyos-build] missing required fields in $config_file" >&2
    exit 1
fi

if [ $skip_setup -eq 0 ]; then
    if [ ! -d "$vyos_dir/.git" ]; then
        echo "### Cloning $repo into $vyos_dir"
        git clone "$repo" "$vyos_dir"
    else
        echo "### Fetching $repo"
        (cd "$vyos_dir" && git fetch --all --tags)
    fi

    target="${revision:-$branch}"
    echo "### Reset $vyos_dir to $target"
    (cd "$vyos_dir" \
        && git checkout "$branch" \
        && git reset --hard "$target")

    if compgen -G "$patches_dir/*.patch" >/dev/null; then
        echo "### Applying patches from $patches_dir"
        for p in "$patches_dir"/*.patch; do
            echo "### git apply --3way $(basename "$p")"
            (cd "$vyos_dir" && git apply --3way "$p")
        done
    else
        echo "### No patches in $patches_dir (skipping)"
    fi
fi

mkdir -p "$output_dir"

echo "### Building VyOS image (docker image: $docker_image)"
echo "### Build command:"
echo "$build_cmd" | sed 's/^/        /'

docker run --rm --privileged \
    -v "$vyos_dir:/vyos" -w /vyos \
    "$docker_image" \
    bash -c "$build_cmd"

shopt -s nullglob
artifacts=( $vyos_dir/$output_glob )
if [ ${#artifacts[@]} -eq 0 ]; then
    echo "### No artifacts match $output_glob inside $vyos_dir" >&2
    exit 1
fi
# Most recent first
latest=$(ls -t "${artifacts[@]}" | head -1)

dst="$output_dir/$output_name"
cp "$latest" "$dst"
echo "### Wrote $dst"
sha256sum "$dst"

if [ $install -eq 1 ]; then
    if [ ! -d "$repo_root/eve" ]; then
        echo "### --install: eve checkout not present at $repo_root/eve" >&2
        echo "### Run ./build.sh <profile> first to populate it" >&2
        exit 1
    fi
    mkdir -p "$eve_images_dir"
    cp "$dst" "$eve_images_dir/$output_name"
    echo "### Installed into $eve_images_dir/$output_name"
    echo "### Next: rebuild pkg/lps + image so the new qcow2 lands in EVE:"
    echo "###   cd eve && make pkg/lps && cd .. && ./build.sh qemu"
fi
