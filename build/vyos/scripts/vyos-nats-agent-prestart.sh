#!/usr/bin/env bash
set -e

mkdir -p /etc/olg/secrets /etc/olg/device-certs /opt/olg/state /run/vyatta/config /run/vyos

modprobe virtiofs 2>/dev/null || true
modprobe virtio_pci 2>/dev/null || true


# Mount guest_secrets virtiofs if not already mounted
if ! grep -q "/etc/olg/secrets" /proc/mounts 2>/dev/null; then
  mount -t virtiofs guest_secrets /etc/olg/secrets 2>/dev/null || true
fi

# Mount device_certs virtiofs if not already mounted
if ! grep -q "/etc/olg/device-certs" /proc/mounts 2>/dev/null; then
  mount -t virtiofs device_certs /etc/olg/device-certs 2>/dev/null || true
fi
[ ! -e /etc/rtty ] && ln -sf /etc/olg/device-certs /etc/rtty 2>/dev/null || true

# Ensure /etc/hosts maps vyos-router hostname to prevent sudo System error
if ! grep -q "vyos-router" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 vyos-router" >> /etc/hosts 2>/dev/null || true
fi

# Initialize nftables raw table/chains to prevent VyOS Python control library exceptions
nft add table ip raw 2>/dev/null || true
nft add chain ip raw VYOS_TCP_MSS '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null || true
nft add chain ip raw vyos_rpfilter '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null || true
nft add table ip6 raw 2>/dev/null || true
nft add chain ip6 raw VYOS_TCP_MSS '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null || true
nft add chain ip6 raw vyos_rpfilter '{ type filter hook prerouting priority -300; policy accept; }' 2>/dev/null || true

# Configured management interface MAC assigned by hypervisor (connected to br-mgmt)
MGMT_MAC="52:54:00:f9:ab:48"

