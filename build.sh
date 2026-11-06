#!/usr/bin/env bash
# ==============================================================================
# OpenLAN Gateway (OLG) Master Unified Appliance Builder
# Single central build engine driven by build.yaml
# ==============================================================================
set -euo pipefail

# Auto-containerize: If running on the host, automatically re-launch inside Docker
if [ ! -f /.dockerenv ] && [ "${OLG_CONTAINER_BUILD:-false}" != "true" ]; then
  DOCKER_TTY=""
  [ -t 0 ] && DOCKER_TTY="-it"

  CRED_FWD=()
  if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
    CRED_FWD+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}" -e SSH_AUTH_SOCK="${SSH_AUTH_SOCK}")
  fi

  USER_HOME="${HOME}"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -d "$SUDO_HOME" ] && USER_HOME="$SUDO_HOME"
  fi
  if [ -d "${USER_HOME}/.ssh" ]; then
    CRED_FWD+=(-v "${USER_HOME}/.ssh:/root/.ssh_host:ro")
  fi
  if [ -f "${USER_HOME}/.gitconfig" ]; then
    CRED_FWD+=(-v "${USER_HOME}/.gitconfig:/root/.gitconfig.host:ro")
  fi
  if [ -f "${USER_HOME}/.git-credentials" ]; then
    CRED_FWD+=(-v "${USER_HOME}/.git-credentials:/root/.git-credentials:ro")
  fi
  if [ -d "${USER_HOME}/.config/gh" ]; then
    CRED_FWD+=(-v "${USER_HOME}/.config/gh:/root/.config/gh:ro")
  fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    CRED_FWD+=(-e GITHUB_TOKEN="${GITHUB_TOKEN}")
  elif [ -n "${GH_TOKEN:-}" ]; then
    CRED_FWD+=(-e GITHUB_TOKEN="${GH_TOKEN}")
  fi

  CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Ensure NBD kernel module is loaded on host if possible
  if ! lsmod | grep -q "^nbd "; then
    modprobe nbd max_part=8 2>/dev/null || true
  fi

  echo -e "\033[1;32m[OLG-BUILD]\033[0m Launching hermetic build environment inside container..."
  exec docker run --rm ${DOCKER_TTY} --privileged \
    -v /dev:/dev \
    -v /lib/modules:/lib/modules:ro \
    -v /:/host:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${CRED_FWD[@]}" \
    -v "${CURRENT_DIR}":"${CURRENT_DIR}" \
    -w "${CURRENT_DIR}" \
    -e SUDO_USER="${SUDO_USER:-}" \
    -e OLG_CONTAINER_BUILD=true \
    ubuntu:24.04 bash -c '
      export DEBIAN_FRONTEND=noninteractive
      if [ -d /root/.ssh_host ]; then
        mkdir -p /root/.ssh
        cp -a /root/.ssh_host/. /root/.ssh/ 2>/dev/null || true
        chown -R root:root /root/.ssh 2>/dev/null || true
        chmod 700 /root/.ssh 2>/dev/null || true
        chmod 600 /root/.ssh/* 2>/dev/null || true
        chmod 644 /root/.ssh/*.pub 2>/dev/null || true
      fi
      [ -f /root/.gitconfig.host ] && cp -f /root/.gitconfig.host /root/.gitconfig 2>/dev/null || true
      echo -e "\033[1;32m[OLG-BUILD]\033[0m Initializing container packages (go, qemu, xorriso, docker, ssh, patch, python3-yaml)..."
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        golang-go qemu-utils xorriso p7zip-full docker.io \
        curl git jq python3 python3-yaml ca-certificates kmod file bc sudo \
        openssh-client patch
      echo -e "\033[1;32m[OLG-BUILD]\033[0m Build container toolchain ready. Starting build..."
      exec ./build.sh "$@"
    ' bash "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/build.yaml"

# Logging helpers
log()  { echo -e "\033[1;32m[OLG-BUILD]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Helper: Find first available free NBD block device
find_free_nbd() {
  if ! lsmod | grep -q "^nbd "; then
    sudo modprobe nbd max_part=8 2>/dev/null || true
  fi
  for dev in /sys/block/nbd*; do
    [ -d "$dev" ] || continue
    local bname
    bname=$(basename "$dev")
    local size
    size=$(cat "$dev/size" 2>/dev/null || echo "1")
    if [ "$size" = "0" ] && [ ! -f "$dev/pid" ] && ! grep -q "/dev/${bname}" /proc/mounts 2>/dev/null; then
      if [ ! -b "/dev/${bname}" ]; then
        local minor="${bname#nbd}"
        sudo mknod "/dev/${bname}" b 43 $((minor * 8)) 2>/dev/null || true
      fi
      echo "/dev/${bname}"
      return 0
    fi
  done
  return 1
}

# Parse CLI Arguments
MODE_ALL=true
MODE_VYOS=true
MODE_ISO=true
REFRESH_DEBS=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

OpenLAN Gateway (OLG) Master Unified Appliance Builder

Options:
  --vyos-only           Build only the VyOS Golden Master Disk
  --iso-only            Build only the Enterprise Appliance ISO (requires vyos-golden.qcow2)
  --refresh-debs        Force refresh/regeneration of offline Debian packages cache
  --config <PATH>       Path to custom build.yaml manifest (Default: ./build.yaml)
  -h, --help            Show this help message
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vyos-only)
      MODE_VYOS=true
      MODE_ISO=false
      shift
      ;;
    --iso-only)
      MODE_VYOS=false
      MODE_ISO=true
      shift
      ;;
    --refresh-debs)
      REFRESH_DEBS=true
      shift
      ;;
    --config)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

# Verify Manifest
if [ ! -f "$MANIFEST_FILE" ]; then
  if [ -f "${SCRIPT_DIR}/build.yaml.example" ]; then
    log "Initializing ${MANIFEST_FILE} from template..."
    cp "${SCRIPT_DIR}/build.yaml.example" "$MANIFEST_FILE"
  else
    err "Manifest file not found: $MANIFEST_FILE"
  fi
fi

# Ensure Python3 and PyYAML
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  err "Python3 PyYAML module is required. Run: sudo apt install -y python3-yaml"
fi

# Extract manifest configuration to JSON
MANIFEST_JSON=$(python3 -c "
import yaml, json, sys
with open('$MANIFEST_FILE') as f:
    cfg = yaml.safe_load(f)
print(json.dumps(cfg))
")

# Global paths & cleanup state tracking
BUILD_DIR="${SCRIPT_DIR}/build"
CACHE_DIR="${BUILD_DIR}/cache"
OUTPUT_DIR="${BUILD_DIR}/output"
mkdir -p "${BUILD_DIR}/.tmp"
WORK_DIR=$(mktemp -d -p "${BUILD_DIR}/.tmp" olg-build-XXXXXX)
PROVENANCE_DIR="${WORK_DIR}/provenance"
mkdir -p "$PROVENANCE_DIR"
rm -rf "${OUTPUT_DIR}/.provenance" 2>/dev/null || true

VYOS_MNT_DIR=""
CURRENT_NBD_DEV=""
CLEANED_UP=false

cleanup() {
  local exit_code=$?
  [ "$CLEANED_UP" = true ] && exit "$exit_code"
  CLEANED_UP=true

  # 1. Safely unmount any active VyOS mount
  if [ -n "${VYOS_MNT_DIR:-}" ] && [ -d "${VYOS_MNT_DIR}" ]; then
    if mountpoint -q "${VYOS_MNT_DIR}" 2>/dev/null || grep -q "${VYOS_MNT_DIR}" /proc/mounts 2>/dev/null; then
      warn "Cleaning up active mount: ${VYOS_MNT_DIR}..."
      sudo umount -f "${VYOS_MNT_DIR}" 2>/dev/null || sudo umount -l "${VYOS_MNT_DIR}" 2>/dev/null || true
    fi
  fi

  # Also scan /proc/mounts for any lingering submounts under WORK_DIR
  if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
    while read -r lingering_mnt; do
      [ -n "$lingering_mnt" ] || continue
      warn "Unmounting lingering mount under WORK_DIR: ${lingering_mnt}..."
      sudo umount -f "$lingering_mnt" 2>/dev/null || sudo umount -l "$lingering_mnt" 2>/dev/null || true
    done < <(grep "${WORK_DIR}" /proc/mounts 2>/dev/null | awk '{print $2}' || true)
  fi

  # 2. Disconnect active NBD device if connected
  if [ -n "${CURRENT_NBD_DEV:-}" ]; then
    warn "Disconnecting NBD device: ${CURRENT_NBD_DEV}..."
    sudo qemu-nbd --disconnect "${CURRENT_NBD_DEV}" 2>/dev/null || true
  fi

  # 3. Clean up WORK_DIR
  if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

mkdir -p "$CACHE_DIR" "$OUTPUT_DIR"

# Manifest Variables
UBUNTU_RELEASE=$(jq -r '.host.ubuntu_release // .global.ubuntu_release // "25.10"' <<< "$MANIFEST_JSON")
UBUNTU_ISO_URL=$(jq -r '.host.ubuntu_iso_url // .global.ubuntu_iso_url // empty' <<< "$MANIFEST_JSON")
UBUNTU_ISO_SHA256=$(jq -r '.host.ubuntu_iso_sha256 // .global.ubuntu_iso_sha256 // empty' <<< "$MANIFEST_JSON")

echo "================================================================="
echo "        OPENLAN GATEWAY (OLG) UNIFIED BUILD ENGINE               "
echo "================================================================="
echo " Manifest       : $MANIFEST_FILE"
echo " Target Ubuntu  : $UBUNTU_RELEASE"
echo " Build Mode     : VyOS=${MODE_VYOS}, ISO=${MODE_ISO}"
echo "================================================================="

# ------------------------------------------------------------------------------
# Configure Git authentication (supports SSH keys, PAT, and GitHub CLI tokens)
# ------------------------------------------------------------------------------
HAS_SSH_KEY=false
USER_SSH_DIR=""
if [ -d "/root/.ssh" ]; then
  USER_SSH_DIR="/root/.ssh"
elif [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}/.ssh" ]; then
  USER_SSH_DIR="/home/${SUDO_USER}/.ssh"
elif [ -d "${HOME:-/root}/.ssh" ]; then
  USER_SSH_DIR="${HOME:-/root}/.ssh"
fi

if [ -n "$USER_SSH_DIR" ] && [ -d "$USER_SSH_DIR" ]; then
  for key in id_ed25519 id_rsa id_ecdsa; do
    if [ -f "${USER_SSH_DIR}/${key}" ]; then
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -i ${USER_SSH_DIR}/${key}"
      HAS_SSH_KEY=true
      break
    fi
  done
fi

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
  HAS_SSH_KEY=true
  [ -z "${GIT_SSH_COMMAND:-}" ] && export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/" 2>/dev/null || true
  log "Configured Git to authenticate via GITHUB_TOKEN (Personal Access Token)."
elif [ "$HAS_SSH_KEY" = "true" ]; then
  git config --global url."git@github.com:".insteadOf "https://github.com/" 2>/dev/null || true
  log "Configured Git to authenticate via SSH."
else
  log "Preserving Git HTTPS authentication (using local git credentials / PAT)."
fi
export GIT_TERMINAL_PROMPT=0

# ------------------------------------------------------------------------------
# 1. Dependency Validation
# ------------------------------------------------------------------------------
log "Validating host build dependencies..."
REQUIRED_TOOLS=(xorriso 7z sha256sum curl go docker qemu-img qemu-nbd patch git jq)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  pkgs_to_install=()
  for t in "${MISSING_TOOLS[@]}"; do
    case "$t" in
      xorriso) pkgs_to_install+=(xorriso) ;;
      7z) pkgs_to_install+=(p7zip-full) ;;
      curl) pkgs_to_install+=(curl) ;;
      go) pkgs_to_install+=(golang-go) ;;
      docker) pkgs_to_install+=(docker.io) ;;
      qemu-img|qemu-nbd) pkgs_to_install+=(qemu-utils) ;;
      patch) pkgs_to_install+=(patch) ;;
      git) pkgs_to_install+=(git) ;;
      jq) pkgs_to_install+=(jq) ;;
    esac
  done
  pkgs_to_install=($(printf "%s\n" "${pkgs_to_install[@]}" | sort -u))

  if [ "${EUID:-$(id -u)}" -eq 0 ] || command -v sudo >/dev/null 2>&1; then
    log "Auto-installing missing tools: ${MISSING_TOOLS[*]} (${pkgs_to_install[*]})..."
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs_to_install[@]}"
  else
    err "Missing tools: ${MISSING_TOOLS[*]}. Install them before proceeding: ${pkgs_to_install[*]}"
  fi
fi

if ! lsmod | grep -q "^nbd "; then
  log "Loading nbd kernel module..."
  sudo modprobe nbd max_part=8 2>/dev/null || true
fi

# ==============================================================================
# Helper: Patch Resolver
# Resolves patches from local dir, git sparse-checkout, or URLs
# ==============================================================================
resolve_and_apply_patches() {
  local binary_json="$1"
  local target_src_dir="$2"
  local patches_json
  patches_json=$(jq -c '.patches // empty' <<< "$binary_json")

  [ -z "$patches_json" ] || [ "$patches_json" = "null" ] && return 0

  local patch_tmp="${WORK_DIR}/patches_$(date +%s%N)"
  mkdir -p "$patch_tmp"

  local local_dir
  local_dir=$(jq -r '.local_dir // empty' <<< "$patches_json")
  local repo
  repo=$(jq -r '.repo // empty' <<< "$patches_json")
  local ref
  ref=$(jq -r '.ref // "main"' <<< "$patches_json")
  local p_path
  p_path=$(jq -r '.path // empty' <<< "$patches_json")

  if [ -n "$repo" ] && [ -n "$p_path" ]; then
    log "Fetching patches from ${repo} (${p_path} @ ${ref})..."
    local git_sparse_tmp="${WORK_DIR}/git_sparse_$(date +%s%N)"
    mkdir -p "$git_sparse_tmp"
    git clone --depth 1 --filter=blob:none --sparse --branch "$ref" "$repo" "$git_sparse_tmp" 2>/dev/null || \
      (git clone --filter=blob:none --sparse "$repo" "$git_sparse_tmp" 2>/dev/null && (cd "$git_sparse_tmp" && git checkout "$ref" 2>/dev/null || true))
    if [ -d "$git_sparse_tmp/.git" ]; then
      (cd "$git_sparse_tmp" && git sparse-checkout set "$p_path" 2>/dev/null || true)
      cp -f "$git_sparse_tmp/$p_path"/*.patch "$patch_tmp/" 2>/dev/null || true
    fi
    rm -rf "$git_sparse_tmp"
  elif [ -n "$local_dir" ] && [ -d "${SCRIPT_DIR}/${local_dir}" ]; then
    log "Using local patches from ${SCRIPT_DIR}/${local_dir}..."
    cp -f "${SCRIPT_DIR}/${local_dir}"/*.patch "$patch_tmp/" 2>/dev/null || true
  fi

  # Apply discovered patches sequentially
  local patch_count=0
  for p in $(ls -1v "$patch_tmp"/*.patch 2>/dev/null || true); do
    if [ -f "$p" ]; then
      log "Applying patch: $(basename "$p")..."
      patch -p1 -d "$target_src_dir" < "$p"
      patch_count=$((patch_count + 1))
    fi
  done
  log "Applied ${patch_count} patch(es) to $(basename "$target_src_dir")."
  rm -rf "$patch_tmp"
}

# ==============================================================================
# Helper: Provenance Manifest Generator
# Generates a comprehensive SBOM and provenance manifest (provenance.json)
# capturing inputs, commits, container digests, base image checksums, and outputs
# ==============================================================================
generate_provenance_manifest() {
  local output_file="$1"
  local final_iso_path="${2:-}"

  local vyos_json
  vyos_json=$(jq -c '.vyos // {}' <<< "$MANIFEST_JSON")
  local host_json
  host_json=$(jq -c '.host // {}' <<< "$MANIFEST_JSON")

  local vyos_bins="[]"
  if compgen -G "${PROVENANCE_DIR}/vyos_bin_*.json" >/dev/null 2>&1; then
    vyos_bins=$(jq -s '.' "${PROVENANCE_DIR}"/vyos_bin_*.json)
  fi

  local host_bins="[]"
  if compgen -G "${PROVENANCE_DIR}/host_bin_*.json" >/dev/null 2>&1; then
    host_bins=$(jq -s '.' "${PROVENANCE_DIR}"/host_bin_*.json)
  fi

  local containers="[]"
  if compgen -G "${PROVENANCE_DIR}/container_*.json" >/dev/null 2>&1; then
    containers=$(jq -s '.' "${PROVENANCE_DIR}"/container_*.json)
  fi

  local offline_pkgs_file="${PROVENANCE_DIR}/offline_packages.json"
  local temp_empty=""
  if [ ! -f "$offline_pkgs_file" ]; then
    temp_empty=$(mktemp)
    echo "[]" > "$temp_empty"
    offline_pkgs_file="$temp_empty"
  fi

  local vyos_golden_sha=""
  if [ -f "${OUTPUT_DIR}/vyos-golden.qcow2.sha256" ]; then
    vyos_golden_sha=$(awk '{print $1}' "${OUTPUT_DIR}/vyos-golden.qcow2.sha256")
  fi

  local iso_sha=""
  if [ -n "$final_iso_path" ] && [ -f "${final_iso_path}.sha256" ]; then
    iso_sha=$(awk '{print $1}' "${final_iso_path}.sha256")
  fi

  mkdir -p "$(dirname "$output_file")"
  jq -n \
    --arg build_time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg builder "$(whoami)@$(hostname 2>/dev/null || echo "builder")" \
    --arg manifest_ver "$(jq -r '.version // "1.0"' <<< "$MANIFEST_JSON")" \
    --arg ubuntu_rel "$UBUNTU_RELEASE" \
    --arg vyos_base_name "$(jq -r '.base_image.cache_name // "vyos-base.qcow2"' <<< "$vyos_json")" \
    --arg vyos_base_url "$(jq -r '.base_image.url // ""' <<< "$vyos_json")" \
    --arg vyos_base_sha "$(jq -r '.base_image.sha256 // ""' <<< "$vyos_json")" \
    --arg ubuntu_iso_url "$UBUNTU_ISO_URL" \
    --arg ubuntu_iso_sha "$UBUNTU_ISO_SHA256" \
    --arg vyos_golden_sha "$vyos_golden_sha" \
    --arg final_iso_sha "$iso_sha" \
    --argjson vyos_binaries "$vyos_bins" \
    --argjson host_binaries "$host_bins" \
    --argjson containers "$containers" \
    --slurpfile offline_pkgs "$offline_pkgs_file" \
    '{
      schema_version: "1.0",
      build_timestamp: $build_time,
      builder: $builder,
      manifest_version: $manifest_ver,
      ubuntu_release: $ubuntu_rel,
      base_images: {
        vyos: {
          cache_name: $vyos_base_name,
          url: $vyos_base_url,
          expected_sha256: (if $vyos_base_sha != "" then $vyos_base_sha else null end)
        },
        ubuntu_installer: {
          url: $ubuntu_iso_url,
          expected_sha256: (if $ubuntu_iso_sha != "" then $ubuntu_iso_sha else null end)
        }
      },
      vyos_binaries: $vyos_binaries,
      host_binaries: $host_binaries,
      containers: $containers,
      offline_packages: (if ($offline_pkgs | length) > 0 then $offline_pkgs[0] else [] end),
      artifacts: {
        vyos_golden_disk: {
          file: "vyos-golden.qcow2",
          sha256: (if $vyos_golden_sha != "" then $vyos_golden_sha else null end)
        },
        enterprise_iso: {
          file: ("olg-enterprise-appliance-" + $ubuntu_rel + ".iso"),
          sha256: (if $final_iso_sha != "" then $final_iso_sha else null end)
        }
      }
    }' > "$output_file"
  [ -n "$temp_empty" ] && rm -f "$temp_empty"
  log "Generated artifact provenance manifest: ${output_file}"
}

# ==============================================================================
# STEP 1: Build VyOS Golden Master Disk
# ==============================================================================
build_vyos() {
  log "================================================================="
  log "STEP 1: Compiling Components & Building VyOS Golden Disk"
  log "================================================================="

  local vyos_json
  vyos_json=$(jq -c '.vyos' <<< "$MANIFEST_JSON")
  local base_name
  base_name=$(jq -r '.base_image.cache_name // "vyos-base.qcow2"' <<< "$vyos_json")
  local base_url
  base_url=$(jq -r '.base_image.url // empty' <<< "$vyos_json")
  local base_sha256
  base_sha256=$(jq -r '.base_image.sha256 // empty' <<< "$vyos_json")
  local cached_base="${CACHE_DIR}/${base_name}"
  local golden_disk="${OUTPUT_DIR}/vyos-golden.qcow2"

  if [ ! -f "$cached_base" ]; then
    if [ -n "$base_url" ]; then
      log "Downloading VyOS base disk from $base_url..."
      curl --fail -L -C - -o "$cached_base" "$base_url"
    else
      err "VyOS base disk not found in cache ($cached_base) and no base_image.url configured in manifest."
    fi
  fi

  # Validate base VyOS image checksum if declared
  if [ -n "$base_sha256" ]; then
    log "Verifying SHA-256 checksum for VyOS base disk: ${cached_base}..."
    local act_base_sha
    act_base_sha=$(sha256sum "$cached_base" | awk '{print $1}')
    if [ "$act_base_sha" != "$base_sha256" ]; then
      err "VyOS base disk SHA-256 checksum mismatch! Expected: ${base_sha256}, Got: ${act_base_sha}"
    fi
    log "VyOS base disk checksum verified [OK]."
  fi

  # Working staging directories for binaries and libraries
  local vyos_stage_bin="${WORK_DIR}/vyos_stage_bin"
  local vyos_stage_lib="${WORK_DIR}/vyos_stage_lib"
  mkdir -p "$vyos_stage_bin" "$vyos_stage_lib"

  # Process VyOS Binaries declared in manifest
  local num_binaries
  num_binaries=$(jq '.binaries | length' <<< "$vyos_json")

  for ((i=0; i<num_binaries; i++)); do
    local b_json
    b_json=$(jq -c ".binaries[$i]" <<< "$vyos_json")
    local b_name
    b_name=$(jq -r '.name' <<< "$b_json")
    local b_type
    b_type=$(jq -r '.type' <<< "$b_json")
    local b_dest
    b_dest=$(jq -r '.dest' <<< "$b_json")
    local b_local
    b_local=$(jq -r '.local_path // empty' <<< "$b_json")
    local b_repo
    b_repo=$(jq -r '.repo // empty' <<< "$b_json")
    local b_ref
    b_ref=$(jq -r '.ref // "main"' <<< "$b_json")
    local b_url
    b_url=$(jq -r '.url // empty' <<< "$b_json")

    log "Processing VyOS binary: ${b_name} [${b_type}] -> ${b_dest}"
    local b_src_dir="${WORK_DIR}/src_${b_name}"
    mkdir -p "$b_src_dir"

    # Acquire source
    if [ -n "$b_local" ] && [ -d "${SCRIPT_DIR}/${b_local}" ]; then
      log "Using local repository for ${b_name} from ${SCRIPT_DIR}/${b_local}..."
      cp -r "${SCRIPT_DIR}/${b_local}"/* "$b_src_dir/"
    elif [ -n "$b_repo" ]; then
      log "Cloning ${b_name} from ${b_repo} (ref: ${b_ref})..."
      git clone --depth 1 --branch "$b_ref" "$b_repo" "$b_src_dir" 2>/dev/null || \
        (git clone "$b_repo" "$b_src_dir" && cd "$b_src_dir" && git checkout "$b_ref")
    elif [ -n "$b_url" ]; then
      log "Downloading source tarball for ${b_name} from ${b_url}..."
      curl -f -sL "$b_url" | tar -xz -C "$b_src_dir" --strip-components=1
    fi

    # Record provenance for VyOS binary
    local actual_commit="local"
    if [ -d "$b_src_dir/.git" ]; then
      actual_commit=$(git -C "$b_src_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
    fi
    mkdir -p "${PROVENANCE_DIR}"
    jq -n \
      --arg name "$b_name" \
      --arg type "$b_type" \
      --arg repo "${b_repo:-local}" \
      --arg ref "${b_ref:-}" \
      --arg commit "$actual_commit" \
      --arg dest "$b_dest" \
      '{name: $name, type: $type, repo: $repo, ref: $ref, commit_sha: $commit, dest: $dest}' \
      > "${PROVENANCE_DIR}/vyos_bin_${i}.json"

    # Resolve and apply patches
    resolve_and_apply_patches "$b_json" "$b_src_dir"

    # Compile based on type
    case "$b_type" in
      go)
        log "Compiling Go binary for ${b_name}..."
        local b_build_cmd
        b_build_cmd=$(jq -r '.build_cmd // empty' <<< "$b_json")
        if [ -z "$b_build_cmd" ]; then
          err "Binary '${b_name}' is missing required 'build_cmd' in ${MANIFEST_FILE}."
        fi
        local cmd="${b_build_cmd//\{output\}/\"${vyos_stage_bin}/${b_name}\"}"
        (cd "$b_src_dir" && eval "$cmd")
        ;;
      cmake)
        log "Compiling CMake binary for ${b_name} in hermetic debian:bookworm-slim container..."
        local build_container
        build_container=$(jq -r '.build_container // "debian:bookworm-slim"' <<< "$b_json")
        local cmake_args
        cmake_args=$(jq -r '.cmake_args // ""' <<< "$b_json")
        local lib_patterns
        lib_patterns=$(jq -r '.libraries[]? // empty' <<< "$b_json" | tr '\n' ' ')

        docker run --rm -v "${b_src_dir}:/src" -v "${vyos_stage_bin}:/out_bin" -v "${vyos_stage_lib}:/out_lib" "$build_container" bash -c "
          set -e
          apt-get update -qq && apt-get install -qq -y cmake build-essential libssl-dev libev-dev patch curl >/dev/null
          cd /src
          mkdir -p build && cd build
          cmake .. ${cmake_args} >/dev/null
          make -j\$(nproc) >/dev/null
          cp src/${b_name} /out_bin/${b_name} 2>/dev/null || cp ${b_name} /out_bin/${b_name} 2>/dev/null || cp build/${b_name} /out_bin/${b_name}
          for lib in ${lib_patterns}; do
            cp -a \${lib} /out_lib/ 2>/dev/null || true
          done
        "
        ;;
      *)
        err "Unsupported compilation type: $b_type for $b_name"
        ;;
    esac

    # Record destination
    echo "${b_dest}" > "${vyos_stage_bin}/${b_name}.dest"
  done

  # Mount QCOW2 via NBD and inject components
  log "Mounting VyOS QCOW2 via NBD for file injection..."
  cp -f "$cached_base" "$golden_disk"
  local mnt="${WORK_DIR}/vyos_mnt"
  mkdir -p "$mnt"
  VYOS_MNT_DIR="$mnt"

  # Dynamically discover an available free NBD device
  CURRENT_NBD_DEV=$(find_free_nbd 2>/dev/null || true)
  if [ -z "$CURRENT_NBD_DEV" ]; then
    err "No free NBD block devices available in /dev/nbd*. Check active mounts or 'lsmod | grep nbd'."
  fi

  log "Connecting ${golden_disk} to ${CURRENT_NBD_DEV}..."
  sudo qemu-nbd --disconnect "$CURRENT_NBD_DEV" 2>/dev/null || true
  sudo qemu-nbd --connect="$CURRENT_NBD_DEV" "$golden_disk"
  sleep 1

  # Discover root partition (default VyOS rootfs is partition 3)
  local part_dev="${CURRENT_NBD_DEV}p3"
  if [ ! -b "$part_dev" ]; then
    sudo partx -u "$CURRENT_NBD_DEV" 2>/dev/null || sudo partprobe "$CURRENT_NBD_DEV" 2>/dev/null || true
    sleep 1
  fi
  if [ ! -b "$part_dev" ]; then
    err "Expected VyOS root partition ${part_dev} not found after connecting ${golden_disk}."
  fi

  sudo mount "$part_dev" "$mnt"

  local root_target="$mnt"
  local vyos_rw
  vyos_rw=$(ls -d "$mnt"/boot/*/rw 2>/dev/null | head -n 1 || echo "")
  if [ -n "$vyos_rw" ] && [ -d "$vyos_rw" ]; then
    root_target="$vyos_rw"
    log "Using VyOS persistence overlay root: $root_target"
  fi

  # Inject compiled binaries & recorded destinations
  for bin_path in "$vyos_stage_bin"/*; do
    [ -f "$bin_path" ] || continue
    [[ "$bin_path" == *.dest ]] && continue
    local b_name
    b_name=$(basename "$bin_path")
    local dest_file
    dest_file=$(cat "${bin_path}.dest" 2>/dev/null || echo "/usr/local/bin/${b_name}")
    log "Injecting ${b_name} -> ${root_target}${dest_file}..."
    sudo mkdir -p "$(dirname "${root_target}${dest_file}")"
    sudo cp -f "$bin_path" "${root_target}${dest_file}"
    sudo chmod 0755 "${root_target}${dest_file}"
  done

  # Inject shared libraries if any
  if ls "$vyos_stage_lib"/* >/dev/null 2>&1; then
    log "Injecting shared libraries into VyOS..."
    sudo mkdir -p "$root_target/usr/lib/x86_64-linux-gnu"
    sudo cp -a "$vyos_stage_lib"/* "$root_target/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
  fi

  # Inject VirtIO-FS mount points, terminal profiles, and agent service
  sudo mkdir -p "$root_target/etc/olg/secrets" "$root_target/etc/olg/device-certs" "$root_target/opt/olg/state" "$root_target/etc/profile.d"
  
  # Ensure /etc/rtty symlink points to /etc/olg/device-certs
  sudo ln -sf /etc/olg/device-certs "$root_target/etc/rtty" 2>/dev/null || true

  # Terminal profile
  echo 'if [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [ "$TERM" = "unknown" ]; then export TERM=xterm-256color; fi' | sudo tee "$root_target/etc/profile.d/terminal.sh" >/dev/null
  sudo chmod 0644 "$root_target/etc/profile.d/terminal.sh"

  # Inject VyOS prestart hook, systemd service, agent config, and udev rules from templates
  local vyos_tpl_dir="${BUILD_DIR}/vyos"

  # 1. Prestart synchronization hook
  if [ -f "$vyos_tpl_dir/scripts/vyos-nats-agent-prestart.sh" ]; then
    sudo cp -f "$vyos_tpl_dir/scripts/vyos-nats-agent-prestart.sh" "$root_target/usr/local/bin/vyos-nats-agent-prestart.sh"
    sudo chmod 0755 "$root_target/usr/local/bin/vyos-nats-agent-prestart.sh"
    log "Injected vyos-nats-agent-prestart.sh from template."
  fi

  # 2. Systemd service unit and auto-enable
  if [ -f "$vyos_tpl_dir/systemd/vyos-nats-agent.service" ]; then
    sudo mkdir -p "$root_target/etc/systemd/system/multi-user.target.wants"
    sudo cp -f "$vyos_tpl_dir/systemd/vyos-nats-agent.service" "$root_target/etc/systemd/system/vyos-nats-agent.service"
    sudo chmod 0644 "$root_target/etc/systemd/system/vyos-nats-agent.service"
    sudo ln -sf /etc/systemd/system/vyos-nats-agent.service "$root_target/etc/systemd/system/multi-user.target.wants/vyos-nats-agent.service" 2>/dev/null || true
    log "Injected and enabled vyos-nats-agent.service from template."
  fi

  # 3. Agent configuration
  if [ -f "$vyos_tpl_dir/config/config.yaml" ]; then
    sudo mkdir -p "$root_target/etc/vyos-nats-agent"
    sudo cp -f "$vyos_tpl_dir/config/config.yaml" "$root_target/etc/vyos-nats-agent/config.yaml"
    sudo chmod 0644 "$root_target/etc/vyos-nats-agent/config.yaml"
    log "Injected /etc/vyos-nats-agent/config.yaml from template."
  fi

  # 4. Udev persistent network naming rules
  if [ -f "$vyos_tpl_dir/udev/70-persistent-net.rules" ]; then
    sudo mkdir -p "$root_target/etc/udev/rules.d"
    sudo cp -f "$vyos_tpl_dir/udev/70-persistent-net.rules" "$root_target/etc/udev/rules.d/70-persistent-net.rules"
    sudo chmod 0644 "$root_target/etc/udev/rules.d/70-persistent-net.rules"
    log "Injected /etc/udev/rules.d/70-persistent-net.rules from template."
  fi

  # Enable serial console on ttyS0 for 'virsh console'
  sudo mkdir -p "$root_target/etc/systemd/system/getty.target.wants"
  sudo ln -sf /lib/systemd/system/serial-getty@.service "$root_target/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true

  # Configure VyOS postconfig bootup hook to signal boot completion
  for POSTCONFIG_DIR in "$root_target/opt/vyatta/etc/config/scripts" "$root_target/config/scripts"; do
    sudo mkdir -p "$POSTCONFIG_DIR"
    POSTCONFIG_SCRIPT="$POSTCONFIG_DIR/vyos-postconfig-bootup.script"
    if [ ! -f "$POSTCONFIG_SCRIPT" ]; then
      echo '#!/bin/sh' | sudo tee "$POSTCONFIG_SCRIPT" >/dev/null
    fi
    cat <<'EOF_POSTCONFIG' | sudo tee -a "$POSTCONFIG_SCRIPT" >/dev/null

# OLG: Ensure runtime directories exist
mkdir -p /run/vyatta/config /run/vyos 2>/dev/null || true

# OLG: Ensure management interface mgmt0 is configured and up
ip addr add 192.168.254.1/24 dev mgmt0 2>/dev/null || true
ip link set mgmt0 up 2>/dev/null || true

# OLG: Ensure DNS nameservers for domain resolution out of the box
which resolvectl >/dev/null 2>&1 && resolvectl default-route br0 true 2>/dev/null || true
which resolvectl >/dev/null 2>&1 && resolvectl dns br0 1.1.1.1 8.8.8.8 2>/dev/null || true
if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf 2>/dev/null || true
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>/dev/null || true
fi

# OLG: Strip any auto-generated hw-id lines from config.boot to preserve hardware portability
for cfg in /config/config.boot /opt/vyatta/etc/config/config.boot; do
  [ -f "$cfg" ] && sed -i '/^[[:space:]]*hw-id[[:space:]]/d' "$cfg" 2>/dev/null || true
done

# OLG: Signal that VyOS postconfig and initial boot commits are 100% complete
touch /run/vyos/boot_ready
EOF_POSTCONFIG
    sudo chmod 0755 "$POSTCONFIG_SCRIPT"
  done

  # Configure VirtIO-FS auto-mount in /etc/fstab and modules
  if [ -f "$root_target/etc/fstab" ]; then
    if ! grep -q "guest_secrets" "$root_target/etc/fstab" 2>/dev/null; then
      echo "guest_secrets /etc/olg/secrets virtiofs ro,nofail 0 0" | sudo tee -a "$root_target/etc/fstab" >/dev/null
    fi
  fi
  if [ -f "$root_target/etc/modules" ]; then
    if ! grep -q "virtiofs" "$root_target/etc/modules" 2>/dev/null; then
      echo "virtiofs" | sudo tee -a "$root_target/etc/modules" >/dev/null
    fi
  fi

  # Clean and configure config.boot across all filesystem locations
  local cfg_boot_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && cfg_boot_files+=("$f")
  done < <(sudo find "$mnt" -type f -name "config.boot" 2>/dev/null || true)

  for CFG_BOOT in "${cfg_boot_files[@]}"; do
    [ -f "$CFG_BOOT" ] || continue
    log "Sanitizing and prepping VyOS config: $CFG_BOOT..."
    # Strip stale hardware MAC IDs and any old ethernet interface definitions
    sudo sed -i '/^[[:space:]]*hw-id[[:space:]]/d' "$CFG_BOOT" 2>/dev/null || true
    sudo awk '
      /^[[:space:]]*ethernet eth[0-9]+ \{/ { skip=1; brace_count=1; next }
      skip {
        for (i=1; i<=length($0); i++) {
          c = substr($0, i, 1)
          if (c == "{") brace_count++
          if (c == "}") brace_count--
        }
        if (brace_count == 0) { skip=0 }
        next
      }
      { print }
    ' "$CFG_BOOT" | sudo tee "${CFG_BOOT}.tmp" >/dev/null && sudo mv -f "${CFG_BOOT}.tmp" "$CFG_BOOT"

    # Ensure serial console is defined in VyOS config.boot
    if ! grep -q "ttyS0" "$CFG_BOOT" 2>/dev/null; then
      sudo sed -i '/console {/a \        device ttyS0 {\n            speed 115200\n        }' "$CFG_BOOT" 2>/dev/null || true
    fi

    # Ensure system name-servers are pre-baked into config.boot
    if ! grep -q "name-server" "$CFG_BOOT" 2>/dev/null; then
      sudo sed -i '/system {/a \    name-server 1.1.1.1\n    name-server 8.8.8.8' "$CFG_BOOT" 2>/dev/null || true
    fi
  done

  # Inject custom VyOS files declared in manifest (local_path or url)
  local num_vfiles
  num_vfiles=$(jq '.vyos.files // [] | length' <<< "$MANIFEST_JSON")
  if [ "$num_vfiles" -gt 0 ]; then
    log "Injecting ${num_vfiles} custom files into VyOS root filesystem..."
    for ((i=0; i<num_vfiles; i++)); do
      local f_json
      f_json=$(jq -c ".vyos.files[$i]" <<< "$MANIFEST_JSON")
      local f_url
      f_url=$(jq -r '.url // empty' <<< "$f_json")
      local f_local
      f_local=$(jq -r '.local_path // .src // empty' <<< "$f_json")
      local f_dest
      f_dest=$(jq -r '.dest' <<< "$f_json")
      local f_mode
      f_mode=$(jq -r '.mode // "0644"' <<< "$f_json")

      local dest_path="${root_target}/${f_dest#/}"
      sudo mkdir -p "$(dirname "$dest_path")"

      if [ -n "$f_local" ]; then
        local src_file="$f_local"
        if [ ! -f "$src_file" ] && [ -f "/host${src_file}" ]; then
          src_file="/host${src_file}"
        fi
        [[ "$src_file" != /* ]] && src_file="${SCRIPT_DIR}/${src_file}"
        if [ ! -f "$src_file" ] && [ -f "/host${src_file}" ]; then
          src_file="/host${src_file}"
        fi
        if [ -f "$src_file" ]; then
          sudo cp -f "$src_file" "$dest_path"
          sudo chmod "$f_mode" "$dest_path"
          log "Injected VyOS custom file: ${f_local} -> ${f_dest} (${f_mode})"
        else
          err "VyOS custom file declared in manifest not found: ${src_file}"
        fi
      elif [ -n "$f_url" ]; then
        log "Downloading custom VyOS file: ${f_url} -> ${f_dest}..."
        if ! sudo curl -fsSL "$f_url" -o "$dest_path"; then
          err "Failed to download custom VyOS file from URL: ${f_url}"
        fi
        sudo chmod "$f_mode" "$dest_path"
      fi
    done
  fi

  # Unmount NBD and cleanly disconnect
  sudo umount "$mnt"
  VYOS_MNT_DIR=""
  sudo qemu-nbd --disconnect "$CURRENT_NBD_DEV" 2>/dev/null || true
  CURRENT_NBD_DEV=""

  # Generate Checksum
  (cd "$OUTPUT_DIR" && sha256sum "$(basename "$golden_disk")" > "${golden_disk}.sha256")
  log "VyOS Golden Master Disk built successfully at: ${golden_disk}"
  generate_provenance_manifest "${OUTPUT_DIR}/provenance.json"
}

# ==============================================================================
# STEP 2: Build Enterprise Appliance ISO & Package Containers
# ==============================================================================
build_iso() {
  log "================================================================="
  log "STEP 2: Building Enterprise Appliance ISO & Containers"
  log "================================================================="

  local golden_disk="${OUTPUT_DIR}/vyos-golden.qcow2"
  if [ ! -f "$golden_disk" ] && [ -f "${BUILD_DIR}/vyos/vyos-golden.qcow2" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp -f "${BUILD_DIR}/vyos/vyos-golden.qcow2"* "$OUTPUT_DIR/" 2>/dev/null || true
  fi
  if [ ! -f "$golden_disk" ]; then
    err "Cannot build ISO: ${golden_disk} is missing. Run without --iso-only first."
  fi

  local base_iso="${CACHE_DIR}/ubuntu-${UBUNTU_RELEASE}-live-server-amd64.iso"
  [ ! -f "$base_iso" ] && [ -f "${BUILD_DIR}/iso/cache/ubuntu-${UBUNTU_RELEASE}-live-server-amd64.iso" ] && base_iso="${BUILD_DIR}/iso/cache/ubuntu-${UBUNTU_RELEASE}-live-server-amd64.iso"
  if [ ! -f "$base_iso" ]; then
    if [ -n "$UBUNTU_ISO_URL" ]; then
      log "Downloading Ubuntu ${UBUNTU_RELEASE} base ISO from $UBUNTU_ISO_URL..."
      curl --fail -L -C - -o "$base_iso" "$UBUNTU_ISO_URL"
    else
      err "Ubuntu base ISO not found at $base_iso and no host.ubuntu_iso_url configured."
    fi
  fi

  # Validate Ubuntu base ISO checksum if declared
  if [ -n "$UBUNTU_ISO_SHA256" ]; then
    log "Verifying SHA-256 checksum for Ubuntu base ISO: ${base_iso}..."
    local act_iso_sha
    act_iso_sha=$(sha256sum "$base_iso" | awk '{print $1}')
    if [ "$act_iso_sha" != "$UBUNTU_ISO_SHA256" ]; then
      err "Ubuntu base ISO SHA-256 checksum mismatch! Expected: ${UBUNTU_ISO_SHA256}, Got: ${act_iso_sha}"
    fi
    log "Ubuntu base ISO checksum verified [OK]."
  fi

  local iso_extract="${WORK_DIR}/iso_extract"
  local payload_dir="${iso_extract}/olg-payload"
  mkdir -p "$payload_dir"/{scripts,tools,config,systemd,images,docker-cache,debs}

  # Extract Base ISO
  log "Extracting base Ubuntu installer ISO..."
  7z x "$base_iso" "-o$iso_extract" >/dev/null

  # Stage configs, scripts, and systemd
  cp -a "$SCRIPT_DIR/scripts"/* "$payload_dir/scripts/" 2>/dev/null || true
  cp -a "$SCRIPT_DIR/config"/* "$payload_dir/config/" 2>/dev/null || true
  cp -a "$SCRIPT_DIR/systemd"/* "$payload_dir/systemd/" 2>/dev/null || true

  # Extract host configuration from manifest
  local host_json
  host_json=$(jq -c '.host' <<< "$MANIFEST_JSON")

  # Resolve authoritative model hardware profile from manifest if specified
  local hw_profile
  hw_profile=$(jq -r '.hardware_profile // empty' <<< "$host_json")
  if [ -n "$hw_profile" ]; then
    local hw_path="$hw_profile"
    if [ ! -f "$hw_path" ] && [ -f "/host${hw_path}" ]; then
      hw_path="/host${hw_path}"
    fi
    [[ "$hw_path" != /* ]] && hw_path="${SCRIPT_DIR}/${hw_path}"
    if [ ! -f "$hw_path" ] && [ -f "/host${hw_path}" ]; then
      hw_path="/host${hw_path}"
    fi
    if [ -f "$hw_path" ]; then
      log "Bundling model hardware profile: ${hw_profile} -> /etc/olg/hardware-profile.json"
      cp -f "$hw_path" "$payload_dir/config/hardware-profile.json"
    else
      err "Specified hardware profile not found: ${hw_path}"
    fi
  fi

  # Process Host Binaries from manifest
  local num_host_binaries
  num_host_binaries=$(jq 'if .binaries then (.binaries | length) else 0 end' <<< "$host_json")

  if [ "$num_host_binaries" -gt 0 ]; then
    log "Processing ${num_host_binaries} Host binaries..."
    for ((i=0; i<num_host_binaries; i++)); do
      local hb_json
      hb_json=$(jq -c ".binaries[$i]" <<< "$host_json")
      local hb_name
      hb_name=$(jq -r '.name' <<< "$hb_json")
      local hb_type
      hb_type=$(jq -r '.type' <<< "$hb_json")
      local hb_dest
      hb_dest=$(jq -r '.dest // "tools/" + .name' <<< "$hb_json")
      local hb_local
      hb_local=$(jq -r '.local_path // empty' <<< "$hb_json")
      local hb_repo
      hb_repo=$(jq -r '.repo // empty' <<< "$hb_json")
      local hb_ref
      hb_ref=$(jq -r '.ref // "main"' <<< "$hb_json")
      local hb_url
      hb_url=$(jq -r '.url // empty' <<< "$hb_json")

      log "Compiling Host binary: ${hb_name} [${hb_type}] -> ${hb_dest}"
      local hb_src_dir="${WORK_DIR}/hsrc_${hb_name}"
      mkdir -p "$hb_src_dir"

      # Determine source
      if [ -n "$hb_local" ] && [ -f "${SCRIPT_DIR}/${hb_local}" ]; then
        local local_file_dir
        local_file_dir="$(dirname "${SCRIPT_DIR}/${hb_local}")"
        if [ -f "${local_file_dir}/go.mod" ]; then
          cp -r "${local_file_dir}"/* "$hb_src_dir/"
        else
          cp "${SCRIPT_DIR}/${hb_local}" "$hb_src_dir/"
        fi
      elif [ -n "$hb_local" ] && [ -d "${SCRIPT_DIR}/${hb_local}" ]; then
        cp -r "${SCRIPT_DIR}/${hb_local}"/* "$hb_src_dir/"
      elif [ -n "$hb_repo" ]; then
        git clone --depth 1 --branch "$hb_ref" "$hb_repo" "$hb_src_dir" 2>/dev/null || \
          (git clone "$hb_repo" "$hb_src_dir" && cd "$hb_src_dir" && git checkout "$hb_ref")
      elif [ -n "$hb_url" ]; then
        curl -f -sL "$hb_url" | tar -xz -C "$hb_src_dir" --strip-components=1
      fi

      # Apply patches if defined
      resolve_and_apply_patches "$hb_json" "$hb_src_dir"

      # Record provenance for Host binary
      local hb_actual_commit="local"
      if [ -d "$hb_src_dir/.git" ]; then
        hb_actual_commit=$(git -C "$hb_src_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
      fi
      mkdir -p "${PROVENANCE_DIR}"
      jq -n \
        --arg name "$hb_name" \
        --arg type "$hb_type" \
        --arg repo "${hb_repo:-local}" \
        --arg ref "${hb_ref:-}" \
        --arg commit "$hb_actual_commit" \
        --arg dest "$hb_dest" \
        '{name: $name, type: $type, repo: $repo, ref: $ref, commit_sha: $commit, dest: $dest}' \
        > "${PROVENANCE_DIR}/host_bin_${i}.json"

      # Ensure destination directory inside payload
      local target_out="${payload_dir}/${hb_dest#/}"
      mkdir -p "$(dirname "$target_out")"

      case "$hb_type" in
        go)
          local hb_build_cmd
          hb_build_cmd=$(jq -r '.build_cmd // empty' <<< "$hb_json")
          if [ -z "$hb_build_cmd" ]; then
            err "Host binary '${hb_name}' is missing required 'build_cmd' in ${MANIFEST_FILE}."
          fi
          local cmd="${hb_build_cmd//\{output\}/\"$target_out\"}"
          (cd "$hb_src_dir" && eval "$cmd")
          ;;
        cmake|make)
          (cd "$hb_src_dir" && cmake . && make -j"$(nproc)" && cp "$hb_name" "$target_out")
          ;;
        *)
          err "Unsupported host binary compilation type: $hb_type for $hb_name"
          ;;
      esac
      chmod 0755 "$target_out"
    done
  else
    # Fallback default: Compile native host bootstrap tools if not explicitly in manifest
    log "Compiling default native Go bootstrap binaries..."
    (cd "$SCRIPT_DIR/tools" && CGO_ENABLED=0 go build -o "$payload_dir/tools/nats_pki_bootstrap" nats_pki_bootstrap.go)
    (cd "$SCRIPT_DIR/tools" && CGO_ENABLED=0 go build -o "$payload_dir/tools/nats_kv_pusher" nats_kv_pusher.go)
    mkdir -p "${PROVENANCE_DIR}"
    jq -n \
      --arg name "nats_pki_bootstrap" \
      --arg type "go" \
      --arg repo "local" \
      --arg commit "local" \
      --arg dest "tools/nats_pki_bootstrap" \
      '{name: $name, type: $type, repo: $repo, ref: "local", commit_sha: $commit, dest: $dest}' \
      > "${PROVENANCE_DIR}/host_bin_0.json"
    jq -n \
      --arg name "nats_kv_pusher" \
      --arg type "go" \
      --arg repo "local" \
      --arg commit "local" \
      --arg dest "tools/nats_kv_pusher" \
      '{name: $name, type: $type, repo: $repo, ref: "local", commit_sha: $commit, dest: $dest}' \
      > "${PROVENANCE_DIR}/host_bin_1.json"
  fi

  # Bundle VyOS golden disk
  log "Bundling VyOS Golden Disk into ISO payload..."
  cp "$golden_disk" "$payload_dir/images/vyos-golden.qcow2"
  cp "${golden_disk}.sha256" "$payload_dir/images/vyos-golden.qcow2.sha256"

  # Process Host Containers from manifest
  local host_json
  host_json=$(jq -c '.host' <<< "$MANIFEST_JSON")
  local num_containers
  num_containers=$(jq '.containers | length' <<< "$host_json")

  for ((i=0; i<num_containers; i++)); do
    local c_json
    c_json=$(jq -c ".containers[$i]" <<< "$host_json")
    local c_name
    c_name=$(jq -r '.name' <<< "$c_json")
    local c_type
    c_type=$(jq -r '.type' <<< "$c_json")
    local c_tag
    c_tag=$(jq -r '.tag // .image' <<< "$c_json")
    local c_tar
    c_tar=$(jq -r '.cache_tar' <<< "$c_json")
    local c_local
    c_local=$(jq -r '.local_path // empty' <<< "$c_json")
    local c_repo
    c_repo=$(jq -r '.repo // empty' <<< "$c_json")
    local c_ref
    c_ref=$(jq -r '.ref // "main"' <<< "$c_json")

    log "Processing Host Container: ${c_name} [${c_type}] -> ${c_tag}"
    case "$c_type" in
      docker-build)
        local c_src="${WORK_DIR}/csrc_${c_name}"
        mkdir -p "$c_src"
        if [ -n "$c_local" ] && [ -d "${SCRIPT_DIR}/${c_local}" ]; then
          log "Using local repository for ${c_name} from ${SCRIPT_DIR}/${c_local}..."
          cp -a "${SCRIPT_DIR}/${c_local}/." "$c_src/"
        elif [ -n "$c_repo" ]; then
          log "Cloning ${c_name} from ${c_repo} (${c_ref})..."
          git clone --depth 1 --branch "$c_ref" "$c_repo" "$c_src" 2>/dev/null || \
            (git clone "$c_repo" "$c_src" && cd "$c_src" && git checkout "$c_ref")
        fi
        # Resolve and apply patches if declared
        resolve_and_apply_patches "$c_json" "$c_src"
        log "Building container ${c_tag} via Docker..."
        docker build --no-cache -t "$c_tag" "$c_src"
        mkdir -p "$(dirname "${payload_dir}/${c_tar}")"
        docker save "$c_tag" -o "${payload_dir}/${c_tar}"

        local c_actual_commit="local"
        if [ -d "$c_src/.git" ]; then
          c_actual_commit=$(git -C "$c_src" rev-parse HEAD 2>/dev/null || echo "unknown")
        fi
        local c_img_id
        c_img_id=$(docker inspect --format='{{.Id}}' "$c_tag" 2>/dev/null || echo "unknown")

        mkdir -p "${PROVENANCE_DIR}"
        jq -n \
          --arg name "$c_name" \
          --arg type "$c_type" \
          --arg tag "$c_tag" \
          --arg repo "${c_repo:-local}" \
          --arg ref "${c_ref:-}" \
          --arg commit "$c_actual_commit" \
          --arg image_id "$c_img_id" \
          --arg cache_tar "$c_tar" \
          '{name: $name, type: $type, tag: $tag, repo: $repo, ref: $ref, commit_sha: $commit, image_id: $image_id, cache_tar: $cache_tar}' \
          > "${PROVENANCE_DIR}/container_${i}.json"
        ;;
      docker-pull)
        local img
        img=$(jq -r '.image' <<< "$c_json")
        log "Pulling and pre-caching image ${img}..."
        docker pull "$img"
        mkdir -p "$(dirname "${payload_dir}/${c_tar}")"
        docker save "$img" -o "${payload_dir}/${c_tar}"

        local p_img_id
        p_img_id=$(docker inspect --format='{{.Id}}' "$img" 2>/dev/null || echo "unknown")
        local p_digest
        p_digest=$(docker inspect --format='{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$img" 2>/dev/null | head -n1 || echo "")
        [ -z "$p_digest" ] && p_digest="none"

        mkdir -p "${PROVENANCE_DIR}"
        jq -n \
          --arg name "$c_name" \
          --arg type "$c_type" \
          --arg image "$img" \
          --arg image_id "$p_img_id" \
          --arg digest "$p_digest" \
          --arg cache_tar "$c_tar" \
          '{name: $name, type: $type, image: $image, image_id: $image_id, digest: $digest, cache_tar: $cache_tar}' \
          > "${PROVENANCE_DIR}/container_${i}.json"
        ;;
    esac
  done

  # Cache offline deb packages and generate local repository metadata
  log "Pre-caching offline Debian packages for 100% air-gapped installation..."
  local deb_cache="${CACHE_DIR}/debs"
  mkdir -p "$deb_cache"
  local pkgs_list
  pkgs_list=$(jq -r '.offline_packages // [] | sort | .[]' <<< "$host_json" | tr '\n' ' ' | xargs)
  [ -z "$pkgs_list" ] && pkgs_list="ca-certificates containerd curl docker-compose-v2 docker.io iproute2 jq libvirt-clients libvirt-daemon-system netplan.io openssl pciutils qemu-system-x86 runc virtiofsd"

  local cache_sig_file="$deb_cache/.cache_signature"
  local expected_sig
  expected_sig=$(printf "%s\n%s" "${UBUNTU_RELEASE}" "${pkgs_list}" | sha256sum | awk '{print $1}')

  local cache_valid=false
  local cache_reason=""

  if [ "$REFRESH_DEBS" = true ]; then
    cache_reason="Explicit --refresh-debs flag requested"
  elif [ ! -f "$cache_sig_file" ]; then
    cache_reason="Cache signature file (.cache_signature) missing"
  elif [ ! -f "$deb_cache/Packages.gz" ]; then
    cache_reason="Packages.gz index missing"
  else
    local current_sig
    current_sig=$(cat "$cache_sig_file" 2>/dev/null || echo "")
    if [ "$current_sig" != "$expected_sig" ]; then
      cache_reason="Manifest signature mismatch (Ubuntu release or package list changed)"
    else
      log "Validating integrity of cached Debian packages against Packages.gz..."
      local val_output
      if val_output=$(python3 -c "
import gzip, os, hashlib, sys

cache_dir = sys.argv[1]
packages_gz = os.path.join(cache_dir, 'Packages.gz')

try:
    with gzip.open(packages_gz, 'rt', encoding='utf-8', errors='replace') as f:
        content = f.read()
except Exception as e:
    print(f'Failed to read Packages.gz: {e}')
    sys.exit(1)

stanzas = [s for s in content.strip().split('\n\n') if s.strip()]
if not stanzas:
    print('Packages.gz is empty or contains no package stanzas')
    sys.exit(1)

checked = 0
for s in stanzas:
    fields = {}
    for line in s.splitlines():
        if line and line[0] not in ' \t' and ':' in line:
            k, v = line.split(':', 1)
            fields[k.strip()] = v.strip()

    fname = fields.get('Filename')
    size_str = fields.get('Size')
    exp_sha = fields.get('SHA256')
    pkg = fields.get('Package', 'unknown')

    if not fname or not size_str or not exp_sha:
        print(f'Package entry for {pkg} is missing Filename, Size, or SHA256')
        sys.exit(1)

    rel_name = fname[2:] if fname.startswith('./') else fname
    deb_path = os.path.join(cache_dir, rel_name)

    if not os.path.isfile(deb_path):
        print(f'Missing cached package file: {rel_name}')
        sys.exit(1)

    try:
        act_size = os.path.getsize(deb_path)
        if act_size != int(size_str):
            print(f'Size mismatch for {rel_name}: expected {size_str}, got {act_size}')
            sys.exit(1)
    except ValueError:
        print(f'Invalid Size field in Packages.gz for {rel_name}: {size_str}')
        sys.exit(1)

    h = hashlib.sha256()
    with open(deb_path, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    act_sha = h.hexdigest()
    if act_sha != exp_sha:
        print(f'SHA256 mismatch for {rel_name}: expected {exp_sha}, got {act_sha}')
        sys.exit(1)

    checked += 1

if checked == 0:
    print('No packages were checked')
    sys.exit(1)

print(f'SUCCESS:{checked}')
" "$deb_cache" 2>&1); then
        cache_valid=true
        local checked_count
        checked_count=$(echo "$val_output" | sed -n 's/^SUCCESS://p')
        log "Package cache integrity verified: ${checked_count} packages matched Packages.gz [OK]."
      else
        cache_reason="Integrity check failed: ${val_output}"
      fi
    fi
  fi

  if [ "$cache_valid" = "false" ]; then
    warn "Offline Debian package cache invalid or refresh needed (${cache_reason})."
    log "Regenerating full package closure for Ubuntu ${UBUNTU_RELEASE} inside container sandbox..."
    rm -rf "$deb_cache"/* "$deb_cache"/.cache_signature
    docker run --rm \
      -v "${deb_cache}:/debs" \
      "ubuntu:${UBUNTU_RELEASE}" bash -c "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends apt-utils >/dev/null 2>&1 || true
        # Use clean dpkg status file so APT resolves and downloads all dependencies (including base libraries)
        touch /tmp/empty_status
        apt-get install --download-only -y \
          -o Dir::State::status=/tmp/empty_status \
          -o Dir::Cache::archives=/debs ${pkgs_list}
        rm -f /debs/lock 2>/dev/null || true
        rm -rf /debs/partial /debs/*_i386.deb 2>/dev/null || true
        chmod 0644 /debs/*.deb 2>/dev/null || true
        (cd /debs && apt-ftparchive packages . | gzip -9c > Packages.gz)
        chmod 0644 /debs/Packages.gz
      "
    echo "$expected_sig" > "$cache_sig_file"
    log "Successfully regenerated offline Debian package cache."
  fi

  # Record offline package metadata (names, versions, checksums) for provenance manifest
  mkdir -p "${PROVENANCE_DIR}"
  python3 -c "
import gzip, os, json, sys

cache_dir = sys.argv[1]
out_file = sys.argv[2]
packages_gz = os.path.join(cache_dir, 'Packages.gz')

with gzip.open(packages_gz, 'rt', encoding='utf-8', errors='replace') as f:
    content = f.read()

stanzas = [s for s in content.strip().split('\n\n') if s.strip()]
pkgs = []
for s in stanzas:
    fields = {}
    for line in s.splitlines():
        if line and line[0] not in ' \t' and ':' in line:
            k, v = line.split(':', 1)
            fields[k.strip()] = v.strip()

    fname = fields.get('Filename', '')
    rel_name = fname[2:] if fname.startswith('./') else fname
    pkgs.append({
        'package': fields.get('Package', ''),
        'version': fields.get('Version', ''),
        'architecture': fields.get('Architecture', ''),
        'filename': rel_name,
        'size': int(fields.get('Size', 0)),
        'sha256': fields.get('SHA256', '')
    })

pkgs.sort(key=lambda x: x['package'])
with open(out_file, 'w', encoding='utf-8') as f:
    json.dump(pkgs, f, indent=2)
" "$deb_cache" "${PROVENANCE_DIR}/offline_packages.json"

  cp -f "$deb_cache"/*.deb "$deb_cache"/Packages.gz "$payload_dir/debs/" 2>/dev/null || true
  rm -f "$payload_dir/debs"/*_i386.deb 2>/dev/null || true
  log "Cached $(ls "$payload_dir/debs"/*.deb 2>/dev/null | wc -l) offline packages with local repository index."

  # Process and stage custom host files from manifest (local_path or url)
  local num_hfiles
  num_hfiles=$(jq '.files // [] | length' <<< "$host_json")
  if [ "$num_hfiles" -gt 0 ]; then
    log "Bundling ${num_hfiles} custom host files into ISO payload..."
    local custom_staging="${payload_dir}/custom-files"
    mkdir -p "$custom_staging/root"
    local perm_script="$custom_staging/apply_permissions.sh"
    cat <<'EOF_PERM' > "$perm_script"
#!/bin/bash
set -e
TARGET_ROOT="${1:-/target}"
EOF_PERM

    for ((i=0; i<num_hfiles; i++)); do
      local f_json
      f_json=$(jq -c ".files[$i]" <<< "$host_json")
      local f_url
      f_url=$(jq -r '.url // empty' <<< "$f_json")
      local f_local
      f_local=$(jq -r '.local_path // .src // empty' <<< "$f_json")
      local f_dest
      f_dest=$(jq -r '.dest' <<< "$f_json")
      local f_mode
      f_mode=$(jq -r '.mode // "0644"' <<< "$f_json")

      local target_stage="${custom_staging}/root/${f_dest#/}"
      mkdir -p "$(dirname "$target_stage")"

      if [ -n "$f_local" ]; then
        local src_file="$f_local"
        if [ ! -f "$src_file" ] && [ -f "/host${src_file}" ]; then
          src_file="/host${src_file}"
        fi
        [[ "$src_file" != /* ]] && src_file="${SCRIPT_DIR}/${src_file}"
        if [ ! -f "$src_file" ] && [ -f "/host${src_file}" ]; then
          src_file="/host${src_file}"
        fi
        if [ -f "$src_file" ]; then
          cp -f "$src_file" "$target_stage"
          chmod "$f_mode" "$target_stage"
          echo "chmod ${f_mode} \"\${TARGET_ROOT}/${f_dest#/}\"" >> "$perm_script"
          log "Staged custom file: ${f_local} -> ${f_dest} (${f_mode})"
        else
          err "Custom host file declared in manifest not found: ${src_file}"
        fi
      elif [ -n "$f_url" ]; then
        log "Downloading custom host file: ${f_url} -> ${f_dest}..."
        if ! curl -fsSL "$f_url" -o "$target_stage"; then
          err "Failed to download custom host file from URL: ${f_url}"
        fi
        chmod "$f_mode" "$target_stage"
        echo "chmod ${f_mode} \"\${TARGET_ROOT}/${f_dest#/}\"" >> "$perm_script"
        log "Staged downloaded file: ${f_url} -> ${f_dest} (${f_mode})"
      fi
    done
    chmod 0755 "$perm_script"
  fi

  # Copy finish_install.sh post-install late command hook
  if [ -f "$BUILD_DIR/iso/scripts/finish_install.sh" ]; then
    cp -f "$BUILD_DIR/iso/scripts/finish_install.sh" "$payload_dir/finish_install.sh"
    chmod 0755 "$payload_dir/finish_install.sh"
  fi

  # Copy GRUB bootloader and autoinstall files
  cp -f "$BUILD_DIR/iso/grub/grub.cfg" "$iso_extract/boot/grub/grub.cfg" 2>/dev/null || true
  mkdir -p "$iso_extract/EFI/boot" "$iso_extract/EFI/BOOT" 2>/dev/null || true
  cp -f "$BUILD_DIR/iso/grub/grub.cfg" "$iso_extract/EFI/boot/grub.cfg" 2>/dev/null || true
  cp -f "$BUILD_DIR/iso/grub/grub.cfg" "$iso_extract/EFI/BOOT/grub.cfg" 2>/dev/null || true

  # Inject autoinstall user-data into all standard search paths (/autoinstall, /nocloud, and root /)
  mkdir -p "$iso_extract/autoinstall" "$iso_extract/nocloud"
  cp -f "$BUILD_DIR/iso/autoinstall/user-data" "$iso_extract/autoinstall/user-data"
  cp -f "$BUILD_DIR/iso/autoinstall/meta-data" "$iso_extract/autoinstall/meta-data"
  cp -f "$BUILD_DIR/iso/autoinstall/user-data" "$iso_extract/nocloud/user-data"
  cp -f "$BUILD_DIR/iso/autoinstall/meta-data" "$iso_extract/nocloud/meta-data"
  cp -f "$BUILD_DIR/iso/autoinstall/user-data" "$iso_extract/user-data"
  cp -f "$BUILD_DIR/iso/autoinstall/meta-data" "$iso_extract/meta-data"

  # Inspect source ISO boot layout and extract boot metadata dynamically using xorriso
  log "Inspecting source ISO boot metadata via xorriso: ${base_iso}..."
  local xorriso_report
  if ! xorriso_report=$(xorriso -indev "$base_iso" -report_system_area as_mkisofs 2>/dev/null); then
    err "Failed to inspect source ISO boot metadata via xorriso from: ${base_iso}"
  fi

  local part_num=""
  local part_guid=""
  local start_sec=""
  local end_sec=""
  local count_sec=""

  local append_line
  append_line=$(grep -E -- '^[[:space:]]*-append_partition[[:space:]]' <<< "$xorriso_report" | head -n 1)
  if [[ "$append_line" =~ -append_partition[[:space:]]+([0-9]+)[[:space:]]+([a-zA-Z0-9_-]+)[[:space:]]+--interval:[^:]*:([0-9]+)d-([0-9]+)d ]]; then
    part_num="${BASH_REMATCH[1]}"
    part_guid="${BASH_REMATCH[2]}"
    start_sec="${BASH_REMATCH[3]}"
    end_sec="${BASH_REMATCH[4]}"
    count_sec=$((end_sec - start_sec + 1))
    log "Discovered EFI partition from xorriso: partition ${part_num}, GUID ${part_guid}, sector ${start_sec} to ${end_sec} (${count_sec} sectors)."
  fi

  # Fail safely if EFI partition could not be reliably identified (NO hardcoded fallback)
  if [ -z "$part_num" ] || [ -z "$part_guid" ] || [ -z "$start_sec" ] || [ -z "$count_sec" ] || [ "$count_sec" -le 0 ]; then
    err "Failed to discover EFI boot partition metadata (partition number, GUID, sector range) from base ISO: ${base_iso}."
  fi

  # Discover MBR and El Torito boot metadata from xorriso report
  local mbr_part_type=""
  if [[ "$xorriso_report" =~ -iso_mbr_part_type[[:space:]]+([a-zA-Z0-9]+) ]]; then
    mbr_part_type="${BASH_REMATCH[1]}"
  fi

  local eltorito_boot_img="boot/grub/i386-pc/eltorito.img"
  if [[ "$xorriso_report" =~ -b[[:space:]]+[\'\"]?([^[:space:]\'\"]+)[\'\"]? ]]; then
    eltorito_boot_img="${BASH_REMATCH[1]#/}"
  fi

  local has_grub2_mbr=false
  if grep -q -- '--grub2-mbr' <<< "$xorriso_report"; then
    has_grub2_mbr=true
  fi

  # Extract EFI boot image
  local efi_img="${WORK_DIR}/boot-efi.img"
  log "Extracting EFI boot image from ${base_iso} (partition ${part_num}, sector ${start_sec}, count ${count_sec})..."
  if ! dd if="$base_iso" bs=512 skip="$start_sec" count="$count_sec" of="$efi_img" status=none conv=fsync; then
    err "Failed to extract EFI boot image from ${base_iso} at sector offset ${start_sec}."
  fi

  # Validate that the extracted EFI boot image is complete and valid
  log "Validating extracted EFI boot image integrity..."
  [ -f "$efi_img" ] && [ -s "$efi_img" ] || err "Extracted EFI boot image is missing or empty: ${efi_img}"

  local expected_bytes=$((count_sec * 512))
  local actual_bytes
  actual_bytes=$(stat -c%s "$efi_img" 2>/dev/null || wc -c < "$efi_img")
  if [ "$actual_bytes" -ne "$expected_bytes" ]; then
    err "Extracted EFI image size mismatch: expected ${expected_bytes} bytes (${count_sec} sectors), got ${actual_bytes} bytes."
  fi

  local file_type
  file_type=$(file -b "$efi_img" 2>/dev/null || true)
  if ! grep -qiE 'FAT|DOS[ /]MBR boot sector' <<< "$file_type"; then
    err "Extracted EFI image is not a valid FAT/DOS filesystem (type: ${file_type})."
  fi

  local efi_contents
  if ! efi_contents=$(7z l "$efi_img" 2>/dev/null); then
    err "Extracted EFI image is corrupted or unreadable by 7z archive reader."
  fi
  if ! grep -qiE 'bootx64\.efi|grubx64\.efi' <<< "$efi_contents"; then
    err "Extracted EFI image is missing essential UEFI 64-bit bootloader binaries (bootx64.efi/grubx64.efi)."
  fi
  log "Extracted EFI boot image validated successfully (${actual_bytes} bytes, FAT filesystem, verified UEFI bootloader) [OK]."

  # Generate artifact provenance manifest and embed into appliance payload
  log "Generating artifact provenance manifest..."
  generate_provenance_manifest "${payload_dir}/config/provenance.json"

  # Package final hybrid ISO using discovered metadata
  local final_iso="${OUTPUT_DIR}/olg-enterprise-appliance-${UBUNTU_RELEASE}.iso"
  log "Packaging final ISO with xorriso: ${final_iso}..."

  local xorriso_cmd=(
    xorriso -as mkisofs
    -r -V "OLG_ENTERPRISE_INSTALL"
  )

  if [ "$has_grub2_mbr" = true ]; then
    xorriso_cmd+=(--grub2-mbr "--interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:${base_iso}")
  fi

  xorriso_cmd+=(
    --protective-msdos-label
    -partition_cyl_align off
    -partition_offset 16
    --mbr-force-bootable
    -append_partition "$part_num" "$part_guid" "$efi_img"
    -appended_part_as_gpt
  )

  if [ -n "$mbr_part_type" ]; then
    xorriso_cmd+=(-iso_mbr_part_type "$mbr_part_type")
  fi

  xorriso_cmd+=(
    -c /boot.catalog
    -b "$eltorito_boot_img"
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info
    -eltorito-alt-boot
    -e "--interval:appended_partition_${part_num}:all::"
    -no-emul-boot
    -o "$final_iso"
    "$iso_extract"
  )

  "${xorriso_cmd[@]}"

  (cd "$OUTPUT_DIR" && sha256sum "$(basename "$final_iso")" > "${final_iso}.sha256")
  generate_provenance_manifest "${OUTPUT_DIR}/provenance.json" "$final_iso"
  log "Enterprise Appliance ISO created successfully at: ${final_iso}"
}

# Run Steps
[ "$MODE_VYOS" = true ] && build_vyos
[ "$MODE_ISO" = true ] && build_iso

echo "================================================================="
log "ALL BUILDS COMPLETE!"
echo " Output Artifacts:"
ls -lh "$OUTPUT_DIR"
echo "================================================================="