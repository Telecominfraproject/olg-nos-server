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
      echo -e "\033[1;32m[OLG-BUILD]\033[0m Initializing container packages (go, qemu, xorriso, docker, ssh, patch, python3-yaml, pexpect, squashfs)..."
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        golang-go qemu-utils qemu-system-x86 xorriso p7zip-full docker.io \
        curl git jq python3 python3-yaml python3-pexpect ca-certificates kmod file bc sudo \
        openssh-client patch squashfs-tools
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
CLI_BUILD_MODE=""

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

OpenLAN Gateway (OLG) Master Unified Appliance Builder

Options:
  --dev                 Build in development mode (enables default 'vyos' credentials for local testing)
  --production          Build in production mode (default: secure-by-default, no reusable default credentials)
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
    --dev)
      CLI_BUILD_MODE="dev"
      shift
      ;;
    --production)
      CLI_BUILD_MODE="production"
      shift
      ;;
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

# Determine Firmware Build Mode (production vs dev)
CONFIG_BUILD_MODE=$(jq -r '.build_mode // "production"' <<< "$MANIFEST_JSON")
BUILD_MODE="${CLI_BUILD_MODE:-$CONFIG_BUILD_MODE}"
if [ "$BUILD_MODE" != "dev" ] && [ "$BUILD_MODE" != "production" ]; then
  err "Invalid build_mode: '$BUILD_MODE' (must be 'dev' or 'production')"
fi
log "Firmware build mode configured: [${BUILD_MODE^^}] (CLI: '${CLI_BUILD_MODE:-none}', Manifest: '${CONFIG_BUILD_MODE}')"

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
REQUIRED_TOOLS=(xorriso 7z sha256sum curl go docker qemu-img qemu-nbd qemu-system-x86_64 patch git jq unsquashfs python3)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done

