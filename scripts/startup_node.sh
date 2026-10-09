#!/usr/bin/env bash
# ==============================================================================
# OpenLAN Gateway (OLG) Ubuntu Orchestrator: Master Startup & Boot Reconciliation
# SPEC Reference: SPEC.md section 4.1 & REQUIREMENTS.md
# ==============================================================================
set -euo pipefail

log() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$timestamp] [$level] $msg"
  logger -t "olg-orchestrator" "[$level] $msg" 2>/dev/null || true
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ------------------------------------------------------------------------------
# Privilege & Defaults Configuration
# ------------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_error "startup_node.sh must be executed with root privileges."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Global Paths
OPT_OLG_DIR="/opt/olg"
IMAGES_DIR="$OPT_OLG_DIR/images"
CONFIG_DIR="$OPT_OLG_DIR/config"
CERTS_DIR="$CONFIG_DIR/certs"
JWT_DIR="$CONFIG_DIR/jwt"
DATA_DIR="$OPT_OLG_DIR/data/nats"
SCRIPTS_DIR="$OPT_OLG_DIR/scripts"
TOOLS_DIR="$OPT_OLG_DIR/tools"

ETC_OLG_DIR="/etc/olg"
CLIENT_DIR="$ETC_OLG_DIR/client"
GUEST_SECRETS_DIR="$ETC_OLG_DIR/guest-secrets"
JOURNAL_FILE="$ETC_OLG_DIR/credential-generation.json"
HARDWARE_PROFILE="$ETC_OLG_DIR/hardware-profile.json"

# CLI Defaults
GOLDEN_IMAGE_PATH="$IMAGES_DIR/vyos-golden.qcow2"
FLAG_FORCE_RESEED="false"
FLAG_RECREATE_VM="false"
FLAG_SKIP_NETPLAN="false"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

OpenLAN Gateway (OLG) Node Orchestrator & Boot Restoration

Options:
  --image <PATH>             Path to VyOS Golden Master QCOW2 image (Default: /opt/olg/images/vyos-golden.qcow2)
  --force-reseed             Force reset NATS KV desired configuration to baseline template
  --recreate-vm              Force recreation of vyos-router domain with a fresh transient overlay
  --skip-netplan             Skip host Netplan br-mgmt configuration
  -h, --help                 Display this help message
EOF
  exit 0
}

# Parse CLI Arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      GOLDEN_IMAGE_PATH="$2"
      shift 2
      ;;
    --force-reseed)
      FLAG_FORCE_RESEED="true"
      shift
      ;;
    --recreate-vm)
      FLAG_RECREATE_VM="true"
      shift
      ;;
    --skip-netplan)
      FLAG_SKIP_NETPLAN="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown CLI parameter: $1"
      usage
      ;;
  esac
done

log_info "================================================================="
log_info "Starting OLG Node Orchestrator & Boot Reconciliation"
log_info "================================================================="

# ------------------------------------------------------------------------------
# Phase 1: Preflight Dependency & Golden Master Image Verification
# ------------------------------------------------------------------------------
log_info "Phase 1: Validating system dependencies and golden master image..."

for tool in qemu-system-x86_64 virsh virt-xml-validate docker jq openssl ip lspci ping modprobe sha256sum netplan; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Missing required system tool: $tool"
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  log_error "Missing required Docker Compose plugin ('docker compose version' failed)."
  exit 1
fi

if [ ! -f "$GOLDEN_IMAGE_PATH" ]; then
  log_error "Golden master image not found at: $GOLDEN_IMAGE_PATH"
  exit 1
fi

chown -R root:kvm /opt/olg/images 2>/dev/null || chown -R root:libvirt-qemu /opt/olg/images 2>/dev/null || true
chmod 1775 /opt/olg/images 2>/dev/null || true
chmod 0644 "$GOLDEN_IMAGE_PATH" 2>/dev/null || true

CHECKSUM_FILE="${GOLDEN_IMAGE_PATH}.sha256"
if [ ! -f "$CHECKSUM_FILE" ]; then
  log_error "Golden master image checksum manifest missing at: $CHECKSUM_FILE (immutable appliance requires cryptographic verification)."
  exit 1
fi

log_info "Verifying SHA-256 integrity of golden master disk..."
if ! (cd "$(dirname "$GOLDEN_IMAGE_PATH")" && sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>&1); then
  log_error "Cryptographic verification failed for $GOLDEN_IMAGE_PATH against $CHECKSUM_FILE"
  exit 1
fi
log_info "Golden master image integrity verified [OK]."

REQUIRED_IMAGES=("nats:2.10-alpine" "ucentral-client:latest")
for img in "${REQUIRED_IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    log_error "Required local container image '$img' is missing from local Docker cache (offline appliance requires pre-cached images)."
    exit 1
  fi
  log_info "Pre-cached Docker container image '$img' verified [OK]."
done

# ------------------------------------------------------------------------------
# Phase 2: Hardware Discovery & Policy: 1 NIC -> Take for WAN; >1 NICs -> Preserve 1
# ------------------------------------------------------------------------------
log_info "Phase 2: Executing hardware discovery and PCI allocation policy..."

mkdir -p "$ETC_OLG_DIR" "$OPT_OLG_DIR" "$CONFIG_DIR" "$CERTS_DIR" "$JWT_DIR" "$DATA_DIR" "$CLIENT_DIR" "$GUEST_SECRETS_DIR"

# Discover all PCI Ethernet Controllers (Class 0200)
PCI_ETH_LIST=($(lspci -Dnn -d ::0200 | awk '{print $1}'))
PCI_ETH_COUNT="${#PCI_ETH_LIST[@]}"

log_info "Discovered $PCI_ETH_COUNT PCI Ethernet controller(s): ${PCI_ETH_LIST[*]:-none}"

