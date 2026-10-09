# olg-nos-server

# OpenLAN Gateway (OLG) Ubuntu Orchestrator

[![Architecture Guide](https://img.shields.io/badge/Docs-REQUIREMENTS.md-blue.svg)](./REQUIREMENTS.md)
[![Technical Spec](https://img.shields.io/badge/Docs-SPEC.md-green.svg)](./SPEC.md)
[![Status](https://img.shields.io/badge/Status-Operational-brightgreen.svg)](#)

> [!NOTE]
> **Implementation Status**: Implemented & Operational.
> The orchestration script (`scripts/startup_node.sh`), configuration templates (`config/`), compiled helper tools (`tools/`), and systemd unit (`systemd/olg-orchestrator.service`) are fully implemented and verified.

**`olg-ubuntu-orchestrator`** provides an automated zero-touch deployment and boot reconciliation system for the OpenLAN Gateway (OLG) appliance on Ubuntu host systems. It orchestrates hardware virtualization (KVM/QEMU/Libvirt), isolated management network bridges (Netplan/systemd-networkd), VFIO PCI passthrough for WAN interfaces, appliance PKI self-bootstrapping, and dynamic declarative state sync via NATS JetStream Key-Value stores for VyOS virtual routers.

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
│ │                                                    │   │     eth0 (Member)   │ │
│ │                                                    │   │       │             │ │
│ │                                                    │   │       ▼             │ │
│ │                                                    │   │     br0 (WAN Bridge)│ │
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
│ │                                                    │               │         │ │
│ │                                                    ▼               │         │ │
│ │                                                   eth2 (Member)    │         │ │
│ │                                                    │               │         │ │
│ │                                                    ▼               │         │ │
│ │                                                   br1 (LAN Switch) ┘         │ │
│ │                                                   (192.168.100.1/24)         │ │
│ │                                                   [DHCP Server: br1]         │ │
│ └──────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

For complete architectural details, crash resilience semantics, and subnet mappings, see [REQUIREMENTS.md](./REQUIREMENTS.md).

---

## Repository Layout

```text
olg-ubuntu-orchestrator/
├── README.md                     # Master Architecture & Overview (this file)
├── REQUIREMENTS.md               # Master Architecture & Hardware Requirements
├── SPEC.md                       # Technical Specifications for Scripts & Tools
├── systemd/                      # Systemd Service Definitions
│   └── olg-orchestrator.service  # One-shot boot reconciliation unit (/etc/systemd/system/)
├── config/                       # Configuration Templates
│   ├── netplan_bridges.yaml      # Netplan template for host management bridge (br-mgmt)
│   ├── nats.conf                 # NATS server JetStream & Operator/Account JWT resolver template
│   ├── resolver.conf             # NATS Memory Account Resolver template
│   ├── docker-compose.yml        # Declarative Docker Compose microservices specification
│   └── vyos_initial_state.json   # Declarative initial configuration envelope for VyOS
├── scripts/                      # Orchestration & Telemetry Scripts
│   ├── startup_node.sh           # Master one-shot node setup & dynamic VM orchestrator
│   ├── telemetry_dashboard.sh    # Real-time visual network telemetry monitor (planned)
│   └── network_simulator.sh      # Network impairment emulation tool (planned)
└── tools/                        # Auxiliary Binaries & Utilities
    ├── go.mod                    # Go module definition for tools
    ├── nats_pki_bootstrap.go     # Go source code for NATS PKI bootstrapping utility
    ├── nats_pki_bootstrap        # Compiled binary for Operator/Account/User JWT & .creds generation
    ├── nats_kv_pusher.go         # Go source code for NATS KV pusher & TLS readiness probe
    └── nats_kv_pusher            # Compiled binary to seed NATS KV configuration over TLS
```

---

## Immutable Hardware Profile & Interface Resolution

Each OpenLAN Gateway appliance model ships with an immutable model hardware profile baked into `/etc/olg/hardware-profile.json`. `startup_node.sh` validates and allocates interfaces according to the declared profile:

1. **Hardware Profile (`/etc/olg/hardware-profile.json`)**:
   * Declares `host_management` (preserved on Ubuntu host OS under native kernel driver).
   * Declares `wan` (allocated to `vfio-pci` for VyOS WAN passthrough).
   * Declares `lan` (USB dongle topology path e.g. `2-1` or PCI/SFP controller list).
2. **Pluggable SFP/SFP+ Optical Modules**:
   * Optical transceivers do not participate in port identity. Interfaces are identified by stable platform PCIe topology paths and BDFs. Transceiver insertion, removal, or replacement does not affect appliance boot.
3. **Mandatory Profile Enforcement**:
   * If `/etc/olg/hardware-profile.json` is missing or declared devices fail `sysfs` topology validation, `startup_node.sh` halts immediately (`exit 1`) to prevent unsafe driver unbinding or misallocation.

---

## Automated Node Deployment & Execution

`startup_node.sh` automates the end-to-end cold boot sequence:
1. **Preflight Audit**: Verifies host tools (`virsh`, `docker`, `jq`, `openssl`), pre-cached container images, and cryptographic SHA-256 integrity of `/opt/olg/images/vyos-golden.qcow2`.
2. **Hardware Profile Resolution**: Reads `/etc/olg/hardware-profile.json`, validates physical paths in sysfs, verifies 1:1 dedicated IOMMU isolation, and binds WAN/LAN NICs to `vfio-pci` using sysfs `driver_override`.
3. **Appliance PKI Self-Bootstrapping**: Generates local Root CA, NATS server TLS certificates (with SANs), NATS Operator/Account JWTs, and role-scoped decorated `.creds` files (`orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`).
4. **Host Management Bridge**: Brings up `br-mgmt` on `192.168.254.2/24`.
5. **Docker Stack & Readiness Gate**: Boots `nats-server` and `ucentral-client` on `olg-bridge` and executes a bounded TLS probe before proceeding.
6. **JetStream State Seeding**: Seeds `config/vyos_initial_state.json` into NATS KV bucket `cfg_desired` (key `desired.vyos`).
7. **VyOS VM Launch**: Dynamically generates Libvirt domain XML with native `<transient/>` disk handling, VirtIO-FS secrets mount (`guest_secrets`), and starts `vyos-router`.

### Usage

```bash
# Run node orchestrator & boot reconciliation
sudo ./scripts/startup_node.sh

# Force recreation of the VM with a fresh transient overlay
sudo ./scripts/startup_node.sh --recreate-vm

# Force reset desired configuration in NATS JetStream KV store
sudo ./scripts/startup_node.sh --force-reseed
```

#### CLI Flags
* `--image <PATH>`: Path to VyOS Golden Master QCOW2 image (Default: `/opt/olg/images/vyos-golden.qcow2`).
* `--force-reseed`: Overwrites desired router configuration in NATS KV store with baseline initial state.
* `--recreate-vm`: Stops any running instance and restarts `vyos-router` with a fresh transient overlay.
* `--skip-netplan`: Skips applying Netplan bridge configuration.

---

## Related Documentation

* [Architecture & Requirements Guide](./REQUIREMENTS.md)
* [Technical Specifications & Script Contracts](./SPEC.md)
>>>>>>> 8330249 (docs: define OLG Ubuntu orchestrator architecture and deployment contracts)