MISSING_PY_MODULES=()
if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c "import pexpect" >/dev/null 2>&1; then
    MISSING_PY_MODULES+=(python3-pexpect)
  fi
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ] || [ ${#MISSING_PY_MODULES[@]} -gt 0 ]; then
  pkgs_to_install=()
  for t in "${MISSING_TOOLS[@]}"; do
    case "$t" in
      xorriso) pkgs_to_install+=(xorriso) ;;
      7z) pkgs_to_install+=(p7zip-full) ;;
      curl) pkgs_to_install+=(curl) ;;
      go) pkgs_to_install+=(golang-go) ;;
      docker) pkgs_to_install+=(docker.io) ;;
      qemu-img|qemu-nbd) pkgs_to_install+=(qemu-utils) ;;
      qemu-system-x86_64) pkgs_to_install+=(qemu-system-x86) ;;
      patch) pkgs_to_install+=(patch) ;;
      git) pkgs_to_install+=(git) ;;
      jq) pkgs_to_install+=(jq) ;;
      unsquashfs) pkgs_to_install+=(squashfs-tools) ;;
      python3) pkgs_to_install+=(python3) ;;
    esac
  done
  for m in "${MISSING_PY_MODULES[@]}"; do
    pkgs_to_install+=("$m")
  done
  pkgs_to_install=($(printf "%s\n" "${pkgs_to_install[@]}" | sort -u))

  if [ "${EUID:-$(id -u)}" -eq 0 ] || command -v sudo >/dev/null 2>&1; then
    log "Auto-installing missing dependencies: ${MISSING_TOOLS[*]} ${MISSING_PY_MODULES[*]} (${pkgs_to_install[*]})..."
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs_to_install[@]}"
  else
    err "Missing dependencies: ${MISSING_TOOLS[*]} ${MISSING_PY_MODULES[*]}. Install them before proceeding: ${pkgs_to_install[*]}"
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
# Generates a comprehensive SBOM and provenance manifest (image_details.json)
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
# Helper: Convert VyOS Live/Installer ISO to Bootable QCOW2 Disk
# Performs automated unattended installation in headless QEMU
# ==============================================================================
convert_vyos_iso_to_qcow2() {
  local iso_path="$1"
  local output_qcow2="$2"
  local disk_size="${3:-10G}"
  local admin_password="${4:-vyos}"

  log "Creating blank ${disk_size} QCOW2 virtual disk at: ${output_qcow2}..."
  mkdir -p "$(dirname "$output_qcow2")"
  rm -f "$output_qcow2"
  qemu-img create -f qcow2 "$output_qcow2" "$disk_size" >/dev/null

  log "Launching automated headless QEMU installer from ${iso_path}..."
  log "Installing partitions, GRUB, and VyOS system (typically takes 60-90s)..."

  local accel="tcg"
  if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="kvm"
  fi

  python3 - "$iso_path" "$output_qcow2" "$accel" 3<<<"$admin_password" <<'EOF_INSTALL_PY'
import sys, os, time, re
try:
    import pexpect
except ImportError:
    print("[ERROR] python3-pexpect is required for automated VyOS ISO installation. Please install python3-pexpect.", file=sys.stderr)
    sys.exit(1)

iso_file = sys.argv[1]
disk_file = sys.argv[2]
accel = sys.argv[3]

# Read admin_password from private file descriptor 3 to prevent exposing secrets in /proc/<pid>/cmdline
admin_password = ""
if len(sys.argv) > 4:
    admin_password = sys.argv[4]
else:
    try:
        with os.fdopen(3, "r") as f:
            admin_password = f.read().rstrip("\r\n")
    except Exception:
        admin_password = "vyos"

qemu_cmd = [
    "qemu-system-x86_64",
    "-m", "2048",
    "-smp", "2",
    "-drive", f"file={disk_file},format=qcow2,if=virtio",
    "-cdrom", iso_file,
    "-boot", "d",
    "-display", "none",
    "-serial", "stdio",
    "-monitor", "none",
    "-net", "none",
]
if accel == "kvm":
    qemu_cmd.extend(["-accel", "kvm", "-accel", "tcg"])
else:
    qemu_cmd.extend(["-accel", "tcg"])

print(f"[OLG-BUILD] Spawning QEMU installer process (accel={accel})...", flush=True)
child = pexpect.spawn(qemu_cmd[0], qemu_cmd[1:], timeout=120, encoding="utf-8")

patterns = [
    r"vyos login:\s*",                                      # 0: Live login
    r"[Pp]assword:\s*",                                     # 1: Password prompt (live login or installer)
    r"vyos@vyos:.*[#$]\s*",                                 # 2: Shell prompt
    r"\[[yY]/?[nN]?\]\s*",                                  # 3: Any Yes/No confirmation prompt
    r"[Pp]lease.*password.*:\s*",                           # 4: Password setup or confirm
    r"\(Default:.*?\)\s*",                                  # 5: Any question with default option
    r"(The image installed successfully|Installation finished|Installed image:|[sS]uccessfully installed).*", # 6: Success notification
    r"[Pp]artition.*\(Auto/Parted/Skip\).*:\s*",            # 7: Legacy 1.4 partition prompt
    r"[Ee]nter.*password for user.*:\s*",                   # 8: Legacy 1.4 password
    r"[Rr]etype.*password for user.*:\s*",                  # 9: Legacy 1.4 confirm password
    r"GRUB _",                                              # 10: Legacy GRUB prompt
    r"\[vda\]:\s*",                                         # 11: Drive selection prompt
    pexpect.TIMEOUT,                                        # 12
    pexpect.EOF                                             # 13
]

install_started = False
install_success_seen = False
install_completed = False
start_time = time.time()

while True:
    if time.time() - start_time > 300:
        print("\n[ERROR] Automated VyOS installation timed out after 5 minutes.", file=sys.stderr)
        child.kill(9)
        sys.exit(1)

    try:
        idx = child.expect(patterns, timeout=60)
    except pexpect.TIMEOUT:
        child.send("\r")
        continue
    except pexpect.EOF:
        if install_completed and install_success_seen:
            break
        print("\n[ERROR] QEMU terminated prematurely before installation finished.", file=sys.stderr)
        sys.exit(1)

    if idx == 0:  # vyos login:
        print("[OLG-BUILD] Live ISO booted. Logging in as 'vyos'...", flush=True)
        child.send("vyos\r")
    elif idx == 1:  # Password prompt (stage-aware)
        if not install_started:
            print("[OLG-BUILD] Submitting Live ISO console password 'vyos'...", flush=True)
            child.send("vyos\r")
        else:
            print("[OLG-BUILD] Setting VyOS administrative user password from manifest...", flush=True)
            child.send(f"{admin_password}\r")
    elif idx == 2:  # vyos@vyos:~$
        if not install_started:
            print("[OLG-BUILD] Starting unattended 'install image' wizard...", flush=True)
            install_started = True
            child.send("install image\r")
        else:
            if not install_success_seen:
                print("\n[ERROR] Installer exited back to shell prematurely without a verified success signal!", file=sys.stderr)
                child.kill(9)
                sys.exit(1)
            print("[OLG-BUILD] Installation wizard finished successfully and returned to shell. Powering off installer VM...", flush=True)
            install_completed = True
            child.send("sudo poweroff\r")
            time.sleep(2)
            try:
                child.expect(pexpect.EOF, timeout=30)
            except Exception:
                child.kill(9)
            break
    elif idx == 3:  # Any [y/N] prompt
        print("[OLG-BUILD] Prompt: Answering Yes to confirmation prompt", flush=True)
        child.send("y\r")
    elif idx == 4 or idx == 8 or idx == 9:  # Enter or confirm password
        print("[OLG-BUILD] Setting VyOS administrative user password from manifest...", flush=True)
        child.send(f"{admin_password}\r")
    elif idx == 5 or idx == 11:  # Default option or drive prompt
        child.send("\r")
    elif idx == 6:  # Installation completed
        print("[OLG-BUILD] VyOS image installation reported SUCCESS signal.", flush=True)
        install_success_seen = True
    elif idx == 7:  # Legacy 1.4: Partition scheme -> Auto
        child.send("Auto\r")
    elif idx == 10:  # Legacy 1.4: GRUB
        child.send("\r")
    elif idx == 12:  # TIMEOUT
        child.send("\r")
    elif idx == 13:  # EOF
        if install_completed and install_success_seen:
            break
        print("\n[ERROR] QEMU terminated prematurely before installation finished.", file=sys.stderr)
        child.kill(9)
        sys.exit(1)

if not install_completed or not install_success_seen:
    print("\n[ERROR] VyOS automated installation assertion failed (incomplete or unverified).", file=sys.stderr)
    sys.exit(1)

print(f"[OLG-BUILD] Automated VyOS installation successfully generated {disk_file} in {int(time.time() - start_time)}s.")
EOF_INSTALL_PY

  if [ ! -f "$output_qcow2" ] || [ "$(stat -c%s "$output_qcow2" 2>/dev/null || echo 0)" -lt 1000000 ]; then
    err "Automated VyOS ISO conversion failed. Resulting QCOW2 disk is missing or invalid."
  fi

  log "Validating newly converted VyOS QCOW2 virtual disk with qemu-img check..."
  if ! qemu-img check -q "$output_qcow2" >/dev/null 2>&1; then
    rm -f "$output_qcow2"
    err "Automated VyOS ISO conversion produced an invalid or corrupted QCOW2 disk according to qemu-img check."
  fi

  log "Validating that newly converted disk boots standalone and authenticates with configured credentials..."
  python3 - "$output_qcow2" "$accel" 3<<<"$admin_password" <<'EOF_BOOT_CHECK_PY'
import sys, os, time, re
try:
    import pexpect
except ImportError:
    sys.exit(0)

disk_file = sys.argv[1]
accel = sys.argv[2]
admin_password = ""
if len(sys.argv) > 3:
    admin_password = sys.argv[3]
else:
    try:
        with os.fdopen(3, "r") as f:
            admin_password = f.read().rstrip("\r\n")
    except Exception:
        admin_password = "vyos"

qemu_cmd = [
    "qemu-system-x86_64",
    "-m", "2048",
    "-smp", "2",
    "-drive", f"file={disk_file},format=qcow2,if=virtio",
    "-boot", "c",
    "-display", "none",
    "-serial", "stdio",
    "-monitor", "none",
    "-net", "none",
]
if accel == "kvm":
    qemu_cmd.extend(["-accel", "kvm", "-accel", "tcg"])
else:
    qemu_cmd.extend(["-accel", "tcg"])

print(f"[OLG-BUILD] Testing standalone VM boot & console credentials from {disk_file} (no CD-ROM)...", flush=True)
child = pexpect.spawn(qemu_cmd[0], qemu_cmd[1:], timeout=90, encoding="utf-8")
boot_patterns = [
    r"(vyos login:|login:)\s*",           # 0
    r"[Pp]assword:\s*",                  # 1
    r"vyos@vyos:.*[#$]\s*",              # 2
    r"(Login incorrect|invalid login)",  # 3
    pexpect.TIMEOUT,                     # 4
    pexpect.EOF,                         # 5
]

default_rejected = False
auth_success = False

try:
    while True:
        idx = child.expect(boot_patterns, timeout=90)
        if idx == 0:  # login prompt
            child.send("vyos\r")
        elif idx == 1:  # password prompt
            if admin_password != "vyos" and not default_rejected:
                # In production mode: First attempt default password 'vyos' to assert it is rejected
                child.send("vyos\r")
            else:
                # Submit configured admin_password
                child.send(f"{admin_password}\r")
        elif idx == 2:  # shell prompt
            if admin_password != "vyos" and not default_rejected:
                print("\n[ERROR] Security Assertion Failed: Default credentials 'vyos' were accepted!", file=sys.stderr)
                child.kill(9)
                sys.exit(1)
            auth_success = True
            print("[OLG-BUILD] Standalone VyOS disk boot test PASSED: Authenticated with configured admin_password.", flush=True)
            child.send("sudo poweroff\r")
            time.sleep(1)
            child.kill(9)
            sys.exit(0)
        elif idx == 3:  # Login incorrect
            default_rejected = True
            print("[OLG-BUILD] Confirmed rejection of default credentials ('vyos').", flush=True)
        elif idx == 4:  # TIMEOUT
            print("\n[ERROR] Standalone VyOS disk boot test FAILED: Timed out waiting for login/shell prompt.", file=sys.stderr)
            child.kill(9)
            sys.exit(1)
        elif idx == 5:  # EOF
            if auth_success:
                sys.exit(0)
            print("\n[ERROR] Standalone VyOS disk boot test FAILED: QEMU terminated prematurely without authenticating.", file=sys.stderr)
            child.kill(9)
            sys.exit(1)
except Exception as e:
    print(f"\n[ERROR] Standalone VyOS disk boot test exception: {e}", file=sys.stderr)
    child.kill(9)
    sys.exit(1)
EOF_BOOT_CHECK_PY

  if [ $? -ne 0 ]; then
    rm -f "$output_qcow2"
    err "Newly converted VyOS disk failed standalone boot verification."
  fi
  log "VyOS base QCOW2 disk generated, boot-tested, and validated successfully at: ${output_qcow2}"
}

