# olg-nos-server

# OpenLAN Gateway (OLG) Ubuntu Orchestrator

[![Architecture Guide](https://img.shields.io/badge/Docs-REQUIREMENTS.md-blue.svg)](./REQUIREMENTS.md)
[![Technical Spec](https://img.shields.io/badge/Docs-SPEC.md-green.svg)](./SPEC.md)
[![Status](https://img.shields.io/badge/Status-Architecture_Specification-orange.svg)](#)

> [!IMPORTANT]
> **Implementation Status**: Architecture & Specification Only.
> The scripts (`scripts/`), configuration templates (`config/`), and tools (`tools/`) documented in this repository represent **planned technical contracts** ([SPEC.md](./SPEC.md)) and are not yet implemented as executable files.

**`olg-ubuntu-orchestrator`** provides an automated deployment and management orchestration blueprint for the OpenLAN Gateway (OLG) appliance on Ubuntu host systems. It specifies hardware virtualization (KVM/QEMU), network bridge topology (Netplan/systemd-networkd), VFIO PCI passthrough for WAN interfaces, continuous health monitoring, and dynamic declarative state sync via NATS JetStream Key-Value stores for VyOS virtual routers.

---

## System Architecture Overview

```text
┌────────────────────────────────────── HOST ──────────────────────────────────────┐
│                                                                                  │
│   [ISP Modem] ──► Physical WAN NIC ──(VFIO PCI)──────────────────┐               │
│                                                                  │               │
│   ┌─── Management Network (br-mgmt / 192.168.254.0/24) ──────┐   │               │
│   │                                                          │   │               │
│   │   Host OS:      br-mgmt       (192.168.254.2, GW: .1)    │   │               │
│   │                 Published:    192.168.254.2:4222 /       │   │               │
│   │                               127.0.0.1:4222             │   │               │
│   │                                 ▲                        │   │               │
│   │   ┌─── Docker Bridge (veth) ────┼────────────────────┐   │   │               │
│   │   │     nats-server   (veth ──► :4222)               │   │   │               │
│   │   │     ucentral      (veth ──► talks to nats)       │   │   │               │
│   │   └──────────────────────────────────────────────────┘   │   │               │
│   │                                                          │   │               │
│   │   TAP Device:   vnet2 (VirtIO) ──────────────────────┐   │   │               │
│   └──────────────────────────────────────────────────────┼───┘   │               │
│                                                          │       │               │
│   [LAN Clients] ◄─ Physical LAN NIC / USB Dongle ────┐   │       │               │
│                                                      │   │       │               │
│ ┌─────────────────────────────── VYOS VM ────────────┼───┼───────┼─────────────┐ │
│ │                                                    │   │       │             │ │
│ │                                                    │   │       ▼             │ │
│ │                                                    │   │     eth1 (WAN)      │ │
│ │                                                    │   │     [DHCP Client]   │ │
│ │                                                    │   │           ▲         │ │
│ │                                                    │   │           │         │ │
│ │                                                    │   │    [SNAT Rule 100]  │ │
│ │                                                    │   │      (Masquerade)   │ │
│ │                                                    │   │           ▲         │ │
│ │                                                    │   ▼           │         │ │
│ │                                                    │  eth3 (MGMT) ─┤         │ │
│ │                                                    │  (192.168.    │         │ │
│ │                                                    │   254.1/24)   │         │ │
│ │                                                    ▼               │         │ │
│ │                                                   eth2 (LAN)       │         │ │
│ │                                                    │               │         │ │
│ │                                                    ▼               │         │ │
│ │                                                   br1 (LAN Switch) ┘         │ │
│ │                                                   (192.168.100.1/24)         │ │
│ │                                                   [DHCP Server]              │ │
│ └──────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

For complete architectural details, crash resilience semantics, and subnet mappings, see [REQUIREMENTS.md](./REQUIREMENTS.md).

---

## Repository Layout (Planned Contracts)

```text
olg-ubuntu-orchestrator/
├── README.md                     # Master Architecture & Overview (this file)
├── REQUIREMENTS.md               # Master Architecture & Hardware Requirements
├── SPEC.md                       # Technical Specifications for Scripts & Tools
├── systemd/                      # [Planned] Systemd Service Definitions
│   └── olg-orchestrator.service  # One-shot boot reconciliation unit (/etc/systemd/system/)
├── config/                       # [Planned] Configuration Templates
│   ├── netplan_bridges.yaml      # Netplan template for host management bridge (br-mgmt)
│   ├── nats.conf                 # NATS server JetStream & Operator/Account JWT resolver template
│   ├── docker-compose.yml        # Declarative Docker Compose microservices specification
│   └── vyos_initial_state.json   # Declarative initial configuration envelope for VyOS
├── scripts/                      # [Planned] Orchestration & Telemetry Scripts
│   ├── startup_node.sh           # Master one-shot node setup & dynamic VM orchestrator
│   ├── telemetry_dashboard.sh    # Real-time visual network telemetry monitor
│   └── network_simulator.sh      # Network impairment emulation tool
└── tools/                        # [Planned] Auxiliary Binaries & Utilities
    ├── dpinger                   # High-precision compiled C binary for WAN telemetry tracking
    ├── nats_pki_bootstrap        # NATS Operator/Account/User JWT & decorated credentials generator binary
    ├── nats_pki_bootstrap.go     # Go source code for NATS PKI bootstrapping utility
    ├── nats_kv_pusher            # Compiled Go binary to seed/update NATS KV configuration state over TLS
    ├── nats_kv_pusher.go         # Go source code for NATS KV pusher utility
    └── rotate_credentials.sh     # Host-side atomic credential rotation & automated rollback tool
```

For detailed specifications and contracts for each planned script, see [SPEC.md](./SPEC.md).

---

## Architecture & Hardware Prerequisites

Before deployment implementation, host systems must satisfy the following hardware and kernel requirements:

* **Host OS**: Ubuntu Server 25.04+ (x86_64) or compatible Linux distribution providing `libvirt-daemon-system >= 11.0.0`, `qemu-kvm >= 9.0.0`, and `virtiofsd >= 1.13.0` (required for read-only VirtIO-FS, shared memfd, and transient disks).
* **CPU / RAM**: x86_64 with CPU virtualization (VT-x / AMD-V) **AND** IOMMU memory virtualization (Intel VT-d / AMD-Vi) enabled in BIOS/UEFI; minimum 4 GB RAM, 20 GB SSD.
* **Kernel Boot Parameters**: `intel_iommu=on` or `amd_iommu=on` and `iommu=pt` in `/etc/default/grub`.
* **Network Interfaces**:
  * **WAN**: Dedicated PCI Ethernet controller (isolated in a dedicated 1:1 IOMMU group).
  * **LAN**: Either a secondary PCI Ethernet controller or a supported USB 3.0 Ethernet dongle (AX88179 / RTL8152/8153).

Verify virtualization and IOMMU support on your host:
```bash
# Check CPU virtualization
egrep -c '(vmx|svm)' /proc/cpuinfo

# Check active IOMMU groups (must be non-empty)
test -d /sys/kernel/iommu_groups && find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | grep -q . && echo "IOMMU Active & Populated" || echo "IOMMU Disabled or Unpopulated"
```

---

## Automated Node Deployment (Planned Execution Contract)

> [!NOTE]
> **Pre-Baked Golden OS Image Deployment Model & Immutable Artifacts**:
> For factory provisioning and production appliance imaging, the orchestrator scripts, VyOS Golden Master QCOW2 image (`/opt/olg/images/vyos-golden.qcow2` verified via SHA-256 checksum), digest-pinned container images (`nats:<version>@sha256:<digest>`, `ucentral-client:<version>@sha256:<digest>`), configuration templates (`config/`), and systemd unit file (`olg-orchestrator.service`) are pre-packaged into the pre-built Ubuntu disk image and recorded in `/opt/olg/build-manifest.json`. On first hardware boot, `olg-orchestrator.service` (`startup_node.sh`) executes automatically with zero manual intervention.

`startup_node.sh` specifies end-to-end deployment automation. Once implemented, executing the script will automatically:
1. **Offline Dependency & Immutable Artifact Preflight Validation**: Verifies locally installed system packages (`qemu-kvm`, `docker`, `netplan`, `jq`, etc.), pre-cached digest-pinned container images, and cryptographic integrity of the VyOS Golden Master QCOW2 image. If any dependency is missing or corrupted, logs the error and aborts deployment prior to VFIO handoff; runtime `apt-get` downloads and remote container pulls are strictly prohibited to ensure 100% offline cold-boot reconciliation.
2. **Hardware Discovery & Persistent Mapping**: Identifies WAN/LAN controllers, validates 1:1 dedicated IOMMU group isolation, and persists parameters to `/etc/olg/hardware.env`.
3. **Deploy Host Management Bridge**: Configures persistent `br-mgmt` bridge (`192.168.254.2/24`) with default route via `192.168.254.1`.
4. **Deploy Docker Microservices & Bounded NATS Readiness Gate**: Starts `nats-server` (publishing port `4222` to `192.168.254.2:4222` and `127.0.0.1:4222` with directory bind mount `/opt/olg/config:/etc/nats:ro`) and `ucentral-client` (with directory bind mount `/etc/olg/client:/etc/olg/client:ro`) on a user-defined Docker bridge network (`veth` pairs). Executes a bounded authenticated TLS readiness probe verifying NATS JetStream APIs before allowing state seeding or driver unbinds.
5. **Seed NATS JetStream State**: Once NATS is confirmed healthy, conditionally seeds baseline declarative envelope (`desired.vyos` in bucket `cfg_desired`) via `nats_kv_pusher`.
6. **Idempotent VFIO Driver Binding**: Detaches physical WAN NIC (and secondary PCI LAN) from host drivers and binds to `vfio-pci` using sysfs `driver_override`.
7. **Idempotent VyOS VM Startup with Ephemeral Overlays & VirtIO-FS Secrets**: Dynamically generates domain XML configured with native Libvirt `<transient/>` disk overlay (QEMU opens secretless `/opt/olg/images/vyos-golden.qcow2` read-only and routes runtime writes to native ephemeral overlays managed by Libvirt; modifying transient overlays while VM is active/non-stopped is strictly prohibited), read-only `virtiofs` secrets mount (`/etc/olg/guest-secrets` -> `guest_secrets`), and native hypervisor crash restart (`<on_crash>restart</on_crash>`), attaches VFIO PCI devices and static MACs, and boots `vyos-router` (preserving active instance if already running).
8. **Exclusive VM Startup Ownership**: Disables libvirt domain autostart (`virsh autostart --disable vyos-router`) to prevent premature boot race conditions, exiting cleanly with status code `0`.

### Planned Installer Usage

```bash
# Clone the repository
git clone git@github.com:routerarchitects/olg-ubuntu-orchestrator.git
cd olg-ubuntu-orchestrator

# [Planned] Execute deployment with explicit CLI flags once scripts/startup_node.sh is implemented
sudo ./scripts/startup_node.sh \
    --image /path/to/vyos-golden.qcow2 \
    --wan-pci 0000:03:00.0 \
    --usb-lan 0b95:1790
```

#### Accepted CLI Flags Contract (`startup_node.sh`)
* `--image <PATH>`: Path to VyOS Golden Master QCOW2 image (Default: `/opt/olg/images/vyos-golden.qcow2`).
* `--host-mgmt-nic <NAME|BDF|MAC>`: Explicit physical host management/provisioning Ethernet interface selector (e.g. `eno1`, `0000:00:1f.6`, or MAC). Adds to `HOST_PROTECTED_INTERFACES` to prevent VFIO detachment.
* `--wan-pci <BDF>`: Explicit WAN PCI device BDF (e.g. `0000:03:00.0`). Overrides auto-discovery.
* `--usb-lan <TARGET>`: Explicit USB LAN dongle selector (accepts sysfs topology path `1-1.2`, MAC, serial, or VID:PID `0b95:1790`). Overrides auto-discovery.
* `--lan-pci <BDF>`: Explicit secondary LAN PCI device BDF (e.g. `0000:04:00.0`). Overrides auto-discovery.
* `--force-reseed`: Resets desired router configuration in NATS KV store (`desired.vyos` in `cfg_desired`) to baseline envelope, overwriting active cloud configuration.
* `--recreate-vm`: Forces stopping the running VM (graceful ACPI shutdown with forceful destroy fallback), verifying `shut off` state, and restarting the `vyos-router` VM with a clean ephemeral overlay.
* `--skip-netplan`: Skips host Netplan bridge setup.

---

## System Persistence & Auto-Boot (Planned Contract)

Once implemented, the orchestrator installs a one-shot systemd boot unit:

* **`olg-orchestrator.service`**: One-shot boot service (`ExecStart=/opt/olg/scripts/startup_node.sh`) that restores host management bridge `br-mgmt`, re-binds VFIO drivers, and starts VyOS on cold boot.
* **Native Hypervisor Crash Recovery**: Managed directly by KVM/Libvirt via `<on_crash>restart</on_crash>` in the VM domain XML, ensuring the VM automatically boots back up if the guest crashes or kernel panics without external scripts.

```bash
# Verify orchestrator service status
sudo systemctl status olg-orchestrator.service

# Check orchestrator boot logs
sudo journalctl -u olg-orchestrator.service -f
```

---

## Operations & Telemetry (Planned Contract)

* **Live Telemetry Dashboard**: Run `./scripts/telemetry_dashboard.sh` to view live RTT latency, packet loss, and link health metrics.
* **Network Impairment Simulation**: Run `./scripts/network_simulator.sh` with standard `tc` presets (`good`, `fair`, `poor`, `critical`, `blackout`, `reset`) to test link telemetry.

---

---

## Architecture Acceptance & Invariant Verification Matrix

The implementation must satisfy the following verifiable contracts:

| Invariant ID | Area | Verifiable Contract & Pass Criteria |
| :--- | :--- | :--- |
| **BOOT-01** | Management Handoff | Host management network (`br-mgmt` at `192.168.254.2/24`) remains fully reachable and active across WAN VFIO unbind and VM startup. |
| **HW-01** | Hardware Isolation | Zero or multiple unassigned PCI/USB controllers without explicit CLI disambiguation immediately aborts (`exit 1`) before modifying bridges or unbinding drivers. |
| **DHCP-01** | Upstream Lease Invariant | Host OS netplan strictly disables DHCP on physical WAN/LAN; exactly ONE upstream DHCP client identity (VyOS `eth1`) is observed by the ISP. |
| **VM-01** | Stateless Cold Boot | Domain XML uses native Libvirt `<transient/>` disk handling; cold boot starts with a fresh ephemeral overlay without modifying golden master backing store. |
| **VM-02** | Live VM Protection | Modifying or deleting `.TRANSIENT-*` overlay files while domain is in any non-stopped state (`running`, `paused`, `crashed`, etc.) is strictly prohibited and immediately aborts. |
| **ROT-01** | Mid-Rotation Crash | Power loss during `PREPARED` or `FILES_INSTALLED` restores Generation $N$ files from `participants` list upon next cold boot. |
| **ROT-02** | Transaction Rollback | Failed verification probe during rotation restores Generation $N$ files, executes rollback probes, and terminates without VM reset. |
| **ROT-03** | Rollback Failure | Failed rollback verification transitions journal to `ROLLBACK_FAILED`, preserves all `*.prev` snapshot files, and emits critical alert. |
| **NATS-01** | Scoped JetStream ACL | Each decorated credential (`orchestrator`, `ucentral_client`, `vyos_agent`) enforces positive allowed subjects and negative prohibited operations. |
| **FW-01** | Management Isolation | LAN-to-management policy attached to routed bridge `br1` silently drops all traffic from `192.168.100.0/24` to `192.168.254.0/24`. |

---

## Related Documentation

* [Architecture & Requirements Guide](./REQUIREMENTS.md)
* [Technical Specifications & Script Contracts](./SPEC.md)
>>>>>>> 8330249 (docs: define OLG Ubuntu orchestrator architecture and deployment contracts)