# Deterministic interface reconciliation
reconcile_interfaces() {
  local -A MAC_TO_TARGET=()
  local -A TARGET_TO_MAC=()
  local -A DEV_TARGET=()
  local -A ASSIGNED_TARGETS=()
  local -a PHYSICAL_DEVS=()
  local -a UNMATCHED_DEVS=()
  local allow_fallback="false"

  # 0. Strip stale hw-id bindings and normalize physical interface MACs
  # In case a previous boot or stale VyOS hw-id config overrode them
  for cfg in /config/config.boot /opt/vyatta/etc/config/config.boot; do
    if [ -f "$cfg" ] && grep -q "hw-id" "$cfg" 2>/dev/null; then
      sed -i '/^[[:space:]]*hw-id[[:space:]]/d' "$cfg" 2>/dev/null || true
    fi
  done

  for dev in /sys/class/net/*; do
    [ -d "$dev/device" ] || continue
    local iface
    iface=$(basename "$dev")
    case "$iface" in
      lo|mgmt*|pim*|ip_vti*|sit*|dummy*|br*|_olg_*) continue ;;
    esac

    local driver
    driver=$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null || echo "")")
    [ "$driver" = "virtio_net" ] && continue

    local perm_mac curr_mac
    perm_mac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    curr_mac=$(cat "$dev/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if [ -n "$perm_mac" ] && [ "$perm_mac" != "00:00:00:00:00:00" ] && [ "$curr_mac" != "$perm_mac" ]; then
      echo "[INFO] Normalizing $iface software MAC ($curr_mac) to permanent hardware MAC ($perm_mac)..."
      ip link set "$iface" down 2>/dev/null || true
      ip link set "$iface" address "$perm_mac" 2>/dev/null || true
      ip link set "$iface" up 2>/dev/null || true
    fi
  done

  # 1. Management Interface (strictly matched by expected MAC address) pinned to mgmt0
  local mgmt_dev=""
  for dev in /sys/class/net/*; do
    [ -d "$dev" ] || continue
    local iface
    iface=$(basename "$dev")
    case "$iface" in
      lo|pim*|ip_vti*|sit*|dummy*|br*|_olg_*) continue ;;
    esac

    local dev_mac
    dev_mac=$(cat "$dev/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if [ "$dev_mac" = "$MGMT_MAC" ]; then
      mgmt_dev="$iface"
      break
    fi
  done

  if [ -n "$mgmt_dev" ]; then
    if [ "$mgmt_dev" != "mgmt0" ]; then
      if [ -d "/sys/class/net/mgmt0" ]; then
        local old_mgmt_mac
        old_mgmt_mac=$(cat "/sys/class/net/mgmt0/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ "$old_mgmt_mac" != "$MGMT_MAC" ]; then
          ip link set mgmt0 down 2>/dev/null || true
          ip link set mgmt0 name "_olg_evict_mgmt" 2>/dev/null || true
        fi
      fi
      ip link set "$mgmt_dev" down 2>/dev/null || true
      if ! ip link set "$mgmt_dev" name mgmt0; then
        echo "[ERROR] Failed to rename management interface $mgmt_dev (MAC $MGMT_MAC) to mgmt0" >&2
        return 1
      fi
    fi
    if ! ip addr show dev mgmt0 2>/dev/null | grep -q "192.168.254.1/24"; then
      ip addr add 192.168.254.1/24 dev mgmt0 2>/dev/null || true
    fi
    ip link set mgmt0 up 2>/dev/null || true
  fi

  if [ -d "/sys/class/net/mgmt0" ]; then
    local actual_mgmt_mac
    actual_mgmt_mac=$(cat "/sys/class/net/mgmt0/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ "$actual_mgmt_mac" != "$MGMT_MAC" ]; then
      echo "[ERROR] Interface mgmt0 has incorrect MAC '$actual_mgmt_mac' (expected: '$MGMT_MAC')" >&2
      return 1
    fi
    if ! ip addr show dev mgmt0 2>/dev/null | grep -q "192.168.254.1/24"; then
      ip addr add 192.168.254.1/24 dev mgmt0 2>/dev/null || true
    fi
    ip link set mgmt0 up 2>/dev/null || true
  else
    echo "[ERROR] Expected management interface with MAC $MGMT_MAC not found" >&2
    return 1
  fi

  # 2. Parse /etc/olg/secrets/interface_map.json if present
  local map_file="/etc/olg/secrets/interface_map.json"
  if [ -f "$map_file" ]; then
    allow_fallback=$(python3 -c "
import json
try:
    with open('$map_file') as f:
        data = json.load(f)
    val = data.get('allow_inferred_fallback', False)
    print('true' if val is True else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

    local lan_counter=1
    while read -r map_mac map_role map_vport; do
      [ -z "$map_mac" ] && continue
      local target=""
      if [ "$map_role" = "wan" ] || [ "$map_vport" = "wan" ]; then
        target="eth0"
      elif [[ "$map_vport" =~ ^lan([0-9]+)$ ]]; then
        target="eth${BASH_REMATCH[1]}"
      elif [ "$map_role" = "lan" ]; then
        target="eth${lan_counter}"
        lan_counter=$((lan_counter + 1))
      fi

      if [ -n "$target" ]; then
        # Reject conflicting / duplicate target assignments in map
        if [ -n "${TARGET_TO_MAC[$target]:-}" ] && [ "${TARGET_TO_MAC[$target]}" != "$map_mac" ]; then
          echo "[ERROR] Conflicting interface map: target '$target' claimed by both '${TARGET_TO_MAC[$target]}' and '$map_mac'" >&2
          return 1
        fi
        MAC_TO_TARGET["$map_mac"]="$target"
        TARGET_TO_MAC["$target"]="$map_mac"
      fi
    done < <(python3 -c "
import json
try:
    with open('$map_file') as f:
        data = json.load(f)
    for m in data.get('mappings', []):
        mac = m.get('mac_address', '').strip().lower()
        role = m.get('role', '').strip().lower()
        vport = m.get('vyos_port', '').strip().lower()
        if mac:
            print(f'{mac} {role} {vport}')
except Exception:
    pass
" 2>/dev/null || jq -r '.mappings[]? | "\(.mac_address // empty | ascii_downcase) \(.role // empty) \(.vyos_port // empty)"' "$map_file" 2>/dev/null || true)
  fi

  # 3. Collect non-management physical / passthrough interfaces
  for dev in /sys/class/net/*; do
    [ -d "$dev/device" ] || continue
    local iface
    iface=$(basename "$dev")
    case "$iface" in
      lo|mgmt*|pim*|ip_vti*|sit*|dummy*|br*|_olg_*) continue ;;
    esac

    local mac driver devpath
    mac=$(cat "$dev/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    driver=$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null || echo "")")
    devpath=$(readlink -f "$dev/device" 2>/dev/null || echo "")

    # Skip management interface in physical device pool
    if [ "$mac" = "$MGMT_MAC" ] || [ "$iface" = "mgmt0" ]; then
      continue
    fi

    if [ -n "${MAC_TO_TARGET[$mac]:-}" ]; then
      local target="${MAC_TO_TARGET[$mac]}"
      if [ -n "${ASSIGNED_TARGETS[$target]:-}" ]; then
        echo "[ERROR] Target conflict: '$target' already assigned to another interface" >&2
        return 1
      fi
      DEV_TARGET["$iface"]="$target"
      ASSIGNED_TARGETS["$target"]=1
    else
      UNMATCHED_DEVS+=("$iface")
    fi
  done

  # 4. Fallback assignment for any devices without explicit MAC mapping
  if [ "${#UNMATCHED_DEVS[@]}" -gt 0 ]; then
    if [ "$allow_fallback" != "true" ]; then
      echo "[ERROR] Unmatched physical interfaces detected (${UNMATCHED_DEVS[*]}) and allow_inferred_fallback is disabled or mapping is missing." >&2
      return 1
    fi

    # If exactly 1 PCI and 1 USB unmatched, PCI=WAN (eth0), USB=LAN (eth1)
    local pci_devs=()
    local usb_devs=()
    for udev in "${UNMATCHED_DEVS[@]}"; do
      local sub
      sub=$(basename "$(readlink -f "/sys/class/net/$udev/device/subsystem" 2>/dev/null || echo "")")
      local dpath
      dpath=$(readlink -f "/sys/class/net/$udev/device" 2>/dev/null || echo "")
      if [ "$sub" = "usb" ] || echo "$dpath" | grep -q "/usb"; then
        usb_devs+=("$udev")
      else
        pci_devs+=("$udev")
      fi
    done

    if [ "${#pci_devs[@]}" -eq 1 ] && [ "${#usb_devs[@]}" -eq 1 ] && [ -z "${ASSIGNED_TARGETS["eth0"]:-}" ] && [ -z "${ASSIGNED_TARGETS["eth1"]:-}" ]; then
      DEV_TARGET["${pci_devs[0]}"]="eth0"
      ASSIGNED_TARGETS["eth0"]=1
      DEV_TARGET["${usb_devs[0]}"]="eth1"
      ASSIGNED_TARGETS["eth1"]=1
    else
      # Assign lowest available eth indices sorted by sysfs path
      local cur_idx=0
      for udev in $(for d in "${UNMATCHED_DEVS[@]}"; do readlink -f "/sys/class/net/$d/device" 2>/dev/null | sed "s|^|$d |"; done | sort -k2 | awk '{print $1}'); do
        while [ -n "${ASSIGNED_TARGETS["eth${cur_idx}"]:-}" ]; do
          cur_idx=$((cur_idx + 1))
        done
        DEV_TARGET["$udev"]="eth${cur_idx}"
        ASSIGNED_TARGETS["eth${cur_idx}"]=1
        cur_idx=$((cur_idx + 1))
      done
    fi
  fi

  # 5. Two-Phase Collision-Free Rename
  # Phase 1: Rename mismatching interfaces to unique temporary names
  local temp_idx=0
  local -A TEMP_TO_TARGET=()
  for ifname in "${!DEV_TARGET[@]}"; do
    local target="${DEV_TARGET[$ifname]}"
    if [ "$ifname" != "$target" ]; then
      local tmp_name="_olg_tmp_${temp_idx}"
      temp_idx=$((temp_idx + 1))
      ip link set "$ifname" down 2>/dev/null || true
      if ! ip link set "$ifname" name "$tmp_name"; then
        echo "[ERROR] Failed to rename interface $ifname to temporary name $tmp_name" >&2
        return 1
      fi
      TEMP_TO_TARGET["$tmp_name"]="$target"
    fi
  done

  # Phase 2: Rename temporary interfaces to target names
  for tmp_name in "${!TEMP_TO_TARGET[@]}"; do
    local target="${TEMP_TO_TARGET[$tmp_name]}"
    if [ -d "/sys/class/net/$target" ]; then
      ip link set "$target" down 2>/dev/null || true
      ip link set "$target" name "_olg_evict_${target}" 2>/dev/null || true
    fi
    if ! ip link set "$tmp_name" name "$target"; then
      echo "[ERROR] Failed to rename $tmp_name to target name $target" >&2
      return 1
    fi
    ip link set "$target" up 2>/dev/null || true
  done

  # Ensure all targeted interfaces are up
  for target in "${DEV_TARGET[@]}"; do
    if [ -d "/sys/class/net/$target" ]; then
      ip link set "$target" up 2>/dev/null || true
    else
      echo "[ERROR] Target interface $target was not created successfully" >&2
      return 1
    fi
  done

  # 6. Post-reconciliation verification: Assert actual MAC matches expected MAC
  for target in "${!TARGET_TO_MAC[@]}"; do
    local exp_mac="${TARGET_TO_MAC[$target]}"
    [ -z "$exp_mac" ] && continue
    if [ ! -d "/sys/class/net/$target" ]; then
      echo "[ERROR] Post-reconciliation verification failed: $target does not exist" >&2
      return 1
    fi
    local act_mac
    act_mac=$(cat "/sys/class/net/$target/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ "$act_mac" != "$exp_mac" ]; then
      local perm_mac
      perm_mac=$(ethtool -P "$target" 2>/dev/null | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
      if [ "$perm_mac" = "$exp_mac" ]; then
        echo "[INFO] Restoring permanent hardware MAC on $target: $act_mac -> $perm_mac"
        ip link set "$target" down 2>/dev/null || true
        ip link set "$target" address "$perm_mac" 2>/dev/null || true
        ip link set "$target" up 2>/dev/null || true
        act_mac="$perm_mac"
      fi
    fi
    if [ "$act_mac" != "$exp_mac" ]; then
      echo "[ERROR] Post-reconciliation MAC mismatch for $target: actual ($act_mac) != expected ($exp_mac)" >&2
      return 1
    fi
  done

  # Pre-initialize bridge interfaces br0 (WAN) and br1 (LAN)
  ip link add br0 type bridge 2>/dev/null || true
  ip link add br1 type bridge 2>/dev/null || true

  # Align all bridge MAC addresses to their member physical interfaces
  for br_dir in /sys/class/net/*/brif; do
    [ -d "$br_dir" ] || continue
    local br_name
    br_name=$(basename "$(dirname "$br_dir")")
    local primary_member
    primary_member=$(ls -1 "$br_dir" 2>/dev/null | sort | head -n 1 || echo "")
    if [ -n "$primary_member" ] && [ -f "/sys/class/net/$primary_member/address" ]; then
      local member_mac
      member_mac=$(cat "/sys/class/net/$primary_member/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
      local current_br_mac
      current_br_mac=$(cat "/sys/class/net/$br_name/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
      if [ -n "$member_mac" ] && [ "$member_mac" != "00:00:00:00:00:00" ] && [ "$current_br_mac" != "$member_mac" ]; then
        ip link set dev "$br_name" address "$member_mac" 2>/dev/null || true
      fi
    fi
  done

  # Proactively align brN MAC to ethN expected MAC even before member enslavement
  for target in "${!TARGET_TO_MAC[@]}"; do
    if [[ "$target" =~ ^eth([0-9]+)$ ]]; then
      local br_idx="${BASH_REMATCH[1]}"
      local br_target="br${br_idx}"
      if [ -d "/sys/class/net/$br_target" ]; then
        local exp_br_mac="${TARGET_TO_MAC[$target]}"
        local act_br_mac
        act_br_mac=$(cat "/sys/class/net/$br_target/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ "$act_br_mac" != "$exp_br_mac" ]; then
          ip link set dev "$br_target" address "$exp_br_mac" 2>/dev/null || true
        fi
      fi
    fi
  done
  return 0
}

# Wait up to 60 seconds (1 minute) until VyOS boot configuration has completed,
# commit lock is released, all interfaces are reconciled, and host NATS is reachable
for i in $(seq 1 60); do
  if reconcile_interfaces; then
    check_mgmt_mac=""
    [ -f "/sys/class/net/mgmt0/address" ] && check_mgmt_mac=$(cat "/sys/class/net/mgmt0/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if [ -f /run/vyos/boot_ready ] && \
       ! pgrep -f "/opt/vyatta/sbin/my_commit" >/dev/null 2>&1 && \
       ! pgrep -f "/usr/libexec/vyos/init/vyos-router" >/dev/null 2>&1 && \
       [ -d "/sys/class/net/mgmt0" ] && \
       [ "$check_mgmt_mac" = "$MGMT_MAC" ] && \
       ip addr show dev mgmt0 2>/dev/null | grep -q "192.168.254.1/24" && \
       ping -c 1 -W 1 192.168.254.2 >/dev/null 2>&1; then
      echo "[INFO] Interface reconciliation and VyOS system readiness verified successfully."
      exit 0
    fi
  fi
  sleep 1
done

echo "[ERROR] FATAL: Timeout (60s) waiting for VyOS interface reconciliation and host readiness." >&2
[ ! -f /run/vyos/boot_ready ] && echo "[ERROR] Reason: /run/vyos/boot_ready not present (VyOS boot configuration did not complete)." >&2
pgrep -f "/opt/vyatta/sbin/my_commit" >/dev/null 2>&1 && echo "[ERROR] Reason: VyOS commit lock held (/opt/vyatta/sbin/my_commit running)." >&2
pgrep -f "vyos-router" >/dev/null 2>&1 && echo "[ERROR] Reason: vyos-router initialization process still active." >&2
if [ ! -d "/sys/class/net/mgmt0" ]; then
  echo "[ERROR] Reason: mgmt0 interface missing." >&2
else
  actual_mac=$(cat "/sys/class/net/mgmt0/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ "$actual_mac" != "$MGMT_MAC" ] && echo "[ERROR] Reason: mgmt0 MAC '$actual_mac' does not match expected '$MGMT_MAC'." >&2
  ! ip addr show dev mgmt0 2>/dev/null | grep -q "192.168.254.1/24" && echo "[ERROR] Reason: mgmt0 missing IP 192.168.254.1/24." >&2
fi
! ping -c 1 -W 1 192.168.254.2 >/dev/null 2>&1 && echo "[ERROR] Reason: Cannot reach host management bridge at 192.168.254.2." >&2
exit 1