get_pci_mac() {
  local bdf="$1"
  for addr_file in /sys/bus/pci/devices/"$bdf"/net/*/address; do
    if [ -f "$addr_file" ]; then
      cat "$addr_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n 1
      return 0
    fi
  done
  return 1
}

get_pci_sysfs_path() {
  local bdf="$1"
  if [ -d "/sys/bus/pci/devices/$bdf" ]; then
    readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null || echo ""
  fi
}

get_pci_prop() {
  local bdf="$1"
  local prop="$2"
  if [ -f "/sys/bus/pci/devices/$bdf/$prop" ]; then
    cat "/sys/bus/pci/devices/$bdf/$prop" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo ""
  fi
}

validate_pci_identity() {
  local bdf="$1"
  local expected_mac="$2"
  local expected_path="$3"
  local expected_vendor="$4"
  local expected_device="$5"
  local expected_class="$6"

  [ -n "$bdf" ] && [ -d "/sys/bus/pci/devices/$bdf" ] || return 1

  local cur_path cur_vendor cur_device cur_class cur_mac
  cur_path=$(get_pci_sysfs_path "$bdf")
  cur_vendor=$(get_pci_prop "$bdf" "vendor")
  cur_device=$(get_pci_prop "$bdf" "device")
  cur_class=$(get_pci_prop "$bdf" "class")
  cur_mac=$(get_pci_mac "$bdf" || true)

  # Primary validation: Stable PCIe topology path is authoritative when specified
  if [ -n "$expected_path" ]; then
    if [ "$cur_path" != "$expected_path" ]; then
      return 1
    fi
    if [ -n "$expected_vendor" ] && [ "$cur_vendor" != "$expected_vendor" ]; then
      return 1
    fi
    if [ -n "$expected_device" ] && [ "$cur_device" != "$expected_device" ]; then
      return 1
    fi
    if [ -n "$expected_class" ] && [ "$cur_class" != "$expected_class" ]; then
      return 1
    fi
    if [ -n "$expected_mac" ] && [ -n "$cur_mac" ] && [ "$cur_mac" != "$expected_mac" ]; then
      return 1
    fi
    return 0
  fi

  # Secondary validation: When no expected_path is specified, validate by MAC
  if [ -n "$expected_mac" ]; then
    if [ -n "$cur_mac" ] && [ "$cur_mac" = "$expected_mac" ]; then
      if [ -n "$expected_vendor" ] && [ "$cur_vendor" != "$expected_vendor" ]; then
        return 1
      fi
      if [ -n "$expected_device" ] && [ "$cur_device" != "$expected_device" ]; then
        return 1
      fi
      if [ -n "$expected_class" ] && [ "$cur_class" != "$expected_class" ]; then
        return 1
      fi
      return 0
    fi
    return 1
  fi

  # Fallback: Vendor + Device + Class match if neither path nor MAC was specified
  if [ -n "$expected_vendor" ] && [ "$cur_vendor" = "$expected_vendor" ] && \
     [ -n "$expected_device" ] && [ "$cur_device" = "$expected_device" ]; then
    if [ -n "$expected_class" ] && [ "$cur_class" != "$expected_class" ]; then
      return 1
    fi
    return 0
  fi

  return 1
}

WAN_PCI=""
PROTECTED_NIC=""
LAN_TYPE=""
LAN_PCI=""
LAN_PCI_LIST=()
EXP_WAN_PATH=""
EXP_WAN_BDF=""
EXP_WAN_MAC=""
EXP_WAN_VENDOR=""
EXP_WAN_DEVICE=""
EXP_PROT_PATH=""
EXP_PROT_BDF=""
EXP_PROT_MAC=""
EXP_PROT_VENDOR=""
EXP_PROT_DEVICE=""
EXP_LAN_TYPE=""
EXP_LAN_USB_PATH=""
LAN_USB_VENDOR=""
LAN_USB_PRODUCT=""
LAN_USB_BUS=""
LAN_USB_DEV=""
LAN_USB_PATH=""
LAN_USB_MAC=""

# ------------------------------------------------------------------------------
# Phase 2: Immutable Model Hardware Profile Resolution
# ------------------------------------------------------------------------------
log_info "Phase 2: Resolving hardware profile from $HARDWARE_PROFILE..."

if [ ! -f "$HARDWARE_PROFILE" ]; then
  log_error "FATAL: Immutable hardware profile '$HARDWARE_PROFILE' does not exist."
  log_error "Appliance firmware images must include a valid /etc/olg/hardware-profile.json. Aborting boot."
  exit 1
fi

if ! jq empty "$HARDWARE_PROFILE" 2>/dev/null; then
  log_error "FATAL: '$HARDWARE_PROFILE' contains invalid JSON syntax. Please check the file formatting."
  exit 1
fi

normalize_bdf() {
  local raw="$1"
  [ -z "$raw" ] && echo "" && return 0
  if [[ "$raw" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
    echo "0000:$raw"
  else
    echo "$raw"
  fi
}

# 1. Resolve and protect host management interface from profile
EXP_PROT_PATH=$(jq -r '.host_management.pci_path // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_PROT_BDF_RAW=$(jq -r '.host_management.pci_bdf // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_PROT_BDF=$(normalize_bdf "$EXP_PROT_BDF_RAW")
EXP_PROT_MAC=$(jq -r '.host_management.mac // empty' "$HARDWARE_PROFILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
EXP_PROT_VENDOR=$(jq -r '.host_management.vendor // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_PROT_DEVICE=$(jq -r '.host_management.device // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)

if [ -n "$EXP_PROT_PATH" ]; then
  for bdf in "${PCI_ETH_LIST[@]}"; do
    if [ "$(get_pci_sysfs_path "$bdf")" = "$EXP_PROT_PATH" ]; then
      PROTECTED_NIC="$bdf"
      break
    fi
  done
  if [ -z "$PROTECTED_NIC" ]; then
    log_error "FATAL: Declared host management pci_path '$EXP_PROT_PATH' could not be resolved in sysfs. Aborting."
    exit 1
  fi
elif [ -n "$EXP_PROT_BDF" ]; then
  if [ -d "/sys/bus/pci/devices/$EXP_PROT_BDF" ]; then
    PROTECTED_NIC="$EXP_PROT_BDF"
  else
    log_error "FATAL: Declared host management pci_bdf '$EXP_PROT_BDF' does not exist in sysfs. Aborting."
    exit 1
  fi
fi

if [ -n "$EXP_PROT_PATH" ] || [ -n "$EXP_PROT_BDF" ]; then
  if [ -z "$PROTECTED_NIC" ]; then
    log_error "FATAL: Unable to resolve declared host management NIC from hardware profile in sysfs."
    log_error "Declared host management (BDF: '${EXP_PROT_BDF:-none}', Path: '${EXP_PROT_PATH:-none}') did not match any available PCI Ethernet controller."
    exit 1
  fi

  if ! validate_pci_identity "$PROTECTED_NIC" "$EXP_PROT_MAC" "$EXP_PROT_PATH" "$EXP_PROT_VENDOR" "$EXP_PROT_DEVICE" ""; then
    log_error "FATAL: Host management NIC ($PROTECTED_NIC) failed identity validation against hardware profile."
    exit 1
  fi

  prot_class=$(cat "/sys/bus/pci/devices/$PROTECTED_NIC/class" 2>/dev/null || echo "")
  if [[ "$prot_class" != 0x0200* ]]; then
    log_error "FATAL: Host management controller '$PROTECTED_NIC' (class '$prot_class') is not an Ethernet controller. Aborting."
    exit 1
  fi

  log_info "Protected host management interface positively identified and validated: $PROTECTED_NIC"
else
  log_info "Single-NIC mode: No physical host management NIC declared in profile; management is virtualized via br-mgmt."
fi

# 2. Resolve WAN interface from profile
EXP_WAN_PATH=$(jq -r '.wan.pci_path // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_WAN_BDF_RAW=$(jq -r '.wan.pci_bdf // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_WAN_BDF=$(normalize_bdf "$EXP_WAN_BDF_RAW")
EXP_WAN_MAC=$(jq -r '.wan.mac // empty' "$HARDWARE_PROFILE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
EXP_WAN_VENDOR=$(jq -r '.wan.vendor // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_WAN_DEVICE=$(jq -r '.wan.device // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)

log_info "Hardware profile declares WAN: bdf='${EXP_WAN_BDF:-none}', path='${EXP_WAN_PATH:-none}'"

if [ -n "$EXP_WAN_PATH" ]; then
  for bdf in "${PCI_ETH_LIST[@]}"; do
    if [ "$bdf" != "$PROTECTED_NIC" ] && [ "$(get_pci_sysfs_path "$bdf")" = "$EXP_WAN_PATH" ]; then
      WAN_PCI="$bdf"
      break
    fi
  done
  if [ -z "$WAN_PCI" ]; then
    log_error "FATAL: Declared WAN pci_path '$EXP_WAN_PATH' could not be resolved in sysfs. Aborting."
    exit 1
  fi
elif [ -n "$EXP_WAN_BDF" ]; then
  if [ -d "/sys/bus/pci/devices/$EXP_WAN_BDF" ] && [ "$EXP_WAN_BDF" != "$PROTECTED_NIC" ]; then
    WAN_PCI="$EXP_WAN_BDF"
  else
    log_error "FATAL: Declared WAN pci_bdf '$EXP_WAN_BDF' does not exist in sysfs or conflicts with protected NIC. Aborting."
    exit 1
  fi
fi

if [ -z "$WAN_PCI" ]; then
  log_error "FATAL: Failed to resolve valid WAN controller from $HARDWARE_PROFILE in sysfs."
  log_error "Declared WAN (BDF: '${EXP_WAN_BDF:-none}', Path: '${EXP_WAN_PATH:-none}') did not match any available PCI Ethernet controller."
  log_error "Discovered PCI Ethernet controllers: ${PCI_ETH_LIST[*]:-none} (Protected: ${PROTECTED_NIC:-none})."
  exit 1
fi

# Validate resolved WAN PCI controller against profile expectation
if [ -n "$EXP_WAN_PATH" ] || [ -n "$EXP_WAN_MAC" ] || [ -n "$EXP_WAN_VENDOR" ] || [ -n "$EXP_WAN_DEVICE" ]; then
  if ! validate_pci_identity "$WAN_PCI" "$EXP_WAN_MAC" "$EXP_WAN_PATH" "$EXP_WAN_VENDOR" "$EXP_WAN_DEVICE" ""; then
    log_error "FATAL: Resolved WAN PCI ($WAN_PCI) failed identity validation against hardware profile contract. Aborting."
    exit 1
  fi
fi

wan_class=$(cat "/sys/bus/pci/devices/$WAN_PCI/class" 2>/dev/null || echo "")
if [[ "$wan_class" != 0x0200* ]]; then
  log_error "FATAL: WAN controller '$WAN_PCI' has PCI class '$wan_class' (is not an Ethernet controller). Aborting."
  exit 1
fi
log_info "Resolved WAN controller from hardware profile: $WAN_PCI"

# Verify dedicated 1:1 IOMMU Group Isolation for WAN PCI
IOMMU_GRP_LINK="/sys/bus/pci/devices/$WAN_PCI/iommu_group"
if [ ! -L "$IOMMU_GRP_LINK" ]; then
  log_error "IOMMU group link missing for WAN PCI $WAN_PCI. Ensure IOMMU (VT-d/AMD-Vi) is enabled in BIOS and kernel."
  exit 1
fi
IOMMU_DEV_COUNT=$(ls "$IOMMU_GRP_LINK/devices" 2>/dev/null | wc -l)
if [ "$IOMMU_DEV_COUNT" -ne 1 ]; then
  log_error "IOMMU Group Isolation Failure: $WAN_PCI IOMMU group contains $IOMMU_DEV_COUNT devices (must equal 1 for safe passthrough)."
  exit 1
fi

# 3. Resolve LAN interfaces (PCI / SFP / USB) from profile
lan_type=$(jq -r '.lan.type // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)
EXP_LAN_USB_PATH=$(jq -r '.lan.usb_path // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)

if [ "$lan_type" = "usb" ] || [ -n "$EXP_LAN_USB_PATH" ]; then
  if [ -n "$EXP_LAN_USB_PATH" ] && [ -d "/sys/bus/usb/devices/$EXP_LAN_USB_PATH" ]; then
    LAN_TYPE="usb"
    LAN_USB_PATH="$EXP_LAN_USB_PATH"
    dev_dir="/sys/bus/usb/devices/$LAN_USB_PATH"
    LAN_USB_VENDOR=$(cat "$dev_dir/idVendor" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    LAN_USB_PRODUCT=$(cat "$dev_dir/idProduct" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    LAN_USB_BUS=$(cat "$dev_dir/busnum" 2>/dev/null || true)
    LAN_USB_DEV=$(cat "$dev_dir/devnum" 2>/dev/null || true)
    for addr_f in "$dev_dir"/*/net/*/address "$dev_dir"/*/*/net/*/address "$dev_dir"/net/*/address; do
      if [ -f "$addr_f" ]; then
        LAN_USB_MAC=$(cat "$addr_f" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n 1)
        break
      fi
    done
    if [ -z "$LAN_USB_MAC" ]; then
      log_error "FATAL: USB device at '$LAN_USB_PATH' (ID $LAN_USB_VENDOR:$LAN_USB_PRODUCT) does not provide a network interface. Aborting."
      exit 1
    fi
    log_info "Resolved USB LAN from hardware profile: $LAN_USB_PATH (ID $LAN_USB_VENDOR:$LAN_USB_PRODUCT, Bus $LAN_USB_BUS Dev $LAN_USB_DEV, MAC $LAN_USB_MAC)"
  else
    log_error "FATAL: Declared USB LAN '$EXP_LAN_USB_PATH' does not exist in sysfs (/sys/bus/usb/devices/$EXP_LAN_USB_PATH). Aborting."
    exit 1
  fi
elif [ "$lan_type" = "pci" ] || [ -n "$(jq -r '.lan_ports // empty' "$HARDWARE_PROFILE" 2>/dev/null)" ]; then
  LAN_TYPE="pci"
  NUM_LAN_ENTRIES=$(jq 'if .lan_ports and (.lan_ports | type == "array") and (.lan_ports | length > 0) then (.lan_ports | length) elif .lan and (.lan | type == "object") and (.lan.type == "pci" or .lan.pci_path or .lan.pci_bdf) then 1 else 0 end' "$HARDWARE_PROFILE" 2>/dev/null || echo 0)

  if [ "$NUM_LAN_ENTRIES" -eq 0 ]; then
    log_error "FATAL: No valid LAN PCI entries defined in $HARDWARE_PROFILE. Aborting."
    exit 1
  fi

  for ((idx=0; idx<NUM_LAN_ENTRIES; idx++)); do
    ENTRY_JSON=$(jq -c "if .lan_ports and (.lan_ports | type == \"array\") and (.lan_ports | length > 0) then .lan_ports[$idx] else .lan end" "$HARDWARE_PROFILE" 2>/dev/null || echo "{}")
    entry_path=$(jq -r '.pci_path // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)
    entry_bdf_raw=$(jq -r '.pci_bdf // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)
    entry_bdf=$(normalize_bdf "$entry_bdf_raw")
    entry_mac=$(jq -r '.mac // empty' <<< "$ENTRY_JSON" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    entry_vendor=$(jq -r '.vendor // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)
    entry_device=$(jq -r '.device // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)

    resolved_bdf=""
    if [ -n "$entry_path" ]; then
      for bdf in "${PCI_ETH_LIST[@]}"; do
        if [ "$bdf" != "$PROTECTED_NIC" ] && [ "$bdf" != "$WAN_PCI" ] && [ "$(get_pci_sysfs_path "$bdf")" = "$entry_path" ]; then
          resolved_bdf="$bdf"
          break
        fi
      done
      if [ -z "$resolved_bdf" ]; then
        log_error "FATAL: Declared LAN PCI entry $idx pci_path '$entry_path' could not be resolved in sysfs. Aborting."
        exit 1
      fi
    elif [ -n "$entry_bdf" ]; then
      if [ -d "/sys/bus/pci/devices/$entry_bdf" ] && [ "$entry_bdf" != "$PROTECTED_NIC" ] && [ "$entry_bdf" != "$WAN_PCI" ]; then
        resolved_bdf="$entry_bdf"
      else
        log_error "FATAL: Declared LAN PCI entry $idx pci_bdf '$entry_bdf' does not exist in sysfs or conflicts with protected/WAN NIC. Aborting."
        exit 1
      fi
    fi

    if [ -z "$resolved_bdf" ]; then
      log_error "FATAL: Declared LAN PCI entry $idx (BDF: '${entry_bdf:-none}', Path: '${entry_path:-none}') could not be resolved in sysfs."
      exit 1
    fi

    for existing in "${LAN_PCI_LIST[@]}"; do
      if [ "$existing" = "$resolved_bdf" ]; then
        log_error "FATAL: Duplicate LAN PCI controller '$resolved_bdf' resolved for multiple port entries. Aborting."
        exit 1
      fi
    done

    if [ -n "$entry_path" ] || [ -n "$entry_mac" ] || [ -n "$entry_vendor" ] || [ -n "$entry_device" ]; then
      if ! validate_pci_identity "$resolved_bdf" "$entry_mac" "$entry_path" "$entry_vendor" "$entry_device" ""; then
        log_error "FATAL: LAN PCI controller ($resolved_bdf) failed identity validation against profile entry $idx contract. Aborting."
        exit 1
      fi
    fi

    cur_lan_class=$(cat "/sys/bus/pci/devices/$resolved_bdf/class" 2>/dev/null || echo "")
    if [[ "$cur_lan_class" != 0x0200* ]]; then
      log_error "FATAL: LAN PCI controller '$resolved_bdf' (class '$cur_lan_class') is not an Ethernet controller. Aborting."
      exit 1
    fi

    lan_iommu_link="/sys/bus/pci/devices/$resolved_bdf/iommu_group"
    if [ ! -L "$lan_iommu_link" ]; then
      log_error "IOMMU group link missing for LAN PCI $resolved_bdf. Ensure IOMMU is enabled."
      exit 1
    fi
    lan_iommu_count=$(ls "$lan_iommu_link/devices" 2>/dev/null | wc -l)
    if [ "$lan_iommu_count" -ne 1 ]; then
      log_error "IOMMU Group Isolation Failure: $resolved_bdf IOMMU group contains $lan_iommu_count devices (must equal 1)."
      exit 1
    fi

    LAN_PCI_LIST+=("$resolved_bdf")
  done

  if [ "${#LAN_PCI_LIST[@]}" -gt 0 ]; then
    LAN_PCI="${LAN_PCI_LIST[0]}"
    log_info "Resolved and validated ${#LAN_PCI_LIST[@]} LAN PCI/SFP controller(s) from hardware profile: ${LAN_PCI_LIST[*]}"
  else
    log_error "FATAL: Declared LAN PCI controller(s) could not be resolved in sysfs. Aborting."
    exit 1
  fi
fi

if [ -z "$LAN_TYPE" ]; then
  log_error "FATAL: No valid LAN interface (USB or PCI) resolved from $HARDWARE_PROFILE. Aborting."
  exit 1
fi

log_info "Hardware validation completed: WAN=${WAN_PCI:-none}, LAN_TYPE=${LAN_TYPE:-none}, LAN_PCI=${LAN_PCI_LIST[*]:-${LAN_PCI:-none}}, LAN_USB=${LAN_USB_PATH:-none}, Protected Management=${PROTECTED_NIC:-none}"

# ------------------------------------------------------------------------------
# Phase 3: Credential Journal Audit & Crash Recovery
# ------------------------------------------------------------------------------
log_info "Phase 3: Auditing credential transaction journal..."

if [ ! -f "$JOURNAL_FILE" ]; then
  log_info "Initializing baseline credential transaction journal..."
  jq -n --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{generation: 1, previous_generation: 0, state: "COMMITTED", participants: [], updated_at: $ts}' \
    > "$JOURNAL_FILE"
  chmod 0600 "$JOURNAL_FILE" 2>/dev/null || true
else
  JOURNAL_STATE=$(jq -r '.state // "UNKNOWN"' "$JOURNAL_FILE" 2>/dev/null || echo "CORRUPT")
  case "$JOURNAL_STATE" in
    "COMMITTED")
      log_info "Credential transaction journal is clean (state: COMMITTED) [OK]."
      ;;
    "PREPARED"|"FILES_INSTALLED"|"VERIFIED"|"ROLLBACK_IN_PROGRESS")
      log_warn "Uncommitted credential transaction detected (state: $JOURNAL_STATE); rolling back incomplete transaction..."
      rm -f /opt/olg/config/jwt/*.tmp /opt/olg/config/*.tmp /etc/olg/client/*.tmp /etc/olg/guest-secrets/*.tmp 2>/dev/null || true
      rm -rf /etc/olg/staging /opt/olg/config/jwt/staging 2>/dev/null || true

      PARTICIPANTS=()
      while IFS= read -r p; do
        [ -n "$p" ] && PARTICIPANTS+=("$p")
      done < <(jq -r '.participants[]?' "$JOURNAL_FILE" 2>/dev/null || true)

      RESTORE_SUCCESS=true
      if [ "${#PARTICIPANTS[@]}" -gt 0 ]; then
        log_info "Restoring ${#PARTICIPANTS[@]} recorded transaction participants from .prev snapshots..."
        for participant in "${PARTICIPANTS[@]}"; do
          SRC=""
          DST=""
          case "$participant" in
            "operator.jwt")       SRC="/opt/olg/config/jwt/operator.jwt.prev"; DST="/opt/olg/config/jwt/operator.jwt" ;;
            "sys_account.jwt")    SRC="/opt/olg/config/jwt/sys_account.jwt.prev"; DST="/opt/olg/config/jwt/sys_account.jwt" ;;
            "olg_account.jwt")    SRC="/opt/olg/config/jwt/olg_account.jwt.prev"; DST="/opt/olg/config/jwt/olg_account.jwt" ;;
            "resolver.conf")      SRC="/opt/olg/config/resolver.conf.prev"; DST="/opt/olg/config/resolver.conf" ;;
            "orchestrator.creds") SRC="/opt/olg/config/jwt/orchestrator.creds.prev"; DST="/opt/olg/config/jwt/orchestrator.creds" ;;
            "ucentral.creds")     SRC="/etc/olg/client/ucentral.creds.prev"; DST="/etc/olg/client/ucentral.creds" ;;
            "vyos_agent.creds")   SRC="/etc/olg/guest-secrets/vyos_agent.creds.prev"; DST="/etc/olg/guest-secrets/vyos_agent.creds" ;;
            "agent.env")          SRC="/etc/olg/guest-secrets/agent.env.prev"; DST="/etc/olg/guest-secrets/agent.env" ;;
            *)
              log_error "Unknown participant '$participant' recorded in transaction journal."
              RESTORE_SUCCESS=false
              continue
              ;;
          esac

          if [ -f "$SRC" ]; then
            if cp -f --preserve=mode,ownership,timestamps "$SRC" "$DST"; then
              log_info "Restored participant '$participant' from $SRC"
            else
              log_error "Failed to copy $SRC to $DST for participant '$participant'"
              RESTORE_SUCCESS=false
            fi
          else
            log_error "Snapshot file $SRC missing for participant '$participant'!"
            RESTORE_SUCCESS=false
          fi
        done
      fi

      if [ "$RESTORE_SUCCESS" != "true" ]; then
        log_error "CRITICAL ERROR: Transaction rollback failed; one or more participant snapshots could not be restored."
        log_error "Transitioning journal to ROLLBACK_FAILED and preserving all *.prev snapshots for forensic recovery."
        jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          '.state = "ROLLBACK_FAILED" | .updated_at = $ts' \
          "$JOURNAL_FILE" > "${JOURNAL_FILE}.tmp" && mv -f "${JOURNAL_FILE}.tmp" "$JOURNAL_FILE"
        chmod 0600 "$JOURNAL_FILE" 2>/dev/null || true
        exit 1
      fi

      sync
      PREV_GEN=$(jq -r '.previous_generation // 1' "$JOURNAL_FILE" 2>/dev/null || echo 1)
      [ "$PREV_GEN" -le 0 ] && PREV_GEN=1
      jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --argjson prev "$PREV_GEN" \
        '.state = "COMMITTED" | .generation = $prev | .participants = [] | .updated_at = $ts' \
        "$JOURNAL_FILE" > "${JOURNAL_FILE}.tmp" && mv -f "${JOURNAL_FILE}.tmp" "$JOURNAL_FILE"
      chmod 0600 "$JOURNAL_FILE" 2>/dev/null || true
      rm -f /opt/olg/config/jwt/*.prev /opt/olg/config/*.prev /etc/olg/client/*.prev /etc/olg/guest-secrets/*.prev 2>/dev/null || true
      log_info "Credential journal successfully rolled back to generation $PREV_GEN (state: COMMITTED) [OK]."
      ;;
    "ROLLBACK_FAILED")
      log_error "CRITICAL SAFETY ABORT: Credential journal is in ROLLBACK_FAILED state."
      log_error "An unrecoverable credential transaction failure occurred. All *.prev snapshots and journal state are preserved for forensic recovery."
      log_error "Refusing to execute PKI bootstrap, NATS reconciliation, or VFIO handoff until manual intervention resolves the failed transaction."
      exit 1
      ;;
    *)
      log_error "CRITICAL SAFETY ABORT: Credential transaction journal is corrupt, unreadable, or in an unrecognized state (state: $JOURNAL_STATE)."
      log_error "Refusing to overwrite journal or proceed with unverified credentials. Preserving journal and all *.prev snapshots for forensic recovery."
      if [ -f "$JOURNAL_FILE" ]; then
        BACKUP_CORRUPT="${JOURNAL_FILE}.corrupt.$(date +%s)"
        cp -f --preserve=mode,ownership,timestamps "$JOURNAL_FILE" "$BACKUP_CORRUPT" 2>/dev/null || true
        log_info "Preserved corrupt journal snapshot to $BACKUP_CORRUPT"
      fi
      exit 1
      ;;
  esac
fi

# ------------------------------------------------------------------------------
# Phase 4: Local Appliance PKI & NATS JWT/NKey Bootstrapping
# ------------------------------------------------------------------------------
log_info "Phase 4: Auditing local appliance PKI and NATS credentials..."

# Tier 1: TLS Root CA (Preserved independently; validated cryptographically)
CA_REGENERATE="false"
if [ ! -f "$CERTS_DIR/ca.key" ] || [ ! -f "$CERTS_DIR/ca.crt" ]; then
  CA_REGENERATE="true"
else
  # Validate x509 cert and RSA private key integrity & modulus match
  if ! openssl x509 -in "$CERTS_DIR/ca.crt" -noout >/dev/null 2>&1 || \
     ! openssl rsa -in "$CERTS_DIR/ca.key" -check -noout >/dev/null 2>&1; then
    log_warn "Corrupted or invalid Root CA certificate/key detected; scheduling CA regeneration..."
    CA_REGENERATE="true"
  else
    CA_CRT_MOD=$(openssl x509 -noout -modulus -in "$CERTS_DIR/ca.crt" 2>/dev/null | openssl md5 | awk '{print $NF}')
    CA_KEY_MOD=$(openssl rsa -noout -modulus -in "$CERTS_DIR/ca.key" 2>/dev/null | openssl md5 | awk '{print $NF}')
    if [ -z "$CA_CRT_MOD" ] || [ "$CA_CRT_MOD" != "$CA_KEY_MOD" ]; then
      log_warn "Root CA certificate and private key modulus mismatch detected; scheduling CA regeneration..."
      CA_REGENERATE="true"
    fi
  fi
fi

if [ "$CA_REGENERATE" = "true" ]; then
  log_info "Generating local Root CA..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=OLG-Local-Root-CA/O=OpenLAN-Gateway" >/dev/null 2>&1
  chmod 0600 "$CERTS_DIR/ca.key"
  chmod 0644 "$CERTS_DIR/ca.crt"
fi

# Tier 2: NATS Server TLS Certificate (Signed by existing Root CA; validated cryptographically)
SERVER_CERT_REGENERATE="false"
if [ "$CA_REGENERATE" = "true" ] || [ ! -f "$CERTS_DIR/nats-server.key" ] || [ ! -f "$CERTS_DIR/nats-server.crt" ]; then
  SERVER_CERT_REGENERATE="true"
else
  if ! openssl x509 -in "$CERTS_DIR/nats-server.crt" -noout >/dev/null 2>&1 || \
     ! openssl rsa -in "$CERTS_DIR/nats-server.key" -check -noout >/dev/null 2>&1; then
    log_warn "Corrupted or invalid NATS server TLS certificate/key detected; regenerating..."
    SERVER_CERT_REGENERATE="true"
  else
    SRV_CRT_MOD=$(openssl x509 -noout -modulus -in "$CERTS_DIR/nats-server.crt" 2>/dev/null | openssl md5 | awk '{print $NF}')
    SRV_KEY_MOD=$(openssl rsa -noout -modulus -in "$CERTS_DIR/nats-server.key" 2>/dev/null | openssl md5 | awk '{print $NF}')
    if [ -z "$SRV_CRT_MOD" ] || [ "$SRV_CRT_MOD" != "$SRV_KEY_MOD" ]; then
      log_warn "NATS server certificate and private key modulus mismatch detected; regenerating..."
      SERVER_CERT_REGENERATE="true"
    elif ! openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/nats-server.crt" >/dev/null 2>&1; then
      log_warn "NATS server TLS certificate verification against Root CA failed; regenerating..."
      SERVER_CERT_REGENERATE="true"
    elif ! openssl x509 -in "$CERTS_DIR/nats-server.crt" -noout -text 2>/dev/null | grep -q "192.168.254.2"; then
      log_warn "NATS server TLS certificate missing required SAN (192.168.254.2); regenerating..."
      SERVER_CERT_REGENERATE="true"
    fi
  fi
fi

if [ "$SERVER_CERT_REGENERATE" = "true" ]; then
  log_info "Generating NATS server TLS certificate signed by local Root CA..."
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$CERTS_DIR/nats-server.key" \
    -out "$CERTS_DIR/nats-server.csr" \
    -subj "/CN=nats-server/O=OpenLAN-Gateway" >/dev/null 2>&1
  chmod 0600 "$CERTS_DIR/nats-server.key"

  cat <<EOF > "$CERTS_DIR/san.ext"
subjectAltName = @alt_names
[alt_names]
DNS.1 = nats-server
DNS.2 = localhost
IP.1 = 192.168.254.2
IP.2 = 127.0.0.1
EOF

  openssl x509 -req -in "$CERTS_DIR/nats-server.csr" \
    -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
    -out "$CERTS_DIR/nats-server.crt" -days 1825 \
    -extfile "$CERTS_DIR/san.ext" >/dev/null 2>&1
  chmod 0644 "$CERTS_DIR/nats-server.crt"
  rm -f "$CERTS_DIR/nats-server.csr" "$CERTS_DIR/san.ext"
fi

# Tier 3: NATS Operator, Account, and User Credential Reconciliation
BOOTSTRAP_BIN=""
if [ -x "$BASE_DIR/tools/nats_pki_bootstrap" ]; then
  BOOTSTRAP_BIN="$BASE_DIR/tools/nats_pki_bootstrap"
elif [ -x "$TOOLS_DIR/nats_pki_bootstrap" ]; then
  BOOTSTRAP_BIN="$TOOLS_DIR/nats_pki_bootstrap"
fi

REQUIRED_JWTS=("$JWT_DIR/operator.jwt" "$JWT_DIR/sys_account.jwt" "$JWT_DIR/olg_account.jwt" "$JWT_DIR/orchestrator.creds" "$CLIENT_DIR/ucentral.creds" "$GUEST_SECRETS_DIR/vyos_agent.creds" "$CONFIG_DIR/resolver.conf")
NATS_CREDS_RECONCILE="false"

for jwt_file in "${REQUIRED_JWTS[@]}"; do
  if [ ! -f "$jwt_file" ] || [ ! -s "$jwt_file" ]; then
    log_info "Missing or empty required NATS credential artifact ($jwt_file); scheduling reconciliation..."
    NATS_CREDS_RECONCILE="true"
    break
  fi
  if [[ "$jwt_file" == *.creds ]] && [ -n "$BOOTSTRAP_BIN" ]; then
    if ! "$BOOTSTRAP_BIN" --mode verify-creds --creds "$jwt_file" >/dev/null 2>&1; then
      log_warn "Corrupted or invalid decorated NATS credentials ($jwt_file); scheduling reconciliation..."
      NATS_CREDS_RECONCILE="true"
      break
    fi
  fi
done

if [ "$NATS_CREDS_RECONCILE" = "true" ]; then
  if [ -z "$BOOTSTRAP_BIN" ]; then
    log_error "CRITICAL ERROR: NATS credential reconciliation is required, but nats_pki_bootstrap binary was not found or is not executable."
    log_error "Checked paths: $BASE_DIR/tools/nats_pki_bootstrap and $TOOLS_DIR/nats_pki_bootstrap"
    exit 1
  fi
  log_info "Reconciling NATS JWTs, account keys, and user credentials..."
  "$BOOTSTRAP_BIN" \
    --out-jwt "$JWT_DIR" \
    --out-client "$CLIENT_DIR" \
    --out-guest "$GUEST_SECRETS_DIR" \
    --out-resolver "$CONFIG_DIR/resolver.conf"
fi

cp -f "$CERTS_DIR/ca.crt" "$CLIENT_DIR/ca.crt" 2>/dev/null || true
cp -f "$CERTS_DIR/ca.crt" "$GUEST_SECRETS_DIR/ca.crt" 2>/dev/null || true

[ -f "$BASE_DIR/config/nats.conf" ] && cp -f "$BASE_DIR/config/nats.conf" "$CONFIG_DIR/nats.conf"
[ -f "$BASE_DIR/config/docker-compose.yml" ] && cp -f "$BASE_DIR/config/docker-compose.yml" "$OPT_OLG_DIR/docker-compose.yml"

# Sync cloud TLS certs if provisioned in client repository or custom path
if [ -d "$BASE_DIR/../TIP-olg-ucentral-client/certs" ]; then
  cp -f "$BASE_DIR/../TIP-olg-ucentral-client/certs"/* "$CLIENT_DIR/" 2>/dev/null || true
fi

# Enforce secure directory permissions (0700 root:root)
chmod 0700 "$ETC_OLG_DIR" "$CONFIG_DIR" "$CERTS_DIR" "$JWT_DIR" "$CLIENT_DIR" "$GUEST_SECRETS_DIR" 2>/dev/null || true

# Seed baseline uCentral client configuration if missing
if [ ! -f "$CLIENT_DIR/config.json" ] && [ -f "$BASE_DIR/config/ucentral_client_template.json" ]; then
  cp -f "$BASE_DIR/config/ucentral_client_template.json" "$CLIENT_DIR/config.json"
fi

# Apply explicit file permissions based on artifact security classification:
# - Secrets, private keys, and .creds: 0600
# - Public certificates, environment configs, and JSON descriptors: 0644
chmod 0600 "$CERTS_DIR"/*.key "$JWT_DIR"/*.creds "$JWT_DIR"/*.nk "$CLIENT_DIR"/*.creds "$CLIENT_DIR"/*key*.pem "$CLIENT_DIR"/*.key "$GUEST_SECRETS_DIR"/*.creds "$GUEST_SECRETS_DIR"/agent.env "$CLIENT_DIR"/config.json 2>/dev/null || true
chmod 0644 "$CERTS_DIR"/*.crt "$JWT_DIR"/*.jwt "$CLIENT_DIR"/*.crt "$CLIENT_DIR"/*cert*.pem "$GUEST_SECRETS_DIR"/*.crt "$CONFIG_DIR"/*.conf 2>/dev/null || true

# Reconcile /etc/ucentral/interface_map.json
mkdir -p /etc/ucentral
INTERFACE_MAP_FILE="/etc/ucentral/interface_map.json"

SYS_SERIAL=""
if [ -f "$INTERFACE_MAP_FILE" ] && jq empty "$INTERFACE_MAP_FILE" 2>/dev/null && [ -n "$(jq -r '.serial // empty' "$INTERFACE_MAP_FILE" 2>/dev/null)" ]; then
  SYS_SERIAL=$(jq -r '.serial' "$INTERFACE_MAP_FILE")
  log_info "Preserving existing appliance serial from $INTERFACE_MAP_FILE: $SYS_SERIAL"
fi

if [ -z "$SYS_SERIAL" ]; then
  # Resolve authoritative 12-char lowercase MAC serial (WAN primary)
  wan_raw_mac="${EXP_WAN_MAC:-$(get_pci_mac "$WAN_PCI" 2>/dev/null || true)}"
  SYS_SERIAL=$(echo "$wan_raw_mac" | tr -d ':' | tr -d '-' | tr '[:upper:]' '[:lower:]')

  # Fallback to explicit serial in profile if WAN MAC is not available
  [ -z "$SYS_SERIAL" ] && SYS_SERIAL=$(jq -r '.serial // empty' "$HARDWARE_PROFILE" 2>/dev/null || true)

  # Fallback to Host Management or LAN USB MAC
  [ -z "$SYS_SERIAL" ] && SYS_SERIAL=$(echo "${EXP_PROT_MAC:-${LAN_USB_MAC:-}}" | tr -d ':' | tr -d '-' | tr '[:upper:]' '[:lower:]')

  # Fallback to DMI if no MAC available
  if [ -z "$SYS_SERIAL" ]; then
    SYS_SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)
    [ "$SYS_SERIAL" = "None" ] && SYS_SERIAL=""
    [ -z "$SYS_SERIAL" ] && SYS_SERIAL=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)
    [ -z "$SYS_SERIAL" ] && SYS_SERIAL="default-serial"
  fi
fi

MAP_ENTRIES=()
if [ -n "$WAN_PCI" ]; then
  wan_mac_fmt="${EXP_WAN_MAC:-$(get_pci_mac "$WAN_PCI" 2>/dev/null || true)}"
  wan_entry="{\"host_port\": \"eth0\", \"pci_address\": \"${WAN_PCI}\""
  [ -n "$wan_mac_fmt" ] && wan_entry+=", \"mac_address\": \"${wan_mac_fmt}\""
  wan_entry+=", \"vyos_port\": \"wan\", \"role\": \"wan\"}"
  MAP_ENTRIES+=("$wan_entry")
fi

if [ "$LAN_TYPE" = "pci" ] && [ "${#LAN_PCI_LIST[@]}" -gt 0 ]; then
  lan_idx=1
  for ((idx=0; idx<${#LAN_PCI_LIST[@]}; idx++)); do
    lan_pci="${LAN_PCI_LIST[$idx]}"
    ENTRY_JSON=$(jq -c "if .lan_ports and (.lan_ports | type == \"array\") and (.lan_ports | length > 0) then .lan_ports[$idx] else .lan end" "$HARDWARE_PROFILE" 2>/dev/null || echo "{}")
    lan_mac=$(jq -r '.mac // empty' <<< "$ENTRY_JSON" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    [ -z "$lan_mac" ] && lan_mac=$(get_pci_mac "$lan_pci" 2>/dev/null || true)
    lan_entry="{\"host_port\": \"eth${lan_idx}\", \"pci_address\": \"${lan_pci}\""
    [ -n "$lan_mac" ] && lan_entry+=", \"mac_address\": \"${lan_mac}\""
    lan_entry+=", \"vyos_port\": \"lan${lan_idx}\", \"role\": \"lan\"}"
    MAP_ENTRIES+=("$lan_entry")
    lan_idx=$((lan_idx + 1))
  done
elif [ "$LAN_TYPE" = "usb" ] || [ -n "${LAN_USB_PATH:-}" ] || [ -n "${LAN_USB_VENDOR:-}" ]; then
  usb_id="${LAN_USB_VENDOR:+${LAN_USB_VENDOR}:${LAN_USB_PRODUCT}}"
  lan_entry="{\"host_port\": \"usb0\""
  [ -n "$usb_id" ] && lan_entry+=", \"usb_id\": \"${usb_id}\""
  [ -n "${LAN_USB_PATH:-}" ] && lan_entry+=", \"usb_path\": \"${LAN_USB_PATH}\""
  [ -n "${LAN_USB_MAC:-}" ] && lan_entry+=", \"mac_address\": \"${LAN_USB_MAC}\""
  lan_entry+=", \"vyos_port\": \"lan1\", \"role\": \"lan\"}"
  MAP_ENTRIES+=("$lan_entry")
fi

MAPPINGS_JSON=$(IFS=,; echo "${MAP_ENTRIES[*]}")

cat <<EOF > /etc/ucentral/interface_map.json.tmp
{
  "serial": "${SYS_SERIAL}",
  "mappings": [
    ${MAPPINGS_JSON}
  ]
}
EOF
chmod 0644 /etc/ucentral/interface_map.json.tmp 2>/dev/null || true
mv -f /etc/ucentral/interface_map.json.tmp "$INTERFACE_MAP_FILE"
log_info "Reconciled interface map at $INTERFACE_MAP_FILE (serial: $SYS_SERIAL) [OK]."

cat <<EOF > "$GUEST_SECRETS_DIR/agent.env"
NATS_SERVER=tls://192.168.254.2:4222
NATS_CREDS_FILE=/etc/olg/secrets/vyos_agent.creds
NATS_CA_FILE=/etc/olg/secrets/ca.crt
EOF
chmod 0600 "$GUEST_SECRETS_DIR/agent.env" 2>/dev/null || true
chmod 0600 "$GUEST_SECRETS_DIR"/*.creds 2>/dev/null || true
chmod 0644 "$GUEST_SECRETS_DIR"/*.crt 2>/dev/null || true

# ------------------------------------------------------------------------------
# Phase 5: Host Management Bridge Setup (br-mgmt)
# ------------------------------------------------------------------------------
log_info "Phase 5: Configuring host management bridge (br-mgmt)..."

if [ "$FLAG_SKIP_NETPLAN" != "true" ] && [ -f "$BASE_DIR/config/netplan_bridges.yaml" ]; then
  cp -f "$BASE_DIR/config/netplan_bridges.yaml" /etc/netplan/99-olg-bridges.yaml
  chmod 0600 /etc/netplan/99-olg-bridges.yaml 2>/dev/null || true
  if ! netplan generate; then
    log_error "FATAL: Netplan configuration validation failed (netplan generate)."
    exit 1
  fi
  if ! netplan apply; then
    log_error "FATAL: Failed to apply Netplan bridge configuration (netplan apply)."
    exit 1
  fi
  log_info "Netplan bridge configuration successfully generated and applied [OK]."
else
  ip link add name br-mgmt type bridge 2>/dev/null || true
  ip addr add 192.168.254.2/24 dev br-mgmt 2>/dev/null || true
  ip link set br-mgmt up 2>/dev/null || true
  ip route add default via 192.168.254.1 dev br-mgmt metric 200 2>/dev/null || true
  which resolvectl >/dev/null 2>&1 && resolvectl dns br-mgmt 8.8.8.8 1.1.1.1 2>/dev/null || true
fi
log_info "Host bridge br-mgmt verified at 192.168.254.2/24 with gateway 192.168.254.1."

# ------------------------------------------------------------------------------
# Phase 6: Docker Microservices & Bounded NATS Readiness Gate
# ------------------------------------------------------------------------------
log_info "Phase 6: Deploying Docker container stack and awaiting NATS JetStream readiness..."

if [ -f "$BASE_DIR/config/docker-compose.yml" ]; then
  cp -f "$BASE_DIR/config/docker-compose.yml" "$OPT_OLG_DIR/docker-compose.yml"
fi

if [ ! -f "$OPT_OLG_DIR/docker-compose.yml" ]; then
  log_error "Docker compose specification missing at $OPT_OLG_DIR/docker-compose.yml"
  exit 1
fi

docker compose -f "$OPT_OLG_DIR/docker-compose.yml" up -d --force-recreate nats-server

KV_PUSHER="$BASE_DIR/tools/nats_kv_pusher"
[ ! -x "$KV_PUSHER" ] && [ -x "$TOOLS_DIR/nats_kv_pusher" ] && KV_PUSHER="$TOOLS_DIR/nats_kv_pusher"

if [ ! -x "$KV_PUSHER" ]; then
  log_error "NATS KV pusher binary not found or not executable (checked $BASE_DIR/tools/nats_kv_pusher and $TOOLS_DIR/nats_kv_pusher)"
  exit 1
fi

# Bounded Authenticated TLS JetStream Readiness Gate (polling every 500ms up to 20s timeout)
MAX_PROBE_WAIT_SECS=20
PROBE_START_TIME=$(date +%s)
NATS_READY=false

log_info "Probing NATS TLS connection and JetStream readiness..."
while [ $(( $(date +%s) - PROBE_START_TIME )) -lt "$MAX_PROBE_WAIT_SECS" ]; do
  if "$KV_PUSHER" \
      --server "tls://127.0.0.1:4222" \
      --creds "$JWT_DIR/orchestrator.creds" \
      --ca "$CERTS_DIR/ca.crt" \
      --probe-only >/dev/null 2>&1; then
    NATS_READY=true
    break
  fi
  sleep 0.5
done

if [ "$NATS_READY" != "true" ]; then
  log_error "NATS JetStream readiness probe failed after ${MAX_PROBE_WAIT_SECS}s; aborting deployment before VFIO handoff."
  exit 1
fi
log_info "NATS JetStream is ready [OK]."

# ------------------------------------------------------------------------------
# Phase 7: Conditional NATS JetStream State Seeding
# ------------------------------------------------------------------------------
log_info "Phase 7: Seeding initial VyOS declarative state into NATS KV..."

INITIAL_STATE_JSON="$BASE_DIR/config/vyos_initial_state.json"
if [ ! -f "$INITIAL_STATE_JSON" ]; then
  log_error "Initial state JSON configuration not found at $INITIAL_STATE_JSON"
  exit 1
fi

SEED_FLAG="--if-not-exists"
[ "$FLAG_FORCE_RESEED" = "true" ] && SEED_FLAG="--force"

if ! "$KV_PUSHER" \
    --server "tls://127.0.0.1:4222" \
    --creds "$JWT_DIR/orchestrator.creds" \
    --ca "$CERTS_DIR/ca.crt" \
    --payload "$INITIAL_STATE_JSON" \
    "$SEED_FLAG"; then
  log_error "Failed to seed baseline declarative state into NATS KV bucket 'cfg_desired'."
  exit 1
fi
log_info "VyOS declarative state seeded into NATS KV [OK]."

docker compose -f "$OPT_OLG_DIR/docker-compose.yml" up -d ucentral-client

# ------------------------------------------------------------------------------
# Phase 8: Idempotent VFIO PCI Driver Binding for WAN Controller
# ------------------------------------------------------------------------------
if [ -n "$WAN_PCI" ] && [ -d "/sys/bus/pci/devices/$WAN_PCI" ]; then
  # Preflight PCI identity and non-collision assertion
  if [ -n "$PROTECTED_NIC" ] && [ "$WAN_PCI" = "$PROTECTED_NIC" ]; then
    log_error "CRITICAL SAFETY ABORT: WAN PCI ($WAN_PCI) matches protected host management interface ($PROTECTED_NIC). Refusing to unbind host driver."
    exit 1
  fi
  if [ -n "${EXP_WAN_PATH:-}" ] || [ -n "${EXP_WAN_MAC:-}" ] || [ -n "${EXP_WAN_VENDOR:-}" ] || [ -n "${EXP_WAN_DEVICE:-}" ]; then
    if ! validate_pci_identity "$WAN_PCI" "${EXP_WAN_MAC:-}" "${EXP_WAN_PATH:-}" "${EXP_WAN_VENDOR:-}" "${EXP_WAN_DEVICE:-}" ""; then
      log_error "CRITICAL SAFETY ABORT: WAN PCI ($WAN_PCI) identity validation against hardware profile failed before driver unbind. Aborting VFIO handoff."
      exit 1
    fi
  fi

  log_info "Phase 8: Binding WAN PCI controller $WAN_PCI to vfio-pci..."
  modprobe vfio-pci 2>/dev/null || true
  CURRENT_DRIVER=$(basename "$(readlink "/sys/bus/pci/devices/$WAN_PCI/driver" 2>/dev/null)" || echo "")
  if [ "$CURRENT_DRIVER" != "vfio-pci" ]; then
    [ -n "$CURRENT_DRIVER" ] && echo "$WAN_PCI" > "/sys/bus/pci/devices/$WAN_PCI/driver/unbind" 2>/dev/null || true
    echo "vfio-pci" > "/sys/bus/pci/devices/$WAN_PCI/driver_override"
    echo "$WAN_PCI" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
  fi

  FINAL_DRIVER=$(basename "$(readlink "/sys/bus/pci/devices/$WAN_PCI/driver" 2>/dev/null)" || echo "")
  if [ "$FINAL_DRIVER" != "vfio-pci" ]; then
    log_error "Failed to bind WAN PCI controller $WAN_PCI to vfio-pci (current driver: '$FINAL_DRIVER')."
    exit 1
  fi
  log_info "WAN controller $WAN_PCI bound to vfio-pci [OK]."
fi

if [ "$LAN_TYPE" = "pci" ] && [ "${#LAN_PCI_LIST[@]}" -gt 0 ]; then
  NUM_LAN_ENTRIES="${#LAN_PCI_LIST[@]}"
  for ((idx=0; idx<NUM_LAN_ENTRIES; idx++)); do
    lan_pci="${LAN_PCI_LIST[$idx]}"
    ENTRY_JSON=$(jq -c "if .lan_ports and (.lan_ports | type == \"array\") and (.lan_ports | length > 0) then .lan_ports[$idx] else .lan end" "$HARDWARE_PROFILE" 2>/dev/null || echo "{}")
    exp_path=$(jq -r '.pci_path // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)
    exp_mac=$(jq -r '.mac // empty' <<< "$ENTRY_JSON" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    exp_vendor=$(jq -r '.vendor // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)
    exp_device=$(jq -r '.device // empty' <<< "$ENTRY_JSON" 2>/dev/null || true)

    if [ -d "/sys/bus/pci/devices/$lan_pci" ]; then
      # Preflight LAN PCI identity and non-collision assertion
      if [ -n "$PROTECTED_NIC" ] && [ "$lan_pci" = "$PROTECTED_NIC" ]; then
        log_error "CRITICAL SAFETY ABORT: LAN PCI ($lan_pci) matches protected host management interface ($PROTECTED_NIC). Refusing to unbind host driver."
        exit 1
      fi
      if [ -n "$WAN_PCI" ] && [ "$lan_pci" = "$WAN_PCI" ]; then
        log_error "CRITICAL SAFETY ABORT: LAN PCI ($lan_pci) matches WAN PCI ($WAN_PCI). Refusing to unbind host driver."
        exit 1
      fi
      if [ -n "$exp_path" ] || [ -n "$exp_mac" ] || [ -n "$exp_vendor" ] || [ -n "$exp_device" ]; then
        if ! validate_pci_identity "$lan_pci" "$exp_mac" "$exp_path" "$exp_vendor" "$exp_device" ""; then
          log_error "CRITICAL SAFETY ABORT: LAN PCI ($lan_pci) identity validation against hardware profile failed before driver unbind. Aborting VFIO handoff."
          exit 1
        fi
      fi

      log_info "Binding LAN PCI controller $lan_pci to vfio-pci..."
      modprobe vfio-pci 2>/dev/null || true
      CURRENT_DRIVER=$(basename "$(readlink "/sys/bus/pci/devices/$lan_pci/driver" 2>/dev/null)" || echo "")
      if [ "$CURRENT_DRIVER" != "vfio-pci" ]; then
        [ -n "$CURRENT_DRIVER" ] && echo "$lan_pci" > "/sys/bus/pci/devices/$lan_pci/driver/unbind" 2>/dev/null || true
        echo "vfio-pci" > "/sys/bus/pci/devices/$lan_pci/driver_override"
        echo "$lan_pci" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
      fi

      FINAL_DRIVER=$(basename "$(readlink "/sys/bus/pci/devices/$lan_pci/driver" 2>/dev/null)" || echo "")
      if [ "$FINAL_DRIVER" != "vfio-pci" ]; then
        log_error "Failed to bind LAN PCI controller $lan_pci to vfio-pci (current driver: '$FINAL_DRIVER')."
        exit 1
      fi
      log_info "LAN controller $lan_pci bound to vfio-pci [OK]."
    fi
  done
fi

# ------------------------------------------------------------------------------
# Phase 9: VyOS Dynamic Domain XML Generation & VM Startup
# ------------------------------------------------------------------------------
log_info "Phase 9: Generating domain XML and launching vyos-router VM..."

DOMAIN_XML_FILE="/tmp/vyos-router-dynamic.xml"

cat <<EOF > "$DOMAIN_XML_FILE"
<domain type='kvm'>
  <name>vyos-router</name>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='${GOLDEN_IMAGE_PATH}'/>
      <target dev='vda' bus='virtio'/>
      <transient/>
    </disk>
    <interface type='bridge'>
      <source bridge='br-mgmt'/>
      <mac address='52:54:00:f9:ab:48'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
    </video>
    <channel type='unix'>
      <source mode='bind'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <controller type='usb' model='qemu-xhci' ports='15'/>
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='/etc/olg/guest-secrets'/>
      <target dir='guest_secrets'/>
      <readonly/>
    </filesystem>
EOF

# Attach WAN PCI Hostdev if assigned
if [ -n "$WAN_PCI" ]; then
  IFS=':' read -r pci_dom pci_bus pci_slot_func <<< "$WAN_PCI"
  IFS='.' read -r pci_slot pci_func <<< "$pci_slot_func"
  cat <<EOF >> "$DOMAIN_XML_FILE"
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x${pci_dom}' bus='0x${pci_bus}' slot='0x${pci_slot}' function='0x${pci_func}'/>
      </source>
    </hostdev>
EOF
fi

# Attach LAN PCI Hostdevs (or USB) if assigned
if [ "$LAN_TYPE" = "pci" ] && [ "${#LAN_PCI_LIST[@]}" -gt 0 ]; then
  for lan_pci in "${LAN_PCI_LIST[@]}"; do
    IFS=':' read -r pci_dom pci_bus pci_slot_func <<< "$lan_pci"
    IFS='.' read -r pci_slot pci_func <<< "$pci_slot_func"
    cat <<EOF >> "$DOMAIN_XML_FILE"
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x${pci_dom}' bus='0x${pci_bus}' slot='0x${pci_slot}' function='0x${pci_func}'/>
      </source>
    </hostdev>
EOF
  done
elif [ "$LAN_TYPE" = "usb" ] && [ -n "$LAN_USB_BUS" ] && [ -n "$LAN_USB_DEV" ]; then
  cat <<EOF >> "$DOMAIN_XML_FILE"
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <address bus='${LAN_USB_BUS}' device='${LAN_USB_DEV}'/>
      </source>
    </hostdev>
EOF
elif [ "$LAN_TYPE" = "usb" ] && [ -n "$LAN_USB_VENDOR" ] && [ -n "$LAN_USB_PRODUCT" ]; then
  cat <<EOF >> "$DOMAIN_XML_FILE"
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x${LAN_USB_VENDOR}'/>
        <product id='0x${LAN_USB_PRODUCT}'/>
      </source>
    </hostdev>
EOF
fi

cat <<EOF >> "$DOMAIN_XML_FILE"
  </devices>
</domain>
EOF

# Validate domain XML schema before stopping or modifying active domain
if ! virt-xml-validate "$DOMAIN_XML_FILE" domain >/dev/null 2>&1; then
  log_error "CRITICAL SAFETY ABORT: Generated dynamic domain XML failed schema validation (virt-xml-validate). Preserving active router instance and aborting."
  exit 1
fi

VM_STATE=$(virsh domstate vyos-router 2>/dev/null || echo "shut off")

if [ "$VM_STATE" = "running" ] && [ "$FLAG_RECREATE_VM" = "true" ]; then
  log_info "Recreation requested: stopping running vyos-router instance..."
  virsh destroy vyos-router >/dev/null 2>&1 || true
  VM_STATE="shut off"
fi

if [ "$FLAG_RECREATE_VM" = "true" ] || [ "$VM_STATE" = "shut off" ]; then
  virsh undefine vyos-router --nvram >/dev/null 2>&1 || virsh undefine vyos-router >/dev/null 2>&1 || true
  if ! virsh define "$DOMAIN_XML_FILE"; then
    log_error "FATAL: Failed to define vyos-router domain from $DOMAIN_XML_FILE."
    exit 1
  fi
fi

if [ "$VM_STATE" != "running" ]; then
  log_info "Starting vyos-router domain..."
  virsh start vyos-router
  log_info "vyos-router domain started [OK]."
else
  log_info "vyos-router domain is already running [OK]."
fi

virsh autostart --disable vyos-router >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Phase 10: Post-Boot VyOS Management Gateway Verification
# ------------------------------------------------------------------------------
log_info "Phase 10: Verifying VyOS management gateway connectivity (192.168.254.1)..."
MAX_WAIT_SECS=60
START_TIME=$(date +%s)
CONNECTED=false

while [ $(( $(date +%s) - START_TIME )) -lt "$MAX_WAIT_SECS" ]; do
  if ping -c 1 -W 1 192.168.254.1 >/dev/null 2>&1; then
    CONNECTED=true
    break
  fi
  sleep 2
done

if [ "$CONNECTED" = "true" ]; then
  log_info "VyOS management gateway (192.168.254.1) is reachable [OK]."
else
  log_error "VyOS management gateway (192.168.254.1) failed to become reachable within ${MAX_WAIT_SECS}s. Aborting with failure."
  exit 1
fi

log_info "================================================================="
log_info "OLG Node Orchestrator completed successfully."
log_info "================================================================="
exit 0