# ==============================================================================
# Helper: Parse config.boot and update only 'system login user vyos' encrypted-password
# Accurately scopes updates to user 'vyos', preserves other accounts, and asserts
# exactly one modification occurred.
# ==============================================================================
update_vyos_config_boot_password() {
  local cfg_file="$1"
  local new_hash="$2"

  local SUDO_PREFIX=""
  if [ "$(id -u)" -ne 0 ] && [ ! -w "$cfg_file" ]; then
    SUDO_PREFIX="sudo"
  fi

  $SUDO_PREFIX python3 - "$cfg_file" "$new_hash" <<'EOF_UPDATE_CFG_BOOT'
import sys, re

cfg_file = sys.argv[1]
new_hash = sys.argv[2]

with open(cfg_file, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

out = []
stack = []
modified_count = 0

for line in lines:
    stripped = line.strip()

    is_vyos_auth = False
    if len(stack) >= 4:
        s0 = stack[0].lower()
        s1 = stack[1].lower()
        s2 = stack[2].lower()
        s3 = stack[3].lower()
        if s0 == 'system' and s1 == 'login' and bool(re.match(r'^user\s+[\'\"]?vyos[\'\"]?', s2)) and s3 == 'authentication':
            is_vyos_auth = True

    if is_vyos_auth and stripped.startswith('encrypted-password'):
        indent = line[:line.find('encrypted-password')]
        out.append(f"{indent}encrypted-password '{new_hash}'\n")
        modified_count += 1
        continue

    out.append(line)

    in_quote = False
    quote_char = ''
    last_start = 0
    for i, ch in enumerate(stripped):
        if ch in ('"', "'"):
            if not in_quote:
                in_quote = True
                quote_char = ch
            elif ch == quote_char:
                in_quote = False
        elif not in_quote:
            if ch == '{':
                header = stripped[last_start:i].strip()
                stack.append(header)
                last_start = i + 1
            elif ch == '}':
                if stack:
                    stack.pop()
                last_start = i + 1

if modified_count != 1:
    sys.stderr.write(f"ERROR: Expected exactly 1 'system login user vyos' encrypted-password in {cfg_file}, but found and modified {modified_count}.\n")
    sys.exit(1)

with open(cfg_file, 'w', encoding='utf-8') as f:
    f.writelines(out)
EOF_UPDATE_CFG_BOOT
}

# ==============================================================================
# Helper: Parse config.boot and extract only 'system login user vyos' encrypted-password
# ==============================================================================
extract_vyos_config_boot_password() {
  local cfg_file="$1"

  local SUDO_PREFIX=""
  if [ "$(id -u)" -ne 0 ] && [ ! -r "$cfg_file" ]; then
    SUDO_PREFIX="sudo"
  fi

  $SUDO_PREFIX python3 - "$cfg_file" <<'EOF_EXTRACT_CFG_BOOT'
import sys, re

cfg_file = sys.argv[1]
with open(cfg_file, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

stack = []
found_hashes = []

for line in lines:
    stripped = line.strip()

    is_vyos_auth = False
    if len(stack) >= 4:
        s0 = stack[0].lower()
        s1 = stack[1].lower()
        s2 = stack[2].lower()
        s3 = stack[3].lower()
        if s0 == 'system' and s1 == 'login' and bool(re.match(r'^user\s+[\'\"]?vyos[\'\"]?', s2)) and s3 == 'authentication':
            is_vyos_auth = True

    if is_vyos_auth and stripped.startswith('encrypted-password'):
        m = re.search(r'encrypted-password\s+[\'\"]?([^\'\"\s]+)[\'\"]?', stripped)
        if m:
            found_hashes.append(m.group(1))

    in_quote = False
    quote_char = ''
    last_start = 0
    for i, ch in enumerate(stripped):
        if ch in ('"', "'"):
            if not in_quote:
                in_quote = True
                quote_char = ch
            elif ch == quote_char:
                in_quote = False
        elif not in_quote:
            if ch == '{':
                header = stripped[last_start:i].strip()
                stack.append(header)
                last_start = i + 1
            elif ch == '}':
                if stack:
                    stack.pop()
                last_start = i + 1

if len(found_hashes) != 1:
    sys.stderr.write(f"ERROR: Expected exactly 1 encrypted-password for 'system login user vyos' in {cfg_file}, found {len(found_hashes)}.\n")
    sys.exit(1)

print(found_hashes[0])
EOF_EXTRACT_CFG_BOOT
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
  local disk_size
  disk_size=$(jq -r '.base_image.disk_size // .disk_size // "10G"' <<< "$vyos_json")
  local admin_password
  admin_password=$(jq -r '.base_image.admin_password // .admin_password // empty' <<< "$vyos_json")

  if [ "$BUILD_MODE" = "production" ]; then
    # In production mode: Reusable default credentials ('vyos') are strictly prohibited
    if [ -z "$admin_password" ] || [ "$admin_password" = "vyos" ]; then
      err "Production build security policy violation: Reusable default credentials ('vyos') or empty passwords are prohibited. Please specify a secure custom admin_password in build.yaml (or build with --dev for local testing)."
    fi
  else
    # In dev mode: Allow default development credentials for local testing
    [ -z "$admin_password" ] && admin_password="vyos"
  fi
  local install_password="$admin_password"
  local golden_disk="${OUTPUT_DIR}/vyos-golden.qcow2"

  local is_iso=false
  if [[ "$base_name" == *.iso ]] || [[ "$base_url" == *.iso* ]]; then
    is_iso=true
  fi

  local cached_base=""
  local cached_iso=""
  local act_iso_sha=""
  if [ "$is_iso" = "true" ]; then
    local iso_cache_name="${base_name}"
    [[ "$iso_cache_name" != *.iso ]] && iso_cache_name="vyos-installer.iso"
    cached_iso="${CACHE_DIR}/${iso_cache_name}"

    # 1. Download ISO if missing
    if [ ! -f "$cached_iso" ]; then
      if [ -n "$base_url" ]; then
        log "Downloading VyOS installer ISO from $base_url..."
        curl --fail -L -C - -o "$cached_iso" "$base_url"
      else
        err "VyOS installer ISO not found in cache ($cached_iso) and no base_image.url configured in manifest."
      fi
    fi

    # 2. Compute ISO checksum and validate against manifest if declared
    log "Computing SHA-256 checksum for source VyOS installer ISO: ${cached_iso}..."
    local act_iso_sha
    act_iso_sha=$(sha256sum "$cached_iso" | awk '{print $1}')
    if [ -n "$base_sha256" ]; then
      if [ "$act_iso_sha" != "$base_sha256" ]; then
        err "VyOS installer ISO SHA-256 checksum mismatch! Expected: ${base_sha256}, Got: ${act_iso_sha}"
      fi
      log "VyOS installer ISO checksum verified [OK]."
    fi

    # 3. Derive unique converted QCOW2 cache key tied to the source ISO SHA-256, installer settings, and build mode
    local install_settings_hash
    install_settings_hash=$(printf "%s:%s:%s:%s" "$act_iso_sha" "$disk_size" "$install_password" "$BUILD_MODE" | sha256sum | awk '{print $1}')
    local cache_hash_prefix="${install_settings_hash:0:16}"
    cached_base="${CACHE_DIR}/vyos-base-${BUILD_MODE}-${cache_hash_prefix}.qcow2"
    local cached_base_sig="${CACHE_DIR}/.vyos-base-${BUILD_MODE}-${cache_hash_prefix}.sig"
    local pass_hash_prefix
    pass_hash_prefix=$(printf "%s" "$install_password" | sha256sum | awk '{print $1}')
    local expected_sig="${act_iso_sha} size=${disk_size} mode=${BUILD_MODE} pass_sha=${pass_hash_prefix:0:16}"

    # 4. Check if converted QCOW2 already exists, has valid checksum, and is healthy
    local need_conversion=true
    if [ -f "$cached_base" ] && [ -f "$cached_base_sig" ] && [ -f "${cached_base}.sha256" ]; then
      local recorded_sig
      recorded_sig=$(cat "$cached_base_sig" 2>/dev/null || true)
      local recorded_sha
      recorded_sha=$(cat "${cached_base}.sha256" 2>/dev/null | awk '{print $1}' || true)
      local expected_sig_prefix="${expected_sig} qcow2_sha=${recorded_sha}"

      if [ "$recorded_sig" = "$expected_sig_prefix" ] && [ -n "$recorded_sha" ]; then
        log "Verifying cryptographic SHA-256 artifact checksum for cached VyOS base disk (${cached_base})..."
        local actual_cached_sha
        actual_cached_sha=$(sha256sum "$cached_base" | awk '{print $1}')
        if [ "$actual_cached_sha" = "$recorded_sha" ]; then
          log "Verifying structural integrity of cached converted VyOS base disk with qemu-img check..."
          if qemu-img check -q "$cached_base" >/dev/null 2>&1; then
            log "Found verified, cryptographically sealed VyOS base disk matching source ISO and installer settings: ${cached_base} (skipping ISO conversion)."
            need_conversion=false
          else
            log "Cached converted disk failed qemu-img check. Invalidating cache and re-converting from ISO..."
            rm -f "$cached_base" "$cached_base_sig" "${cached_base}.sha256"
          fi
        else
          log "Cached converted disk SHA-256 artifact checksum mismatch (expected: ${recorded_sha:0:16}..., actual: ${actual_cached_sha:0:16}...). File was modified or corrupted. Invalidating cache and re-converting from ISO..."
          rm -f "$cached_base" "$cached_base_sig" "${cached_base}.sha256"
        fi
      else
        log "Cached converted disk installer settings or signature mismatch (ISO, disk_size, or credentials changed). Invalidating cache and re-converting from ISO..."
        rm -f "$cached_base" "$cached_base_sig" "${cached_base}.sha256"
      fi
    else
      # Clean up incomplete or partial cache metadata
      rm -f "$cached_base_sig" "${cached_base}.sha256"
    fi

    if [ "$need_conversion" = "true" ]; then
      log "Converting VyOS installer ISO (${cached_iso}) to bootable virtual disk (${cached_base}, size=${disk_size})..."
      convert_vyos_iso_to_qcow2 "$cached_iso" "$cached_base" "$disk_size" "$install_password"

      # Compute and seal SHA-256 artifact checksum after verified standalone boot
      log "Computing cryptographic SHA-256 checksum for newly converted VyOS base disk..."
      local act_base_qcow2_sha
      act_base_qcow2_sha=$(sha256sum "$cached_base" | awk '{print $1}')
      echo "$act_base_qcow2_sha" > "${cached_base}.sha256"
      echo "${expected_sig} qcow2_sha=${act_base_qcow2_sha}" > "$cached_base_sig"
      log "VyOS base QCOW2 disk generated, boot-tested, and cryptographically sealed at: ${cached_base} (SHA-256: ${act_base_qcow2_sha:0:16}...)"
    fi
  else
    cached_base="${CACHE_DIR}/${base_name}"
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

    log "Validating VyOS base disk integrity with qemu-img check..."
    if ! qemu-img check -q "$cached_base" >/dev/null 2>&1; then
      err "VyOS base disk failed qemu-img check: ${cached_base}."
    fi
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

  # Ensure all conf_mode and op_mode Python scripts have valid python3 shebangs and execute permissions
  log "Ensuring valid python3 shebangs on all VyOS conf_mode and op_mode scripts..."
  local squashfs_file
  squashfs_file=$(ls "$mnt"/boot/*/*.squashfs 2>/dev/null | head -n 1 || true)
  if [ -n "$squashfs_file" ] && [ -f "$squashfs_file" ]; then
    local squash_tmp="${WORK_DIR}/squash_scripts_tmp"
    sudo rm -rf "$squash_tmp"
    mkdir -p "$squash_tmp"
    unsquashfs -d "$squash_tmp" "$squashfs_file" usr/libexec/vyos/conf_mode usr/libexec/vyos/op_mode 2>/dev/null || true

    for subdir in conf_mode op_mode; do
      if [ -d "$squash_tmp/usr/libexec/vyos/$subdir" ]; then
        sudo mkdir -p "$root_target/usr/libexec/vyos/$subdir"
        for py_file in "$squash_tmp/usr/libexec/vyos/$subdir"/*.py; do
          [ -f "$py_file" ] || continue
          local bname
          bname=$(basename "$py_file")
          local target_file="$root_target/usr/libexec/vyos/$subdir/$bname"
          local first_line
          first_line=$(head -n 1 "$py_file" 2>/dev/null || echo "")
          if [[ "$first_line" != "#!"* ]]; then
            { echo "#!/usr/bin/env python3"; cat "$py_file"; } | sudo tee "$target_file" >/dev/null
            sudo chmod 0755 "$target_file"
          elif [ ! -f "$target_file" ]; then
            sudo cp -p "$py_file" "$target_file"
            sudo chmod 0755 "$target_file"
          fi
        done
      fi
    done
    sudo rm -rf "$squash_tmp"
  fi

  # Also scan any scripts already present in root_target to ensure they have shebangs and execute permissions
  for py_file in "$root_target"/usr/libexec/vyos/conf_mode/*.py "$root_target"/usr/libexec/vyos/op_mode/*.py; do
    [ -f "$py_file" ] || continue
    local first_line
    first_line=$(head -n 1 "$py_file" 2>/dev/null || echo "")
    if [[ "$first_line" != "#!"* ]]; then
      local tmp_file
      tmp_file=$(mktemp)
      echo "#!/usr/bin/env python3" > "$tmp_file"
      cat "$py_file" >> "$tmp_file"
      sudo cp -f "$tmp_file" "$py_file"
      sudo chmod 0755 "$py_file"
      rm -f "$tmp_file"
    else
      sudo chmod 0755 "$py_file"
    fi
  done

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

  # Enable serial console on ttyS0 for 'virsh console' with unblocked agetty
  sudo mkdir -p "$root_target/etc/systemd/system/serial-getty@ttyS0.service.d"
  cat <<'EOF_GETTY' | sudo tee "$root_target/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" >/dev/null
[Unit]
Description=Serial Getty on %I (VyOS / OLG Console)
After=
Before=
Wants=

[Service]
ExecStartPre=
ExecStart=
ExecStart=-/sbin/agetty --noclear --keep-baud 115200,38400,9600 %I $TERM
Restart=always
RestartSec=1s
EOF_GETTY
  sudo chmod 0644 "$root_target/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf"

  sudo mkdir -p "$root_target/etc/systemd/system/getty.target.wants" "$root_target/etc/systemd/system/multi-user.target.wants"
  sudo ln -sf /lib/systemd/system/serial-getty@.service "$root_target/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true
  sudo ln -sf /lib/systemd/system/serial-getty@.service "$root_target/etc/systemd/system/multi-user.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true

  # Configure VyOS postconfig bootup hook to signal boot completion and ensure core runtime services
  local seen_scripts=()
  for POSTCONFIG_DIR in "$root_target/opt/vyatta/etc/config/scripts" "$root_target/config/scripts"; do
    [ -d "$POSTCONFIG_DIR" ] || sudo mkdir -p "$POSTCONFIG_DIR"
    local real_dir
    real_dir=$(readlink -f "$POSTCONFIG_DIR" 2>/dev/null || echo "$POSTCONFIG_DIR")
    if [[ " ${seen_scripts[*]} " =~ " ${real_dir} " ]]; then
      continue
    fi
    seen_scripts+=("$real_dir")

    POSTCONFIG_SCRIPT="$POSTCONFIG_DIR/vyos-postconfig-bootup.script"
    local olg_block
    olg_block=$(cat <<'EOF_POSTCONFIG'
### BEGIN OLG MANAGED BLOCK ###
# OLG: Ensure kernel modules are loaded
modprobe virtiofs 2>/dev/null || true
modprobe virtio_pci 2>/dev/null || true
modprobe binfmt_misc 2>/dev/null || true
systemctl restart systemd-binfmt 2>/dev/null || true

# OLG: Ensure runtime directories exist
mkdir -p /run/vyatta/config /run/vyos /etc/olg/secrets /etc/olg/device-certs /opt/olg/state 2>/dev/null || true

# OLG: Ensure management interface mgmt0 is configured and up
ip addr add 192.168.254.1/24 dev mgmt0 2>/dev/null || true
ip link set mgmt0 up 2>/dev/null || true

# OLG: Ensure serial-getty is active on ttyS0 for virsh console
systemctl restart serial-getty@ttyS0.service 2>/dev/null || true

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

# OLG: Ensure Kea DHCP daemon rebinds raw sockets to active bridge interfaces
systemctl is-active isc-kea-dhcp4-server >/dev/null 2>&1 && systemctl restart isc-kea-dhcp4-server 2>/dev/null || true

# OLG: Signal that VyOS postconfig and initial boot commits are 100% complete
touch /run/vyos/boot_ready
### END OLG MANAGED BLOCK ###
EOF_POSTCONFIG
)

    if [ -f "$POSTCONFIG_SCRIPT" ] && [ -s "$POSTCONFIG_SCRIPT" ]; then
      # Strip previous OLG managed block if present to ensure idempotency while preserving user scripts
      sudo sed -i '/### BEGIN OLG MANAGED BLOCK ###/,/### END OLG MANAGED BLOCK ###/d' "$POSTCONFIG_SCRIPT" 2>/dev/null || true
      if [ -n "$(sudo tail -c 1 "$POSTCONFIG_SCRIPT" 2>/dev/null || true)" ]; then
        echo "" | sudo tee -a "$POSTCONFIG_SCRIPT" >/dev/null
      fi
      echo "$olg_block" | sudo tee -a "$POSTCONFIG_SCRIPT" >/dev/null
    else
      {
        echo "#!/bin/sh"
        echo "set -e"
        echo ""
        echo "$olg_block"
      } | sudo tee "$POSTCONFIG_SCRIPT" >/dev/null
    fi
    sudo chmod 0755 "$POSTCONFIG_SCRIPT"

    # Install commit post-hook to rebind Kea DHCP raw sockets after configuration commits
    local commit_post_dir="$POSTCONFIG_DIR/commit/post-hooks.d"
    sudo mkdir -p "$commit_post_dir"
    cat <<'EOF_KEA_HOOK' | sudo tee "$commit_post_dir/10-restart-kea" >/dev/null
#!/bin/sh
# OLG: Rebind Kea DHCP raw sockets after configuration commits
systemctl is-active isc-kea-dhcp4-server >/dev/null 2>&1 && systemctl restart isc-kea-dhcp4-server 2>/dev/null || true
EOF_KEA_HOOK
    sudo chmod 0755 "$commit_post_dir/10-restart-kea"
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

  if [ "${#cfg_boot_files[@]}" -eq 0 ]; then
    err "Required VyOS configuration file 'config.boot' not found in $mnt!"
  fi

  for CFG_BOOT in "${cfg_boot_files[@]}"; do
    [ -f "$CFG_BOOT" ] || continue
    log "Sanitizing and prepping VyOS config: $CFG_BOOT..."
    # Update VyOS administrative user credentials in config.boot (strictly scoped to user vyos)
    if [ -n "$admin_password" ]; then
      local pass_hash
      pass_hash=$(openssl passwd -6 "$admin_password")
      if ! update_vyos_config_boot_password "$CFG_BOOT" "$pass_hash"; then
        err "Failed to update encrypted-password for user 'vyos' in $CFG_BOOT"
      fi
    fi
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

  # Configure /etc/shadow user credentials
  local shadow_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && shadow_files+=("$f")
  done < <(sudo find "$mnt" -type f -name "shadow" 2>/dev/null || true)

  if [ "${#shadow_files[@]}" -eq 0 ]; then
    err "Required user credentials database '/etc/shadow' not found in $mnt!"
  fi

  if [ -n "$admin_password" ]; then
    local shadow_hash
    shadow_hash=$(openssl passwd -6 "$admin_password")
    for shf in "${shadow_files[@]}"; do
      if ! sudo grep -q "^vyos:" "$shf" 2>/dev/null; then
        err "Required administrative user 'vyos' missing from shadow file: $shf"
      fi
      sudo sed -i -E "s|^vyos:[^:]+:|vyos:${shadow_hash}:|" "$shf"
      if ! sudo grep -q "^vyos:${shadow_hash}:" "$shf" 2>/dev/null; then
        err "Failed to write password hash for user 'vyos' in $shf"
      fi
    done
  fi

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

  # In production mode: Verify configured credentials match admin_password and no default credentials remain
  if [ "$BUILD_MODE" = "production" ]; then
    log "Running production security verification: Asserting configured admin_password matches stored hashes and default credentials are absent..."
    for shf in "${shadow_files[@]}"; do
      local vyos_entry
      vyos_entry=$(sudo grep "^vyos:" "$shf" 2>/dev/null || true)
      if [ -z "$vyos_entry" ]; then
        err "Security Validation FAILED: Administrative user 'vyos' missing from $shf!"
      fi
      local vyos_hash
      vyos_hash=$(echo "$vyos_entry" | cut -d: -f2)
      if [ "$vyos_hash" = "!" ] || [ "$vyos_hash" = "*" ] || [ -z "$vyos_hash" ]; then
        err "Security Validation FAILED: Production image vyos user is locked ($vyos_hash) and will block console/RTTY access!"
      fi

      local salt
      salt=$(echo "$vyos_hash" | cut -d'$' -f3)
      if [ -z "$salt" ]; then
        err "Security Validation FAILED: Unable to extract SHA-512 salt from $shf hash!"
      fi

      local expected_hash
      expected_hash=$(openssl passwd -6 -salt "$salt" "$admin_password" 2>/dev/null || true)
      if [ "$vyos_hash" != "$expected_hash" ]; then
        err "Security Validation FAILED: Stored shadow hash in $shf does not match configured admin_password!"
      fi

      local test_default_hash
      test_default_hash=$(openssl passwd -6 -salt "$salt" "vyos" 2>/dev/null || true)
      if [ "$vyos_hash" = "$test_default_hash" ]; then
        err "Security Validation FAILED: Production image contains default password 'vyos' in $shf!"
      fi
    done

    for CFG_BOOT in "${cfg_boot_files[@]}"; do
      local boot_hash
      if ! boot_hash=$(extract_vyos_config_boot_password "$CFG_BOOT"); then
        err "Security Validation FAILED: Unable to extract encrypted-password for user 'vyos' from $CFG_BOOT!"
      fi
      local bsalt
      bsalt=$(echo "$boot_hash" | cut -d'$' -f3)
      if [ -z "$bsalt" ]; then
        err "Security Validation FAILED: Unable to extract SHA-512 salt from $CFG_BOOT user 'vyos' hash!"
      fi

      local expected_boot_hash
      expected_boot_hash=$(openssl passwd -6 -salt "$bsalt" "$admin_password" 2>/dev/null || true)
      if [ "$boot_hash" != "$expected_boot_hash" ]; then
        err "Security Validation FAILED: Stored config.boot hash for user 'vyos' in $CFG_BOOT does not match configured admin_password!"
      fi

      local test_boot_default
      test_boot_default=$(openssl passwd -6 -salt "$bsalt" "vyos" 2>/dev/null || true)
      if [ "$boot_hash" = "$test_boot_default" ]; then
        err "Security Validation FAILED: Production image config.boot user 'vyos' contains default password hash for 'vyos'!"
      fi
    done
    log "Production security verification PASSED: Verified admin_password matches stored hashes and default credentials are absent."
  fi

  # Verify Kea DHCP postconfig and post-hook presence
  local found_kea_postconfig=false
  local found_kea_hook=false
  for POSTCONFIG_DIR in "$root_target/opt/vyatta/etc/config/scripts" "$root_target/config/scripts"; do
    if [ -f "$POSTCONFIG_DIR/vyos-postconfig-bootup.script" ] && grep -q "isc-kea-dhcp4-server" "$POSTCONFIG_DIR/vyos-postconfig-bootup.script" 2>/dev/null; then
      found_kea_postconfig=true
    fi
    if [ -x "$POSTCONFIG_DIR/commit/post-hooks.d/10-restart-kea" ]; then
      found_kea_hook=true
    fi
  done
  if [ "$found_kea_postconfig" = false ] || [ "$found_kea_hook" = false ]; then
    err "Validation FAILED: Kea DHCP raw socket rebind hooks missing from customized VyOS filesystem."
  fi
  log "Kea DHCP raw socket rebind hooks validated successfully."

  # Unmount NBD and cleanly disconnect
  sudo umount "$mnt"
  VYOS_MNT_DIR=""
  sudo qemu-nbd --disconnect "$CURRENT_NBD_DEV" 2>/dev/null || true
  CURRENT_NBD_DEV=""

  # Generate Checksum and Attestation Manifest
  local act_golden_sha
  act_golden_sha=$(sha256sum "$golden_disk" | awk '{print $1}')
  echo "$act_golden_sha  $(basename "$golden_disk")" > "${golden_disk}.sha256"

  local pass_sha=""
  [ -n "$admin_password" ] && pass_sha=$(printf "%s" "$admin_password" | sha256sum | awk '{print $1}')
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local attestation_file="${golden_disk}.attestation.json"
  jq -n \
    --arg artifact "$(basename "$golden_disk")" \
    --arg build_mode "$BUILD_MODE" \
    --arg qcow2_sha256 "$act_golden_sha" \
    --arg pass_sha256 "$pass_sha" \
    --arg built_at "$timestamp" \
    --arg source_iso "$(basename "${cached_iso:-unknown.iso}")" \
    --arg source_iso_sha256 "${act_iso_sha:-unknown}" \
    --argjson credentials_verified true \
    '{
      artifact: $artifact,
      build_mode: $build_mode,
      qcow2_sha256: $qcow2_sha256,
      admin_password_hash_sha256: $pass_sha256,
      built_at: $built_at,
      source_iso: $source_iso,
      source_iso_sha256: $source_iso_sha256,
      credentials_verified: $credentials_verified
    }' > "$attestation_file"
  log "Generated cryptographic image attestation at: ${attestation_file}"
  log "VyOS Golden Master Disk built successfully at: ${golden_disk}"
  generate_provenance_manifest "${OUTPUT_DIR}/image_details.json"
}

# ==============================================================================
# Helper: Verify VyOS Golden Master Attestation & In-Guest Credentials Gate
# Guarantees that images packaged into ISOs (including --iso-only) are attested,
# match the target build mode, and have zero default credentials.
# ==============================================================================
verify_golden_image_attestation_and_credentials() {
  local disk="$1"
  local expected_mode="$2"
  local expected_pass="$3"
  local attestation_file="${disk}.attestation.json"
  local sha_file="${disk}.sha256"

  log "Verifying golden master image attestation and credentials for mode '${expected_mode}'..."

  # 1. Existence checks
  if [ ! -f "$disk" ]; then
    err "Cannot build ISO: Golden master image missing at ${disk}. Run without --iso-only first."
  fi
  if [ ! -f "$sha_file" ]; then
    err "Production security violation: Golden master checksum manifest missing at ${sha_file}."
  fi
  if [ ! -f "$attestation_file" ]; then
    err "Production security violation: Golden master image attestation missing at ${attestation_file}. Image was not verified by build_vyos. Rebuild with full pipeline."
  fi

  # 2. Disk SHA-256 integrity check against .sha256 manifest
  local actual_sha
  actual_sha=$(sha256sum "$disk" | awk '{print $1}')
  local recorded_sha
  recorded_sha=$(cat "$sha_file" 2>/dev/null | awk '{print $1}' || true)
  if [ -z "$recorded_sha" ] || [ "$actual_sha" != "$recorded_sha" ]; then
    err "Production security violation: Golden master disk checksum mismatch against ${sha_file}! (expected: ${recorded_sha}, actual: ${actual_sha})"
  fi

  # 3. Attestation content and integrity validation
  local att_artifact att_mode att_sha att_pass_sha att_verified
  att_artifact=$(jq -r '.artifact // empty' "$attestation_file" 2>/dev/null || true)
  att_mode=$(jq -r '.build_mode // empty' "$attestation_file" 2>/dev/null || true)
  att_sha=$(jq -r '.qcow2_sha256 // empty' "$attestation_file" 2>/dev/null || true)
  att_pass_sha=$(jq -r '.admin_password_hash_sha256 // empty' "$attestation_file" 2>/dev/null || true)
  att_verified=$(jq -r '.credentials_verified // false' "$attestation_file" 2>/dev/null || true)

  if [ -z "$att_mode" ] || [ -z "$att_sha" ]; then
    err "Production security violation: Corrupted or unreadable image attestation in ${attestation_file}."
  fi

  if [ "$actual_sha" != "$att_sha" ]; then
    err "Production security violation: Image attestation SHA-256 mismatch! Attestation records ${att_sha}, but disk is ${actual_sha}."
  fi

  if [ "$att_verified" != "true" ]; then
    err "Production security violation: Image attestation indicates credentials were NOT verified at build time."
  fi

  # 4. Mode gate: Reject development image when building in production mode
  if [ "$expected_mode" = "production" ]; then
    if [ "$att_mode" != "production" ]; then
      err "Production security violation: Golden master image was built in '${att_mode}' mode (contains default 'vyos' development credentials). Cannot package a development image into a production ISO! Rebuild VyOS disk with --production."
    fi

    # Stale credential check against current manifest
    if [ -n "$expected_pass" ]; then
      local exp_pass_sha
      exp_pass_sha=$(printf "%s" "$expected_pass" | sha256sum | awk '{print $1}')
      if [ -n "$att_pass_sha" ] && [ "$att_pass_sha" != "$exp_pass_sha" ]; then
        err "Production security violation: Golden master image was built with a different admin_password than currently configured in build.yaml. Rebuild VyOS disk with --production."
      fi
    fi

    # 5. Direct In-Guest Credential Gate: Inspect disk via read-only NBD to verify zero default credentials
    log "Performing direct in-guest credential audit on ${disk} before ISO packaging..."
    local check_mnt="${WORK_DIR}/attest_mnt"
    mkdir -p "$check_mnt"

    local nbd_dev
    nbd_dev=$(find_free_nbd 2>/dev/null || true)
    if [ -z "$nbd_dev" ]; then
      err "No free NBD block device available for credential audit."
    fi

    CURRENT_NBD_DEV="$nbd_dev"
    sudo qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
    sudo qemu-nbd --read-only --connect="$nbd_dev" "$disk"
    sleep 1

    local part_dev="${nbd_dev}p3"
    if [ ! -b "$part_dev" ]; then
      sudo partx -u "$nbd_dev" 2>/dev/null || sudo partprobe "$nbd_dev" 2>/dev/null || true
      sleep 1
    fi
    if [ ! -b "$part_dev" ]; then
      sudo qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
      CURRENT_NBD_DEV=""
      err "Failed to access root partition ${part_dev} on ${disk} for credential audit."
    fi

    VYOS_MNT_DIR="$check_mnt"
    sudo mount -o ro "$part_dev" "$check_mnt"

    local audit_failed=false
    local audit_reason=""

    # Audit shadow files
    local shadow_files=()
    while IFS= read -r f; do
      [ -n "$f" ] && shadow_files+=("$f")
    done < <(sudo find "$check_mnt" -type f -name "shadow" 2>/dev/null || true)

    if [ "${#shadow_files[@]}" -eq 0 ]; then
      audit_failed=true; audit_reason="Required /etc/shadow not found on root partition"
    fi

    for shf in "${shadow_files[@]}"; do
      local vyos_entry
      vyos_entry=$(sudo grep "^vyos:" "$shf" 2>/dev/null || true)
      if [ -z "$vyos_entry" ]; then
        audit_failed=true; audit_reason="vyos user missing in $shf"; break
      fi
      local vhash
      vhash=$(echo "$vyos_entry" | cut -d: -f2)
      if [ "$vhash" = "!" ] || [ "$vhash" = "*" ] || [ -z "$vhash" ]; then
        audit_failed=true; audit_reason="vyos user is locked ($vhash) in $shf"; break
      fi
      local vsalt
      vsalt=$(echo "$vhash" | cut -d'$' -f3)
      if [ -z "$vsalt" ]; then
        audit_failed=true; audit_reason="Unable to extract salt from $shf"; break
      fi
      local def_h
      def_h=$(openssl passwd -6 -salt "$vsalt" "vyos" 2>/dev/null || true)
      if [ "$vhash" = "$def_h" ]; then
        audit_failed=true; audit_reason="Default password 'vyos' found in $shf"; break
      fi
      if [ -n "$expected_pass" ]; then
        local exp_h
        exp_h=$(openssl passwd -6 -salt "$vsalt" "$expected_pass" 2>/dev/null || true)
        if [ "$vhash" != "$exp_h" ]; then
          audit_failed=true; audit_reason="Stored hash in $shf does not match expected admin_password"; break
        fi
      fi
    done

    # Audit config.boot files
    if [ "$audit_failed" = false ]; then
      local boot_files=()
      while IFS= read -r f; do
        [ -n "$f" ] && boot_files+=("$f")
      done < <(sudo find "$check_mnt" -type f -name "config.boot" 2>/dev/null || true)

      if [ "${#boot_files[@]}" -eq 0 ]; then
        audit_failed=true; audit_reason="Required config.boot not found on root partition"
      fi

      for cboot in "${boot_files[@]}"; do
        local b_hash
        if ! b_hash=$(extract_vyos_config_boot_password "$cboot" 2>/dev/null); then
          audit_failed=true; audit_reason="Failed to extract 'system login user vyos' encrypted-password from $cboot"; break
        fi
        local b_salt
        b_salt=$(echo "$b_hash" | cut -d'$' -f3)
        if [ -z "$b_salt" ]; then
          audit_failed=true; audit_reason="Unable to extract salt from $cboot user 'vyos' hash"; break
        fi
        local b_def_h
        b_def_h=$(openssl passwd -6 -salt "$b_salt" "vyos" 2>/dev/null || true)
        if [ "$b_hash" = "$b_def_h" ]; then
          audit_failed=true; audit_reason="Default password hash for 'vyos' found in $cboot user 'vyos'"; break
        fi
        if [ -n "$expected_pass" ]; then
          local b_exp_h
          b_exp_h=$(openssl passwd -6 -salt "$b_salt" "$expected_pass" 2>/dev/null || true)
          if [ "$b_hash" != "$b_exp_h" ]; then
            audit_failed=true; audit_reason="Stored hash for user 'vyos' in $cboot does not match expected admin_password"; break
          fi
        fi
      done
    fi

    # Unmount and disconnect NBD
    sudo umount "$check_mnt" 2>/dev/null || true
    VYOS_MNT_DIR=""
    sudo qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
    CURRENT_NBD_DEV=""
    rmdir "$check_mnt" 2>/dev/null || true

    if [ "$audit_failed" = true ]; then
      err "Production security violation: Direct in-guest credential audit FAILED: ${audit_reason}! Cannot package unverified image into production ISO."
    fi

    log "Direct in-guest credential audit PASSED: Verified zero default credentials and authentic production hashes [OK]."
  fi

  log "Golden master image attestation verified successfully: Artifact is authentic, matches build mode '${expected_mode}', and is sealed [OK]."
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

  local vyos_json
  vyos_json=$(jq -c '.vyos' <<< "$MANIFEST_JSON")
  local admin_password
  admin_password=$(jq -r '.base_image.admin_password // .admin_password // empty' <<< "$vyos_json")

  if [ "$BUILD_MODE" = "production" ]; then
    if [ -z "$admin_password" ] || [ "$admin_password" = "vyos" ]; then
      err "Production build security policy violation: Reusable default credentials ('vyos') or empty passwords are prohibited. Please specify a secure custom admin_password in build.yaml (or build with --dev for local testing)."
    fi
  fi

  # Require verified production-mode image attestation and credential audit before packaging
  verify_golden_image_attestation_and_credentials "$golden_disk" "$BUILD_MODE" "$admin_password"

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
    (cd "$SCRIPT_DIR/tools" && CGO_ENABLED=0 go build -o "$payload_dir/tools/pki_init" pki_init.go)
    (cd "$SCRIPT_DIR/tools" && CGO_ENABLED=0 go build -o "$payload_dir/tools/kv_config_init" kv_config_init.go)
    mkdir -p "${PROVENANCE_DIR}"
    jq -n \
      --arg name "pki_init" \
      --arg type "go" \
      --arg repo "local" \
      --arg commit "local" \
      --arg dest "tools/pki_init" \
      '{name: $name, type: $type, repo: $repo, ref: "local", commit_sha: $commit, dest: $dest}' \
      > "${PROVENANCE_DIR}/host_bin_0.json"
    jq -n \
      --arg name "kv_config_init" \
      --arg type "go" \
      --arg repo "local" \
      --arg commit "local" \
      --arg dest "tools/kv_config_init" \
      '{name: $name, type: $type, repo: $repo, ref: "local", commit_sha: $commit, dest: $dest}' \
      > "${PROVENANCE_DIR}/host_bin_1.json"
  fi

  # Bundle VyOS golden disk
  log "Bundling VyOS Golden Disk into ISO payload..."
  cp "$golden_disk" "$payload_dir/images/vyos-golden.qcow2"
  cp "${golden_disk}.sha256" "$payload_dir/images/vyos-golden.qcow2.sha256"
  [ -f "${golden_disk}.attestation.json" ] && cp "${golden_disk}.attestation.json" "$payload_dir/images/vyos-golden.qcow2.attestation.json"

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

  # Generate artifact image details manifest and embed into appliance payload
  log "Generating artifact image details manifest..."
  generate_provenance_manifest "${payload_dir}/config/image_details.json"

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
  generate_provenance_manifest "${OUTPUT_DIR}/image_details.json" "$final_iso"
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