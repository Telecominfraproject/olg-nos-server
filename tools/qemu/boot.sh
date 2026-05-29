#!/bin/bash
# Boot eve/dist/amd64/snapshot/installer.raw in QEMU with serial captured.
#
# Just for "did it boot at all?" smoke testing. Output: a log file under
# .qemu-runs/<timestamp>/serial.log, plus a quick grep summary of known
# boot markers.
#
# Usage:
#   tools/qemu/boot.sh [--timeout 180] [--memory 4096] [--no-kvm]
#
# Exits 0 if at least one "EVE is alive" marker appears in the log
# within the timeout, 1 otherwise.

set -e

cd "$(dirname "$0")/../.."
repo_root="$PWD"

timeout_secs=180
memory_mb=4096
use_kvm=1

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) timeout_secs="$2"; shift 2 ;;
        --memory)  memory_mb="$2";    shift 2 ;;
        --no-kvm)  use_kvm=0;         shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

installer="$repo_root/eve/dist/amd64/snapshot/installer.raw"
if [ ! -f "$installer" ]; then
    echo "[boot] no installer.raw at $installer — run ./build.sh <profile> first" >&2
    exit 1
fi

# Locate UEFI firmware
ovmf=""
for cand in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/OVMF.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$cand" ] && ovmf="$cand" && break
done
if [ -z "$ovmf" ]; then
    echo "[boot] OVMF firmware not found — install 'ovmf' package" >&2
    exit 1
fi
echo "[boot] OVMF: $ovmf"

# Optional split-firmware vars file (writable copy of NVRAM template)
ovmf_vars=""
ovmf_vars_tmpl="/usr/share/OVMF/OVMF_VARS_4M.fd"
runs_dir="$repo_root/.qemu-runs"
mkdir -p "$runs_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
work="$runs_dir/$stamp"
mkdir -p "$work"
if [ -f "$ovmf_vars_tmpl" ]; then
    cp "$ovmf_vars_tmpl" "$work/OVMF_VARS.fd"
    ovmf_vars="$work/OVMF_VARS.fd"
fi

target="$work/target.qcow2"
log="$work/serial.log"
qemu-img create -f qcow2 "$target" 32G > /dev/null
echo "[boot] target disk: $target (32 GB sparse)"
echo "[boot] serial log:  $log"

accel_args=()
if [ "$use_kvm" -eq 1 ] && [ -e /dev/kvm ]; then
    accel_args=(-accel kvm -cpu host)
    echo "[boot] KVM acceleration: enabled"
else
    accel_args=(-cpu max)
    echo "[boot] KVM acceleration: disabled (slow)"
fi

firmware_args=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf")
if [ -n "$ovmf_vars" ]; then
    firmware_args+=(-drive "if=pflash,format=raw,file=$ovmf_vars")
fi

cmd=(
    qemu-system-x86_64
    -machine q35
    "${accel_args[@]}"
    -m "$memory_mb"
    -smp 4
    "${firmware_args[@]}"
    # Target disk (will be installed onto)
    -drive "file=$target,format=qcow2,if=virtio,index=0"
    # Installer (read-only source)
    -drive "file=$installer,format=raw,if=virtio,index=1,readonly=on"
    # User-mode networking, NAT'd via host
    -netdev user,id=net0
    -device virtio-net-pci,netdev=net0
    # No graphics; serial → log file (also tee'd so we can watch live)
    -display none
    -serial "file:$log"
    -no-reboot
)

echo "[boot] cmd: ${cmd[*]}"
echo "[boot] timeout: ${timeout_secs}s"

set +e
timeout "$timeout_secs" "${cmd[@]}" &
qpid=$!

# Stream serial log while QEMU runs
tail -F "$log" 2>/dev/null &
tail_pid=$!

wait "$qpid"
rc=$?
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true
set -e

echo
echo "[boot] qemu exit: $rc"
echo "[boot] log size:  $(wc -c < "$log") bytes"
echo "[boot] log path:  $log"
echo
echo "[boot] markers:"

good_markers=(
    "linuxkit: Setting linuxkit_cmdline"   # bootloader handed off cmdline
    "mount_part PART = P3"                 # installer reached persist mount
    "EVE-OS installation completed"        # install finished
    "reboot: Power down"                   # clean shutdown
)
bad_markers=(
    "Kernel panic"
    "Installation failed"
    "Guest has not initialized the display"
)

good_hits=0
bad_hits=0
for m in "${good_markers[@]}"; do
    if grep -m1 -E "$m" "$log" 2>/dev/null >/dev/null; then
        echo "  ✓ $m"
        good_hits=$((good_hits + 1))
    else
        echo "  · $m"
    fi
done
for m in "${bad_markers[@]}"; do
    if grep -m1 -E "$m" "$log" 2>/dev/null >/dev/null; then
        echo "  ✗ $m"
        bad_hits=$((bad_hits + 1))
    fi
done

if [ "$bad_hits" -gt 0 ]; then
    echo "[boot] FAIL: $bad_hits failure marker(s) hit"
    exit 1
fi
if [ "$good_hits" -eq 0 ]; then
    echo "[boot] FAIL: no success markers found"
    exit 1
fi
echo "[boot] OK ($good_hits/${#good_markers[@]} success markers, 0 failures)"
