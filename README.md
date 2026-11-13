# olg-nos-server

# OpenLAN Gateway (OLG) Ubuntu Orchestrator

[![Architecture Guide](https://img.shields.io/badge/Docs-REQUIREMENTS.md-blue.svg)](./REQUIREMENTS.md)
[![Technical Spec](https://img.shields.io/badge/Docs-SPEC.md-green.svg)](./SPEC.md)
[![Build Manifest Spec](https://img.shields.io/badge/Docs-BUILD__MANIFEST__SPEC.md-orange.svg)](./BUILD_MANIFEST_SPEC.md)
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
│ │                                                    │  mgmt0 (MGMT)─┤         │ │
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
├── build.yaml                    # Master declarative build manifest (local git-ignored)
├── build.yaml.example            # Master build manifest template
├── build.sh                      # Unified Master Appliance & ISO Builder engine
├── build/                        # Image Building Pipeline
│   ├── cache/                    # Downloaded base artifacts (Ubuntu ISO, VyOS QCOW2, debs)
│   ├── output/                   # Build artifacts (vyos-golden.qcow2, appliance ISO, sha256)
│   └── iso/                      # Enterprise ISO scaffolding
│       ├── autoinstall/          # Cloud-init unattended installation configuration
│       ├── grub/                 # Headless serial console GRUB configuration
│       └── scripts/              # Post-install late-command scripts (finish_install.sh)
├── systemd/                      # Systemd Service Definitions
│   └── olg-orchestrator.service  # One-shot boot reconciliation unit (/etc/systemd/system/)
├── config/                       # Configuration Templates
│   ├── netplan_bridges.yaml      # Netplan template for host management bridge (br-mgmt)
│   ├── nats.conf                 # NATS server JetStream & Operator/Account JWT resolver template
│   ├── resolver.conf             # NATS Memory Account Resolver template
│   ├── docker-compose.yml        # Declarative Docker Compose microservices specification
│   ├── hardware-profile.json     # Authoritative hardware topology map template
│   ├── ucentral_client_template.json # Baseline uCentral cloud gateway configuration
│   └── vyos_initial_state.json   # Declarative initial configuration envelope for VyOS
├── scripts/                      # Orchestration & Telemetry Scripts
│   ├── startup_node.sh           # Master one-shot node setup & dynamic VM orchestrator
│   ├── telemetry_dashboard.sh    # Real-time visual network telemetry monitor (planned)
│   └── network_simulator.sh      # Network impairment emulation tool (planned)
└── tools/                        # Auxiliary Binaries & Utilities
    ├── go.mod                    # Go module definition for tools
    ├── pki_init.go               # Go source code for NATS PKI bootstrapping utility
    ├── pki_init                  # Compiled binary for Operator/Account/User JWT & .creds generation
    ├── kv_config_init.go         # Go source code for NATS KV pusher & TLS readiness probe
    └── kv_config_init            # Compiled binary to seed NATS KV configuration over TLS
```

---

## Enterprise Appliance Image Building (Single Command SDK)

The repository provides a fully automated, manifest-driven build pipeline that compiles all microservices, injects the VyOS agent into the router master disk, and packages a 100% air-gapped, unattended installer ISO.

### 1. Configure the Build Manifest (`build.yaml`)
Copy `build.yaml.example` to `build.yaml` and adjust binaries, patches, containers, and parameters as needed:

```yaml
global:
  ubuntu_release: "25.10"
  cloud_gateway_url: "wss://openwifi3.routerarchitects.com:15002"
  cloud_server_name: "openwifi3.routerarchitects.com"

vyos:
  binaries:
    - name: "vyos-nats-agent"
      type: "go"
      repo: "https://github.com/RouterArchitects/TIP-olg-server-vyos-client-natsagent.git"
      ref: "dd40dbe5283a9c4727799710727ee082f898e87b"
      target_path: "/usr/local/bin/vyos-nats-agent"
      systemd_service:
        name: "vyos-nats-agent.service"
        enable: true
    - name: "rtty"
      type: "cmake"
      repo: "https://github.com/zhaojh329/rtty.git"
      ref: "master"
      target_path: "/usr/sbin/rtty"
      patches:
        - repo: "https://github.com/RouterArchitects/ra_wlan-ap.git"
          path: "feeds/openwifi-mesh/rtty/patches"
          apply_all: true
      install_symlink:
        target: "/etc/olg/device-certs"
        link_name: "/etc/rtty"

host:
  containers:
    - name: "ucentral-client"
      image: "ucentral-client:latest"
      repo: "https://github.com/RouterArchitects/TIP-olg-ucentral-client.git"
      ref: "RA-dev-main"
      archive_output: "ucentral-client.tar"
```

### 2. Run the Master Builder
Execute the top-level builder script:
```bash
./build.sh
```
Options:
* `./build.sh --vyos-only` : Builds only `vyos-golden.qcow2`.
* `./build.sh --iso-only` : Packages only the bootable Ubuntu ISO (requires `vyos-golden.qcow2`).
* `./build.sh --config <PATH>` : Path to custom `build.yaml` manifest (Default: `./build.yaml`).

The script will:
* Check and auto-install any missing host tools (`xorriso`, `7z`, `curl`, `sha256sum`, `docker`, `go`, `qemu-utils`).
* Download base artifacts if not already in `build/cache/`.
* Resolve all binaries, fetch external patch repos, apply patches, and compile inside container sandboxes.
* Inject binaries, patches, shared libs, VirtIO-FS channels, and systemd units into `vyos-golden.qcow2`.
* Build and package Docker images into `/opt/olg/docker-cache/`.
* Assemble the hybrid bootable ISO with pre-cached offline deb packages, unattended cloud-init, and headless serial GRUB at:
  ```text
  build/output/olg-enterprise-appliance-25.10.iso
  ```

### 3. Flash to USB Drive
Identify your USB drive with `lsblk` (e.g. `/dev/sda`), then unmount and write:
```bash
sudo umount /dev/sda* 2>/dev/null || true
sudo dd if=build/output/olg-enterprise-appliance-25.10.iso of=/dev/sda bs=4M status=progress conv=fsync
sync
```

Boot the target appliance from the USB drive. The installer runs unattended, formats the internal drive, sets up IOMMU, installs packages, and shuts down/reboots when complete.

---

## First-Boot Appliance Provisioning (Cloud Connectivity)

Once the appliance boots from the internal SSD, complete the following steps to establish connection with OpenWiFi / MangoCloud (`openwifi3.routerarchitects.com:15002`):

### 1. Verify USB LAN Hardware Path (`/etc/olg/hardware-profile.json`)
Check the sysfs path of your connected USB network adapter:
```bash
ls -d /sys/bus/usb/devices/*/net/* /sys/bus/usb/devices/*/*/net/* 2>/dev/null
```
Ensure `/etc/olg/hardware-profile.json` has the matching `usb_path` (e.g. `"2-1"` or `"1-4"`).

### 2. Set Device Serial & Capabilities
* Ensure `/etc/ucentral/interface_map.json` contains the serial number registered in your MangoCloud controller:
  ```json
  { "serial": "<REGISTERED_DEVICE_SERIAL>" }
  ```
* Place your appliance capabilities JSON into:
  ```bash
  sudo cp capabilities.json /etc/ucentral/capabilities.json
  sudo chmod 0644 /etc/ucentral/capabilities.json
  ```

### 3. Install mTLS Cloud Certificates
Place your 3 cloud certificates in `/etc/olg/device-certs/` (accessible to both uCentral and VyOS RTTY):
```bash
# Copy certificates into place
sudo mkdir -p /etc/olg/device-certs
sudo cp ca.pem cert.pem key.pem /etc/olg/device-certs/

# Enforce secure permissions
sudo chmod 0755 /etc/olg/device-certs
sudo chmod 0644 /etc/olg/device-certs/*.pem
```

### 4. Restart Client & Verify Live Connection
```bash
sudo docker restart ucentral-client
sudo docker logs -f ucentral-client
```
Expected output:
```text
[NATS STATE] Changed to: connected
ws: dialing wss://openwifi3.routerarchitects.com:15002
ws: connected, performing handshake...
ws: connect handshake frame sent
[WS STATE] Changed to: connected
ws: session sess-1 active, connected and verified
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
