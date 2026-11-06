# OpenLAN Gateway (OLG) Ubuntu Orchestrator: Architecture & Requirements

## 1. Problem Statement & Motivation

Commercial edge gateway deployments in carrier and OpenWiFi environments require a resilient, enterprise-grade Linux network appliance architecture. 

In the OpenLAN Gateway (OLG) architecture:
1. **Software-Defined Router VM (VyOS)**: A guest KVM virtual machine handles high-performance routing, transparent Layer 2 bridging, local DHCP serving, and SNAT masquerading.
2. **Co-located Microservices**: Microservice containers (`nats-server` and `ucentral-client`) run alongside the VyOS router VM on the host. The `ucentral-client` connects to the OpenWiFi Cloud Gateway, while `nats-server` acts as the event-driven JetStream Key-Value (KV) store for declarative configuration management.
3. **Automatic VM Crash Recovery**: If the VyOS router VM crashes or experiences a guest kernel panic, the hypervisor must restart it automatically. KVM/Libvirt provides native crash recovery (`<on_crash>restart</on_crash>`, `<on_reboot>restart</on_reboot>`) in the domain XML to ensure the VM automatically boots back up on crash, while the configuration rendering agent prevents network outages by enforcing core routing and SNAT invariants.

---

## 2. System Requirements & Dependencies

### Hardware Requirements
* **Processor**: x86_64 architecture with CPU virtualization (Intel VT-x or AMD-V) **AND** IOMMU memory virtualization (Intel VT-d or AMD-Vi) enabled in BIOS/UEFI.
* **RAM**: Minimum 4 GB RAM.
* **Storage**: Minimum 20 GB SSD/NVMe disk.
* **Physical WAN Interface**: PCI Ethernet Controller (e.g., `0000:03:00.0` with `r8169`/`e1000e`/`igb` driver) supporting VFIO passthrough and isolated in a dedicated IOMMU group.
* **Physical LAN Interface Passthrough Contracts**:
  * **Topology A (Dual PCI Ethernet Controllers)**: Both WAN (`0000:03:00.0`) and LAN (`0000:04:00.0`) PCI controllers are passed to VyOS via **libvirt VFIO PCI Passthrough** (`<hostdev type='pci'>`). Both PCI controllers undergo IOMMU group symlink verification, group isolation auditing, and BDF-specific sysfs `driver_override` binding to `vfio-pci`.
  * **Topology B (PCI WAN + USB 3.0 Ethernet Dongle)**: Physical WAN is passed via **VFIO PCI Passthrough** (`<hostdev type='pci'>`), and USB LAN dongle is passed via **libvirt USB Subsystem Hostdev Passthrough** using deterministic bus/device address topology resolution (`<hostdev mode='subsystem' type='usb'><source><address bus='$BUS' device='$DEV'/></source></hostdev>`), where `$BUS` and `$DEV` are dynamically resolved at runtime from persistent `LAN_USB_PORT_PATH` (`/sys/bus/usb/devices/$LAN_USB_PORT_PATH/busnum` and `devnum`). This guarantees exact physical device attachment even when multiple identical USB dongles exist. Host NetworkManager sets `unmanage-usb-lan.conf` (`managed=no`) to prevent host interface reset popups.

### Authoritative Hardware Profile & Interface Protection (`/etc/olg/hardware-profile.json`)
`startup_node.sh` executes a deterministic hardware validation and interface protection sequence:

1. **Immutable Model Hardware Profile (`/etc/olg/hardware-profile.json`)**:
   - On production appliances, hardware identity is derived solely from an immutable model hardware profile baked into the appliance firmware image at `/etc/olg/hardware-profile.json`, explicitly declaring `wan`, `lan`, `lan_ports`, and `host_management` interfaces.
   - **Pluggable Optical SFP/SFP+ Module Support**:
     - Interfaces terminating in SFP/SFP+ optical cages may have transceivers inserted, removed, or replaced at any time.
     - Transceiver optics MUST NOT participate in persistent port identity.
     - The orchestrator identifies NIC physical ports using stable platform information (PCI topology path / BDF / physical function), with MAC address and vendor/device IDs used as secondary verification.
     - Absence, removal, or replacement of an optical transceiver module does not invalidate hardware identity or prevent appliance boot.
   - **Host Management Protection Invariant**: Any physical Ethernet interface listed under `host_management` is strictly retained by the host OS under its native Linux kernel driver and is **PROHIBITED** from driver unbind, VFIO override, and VM passthrough.
   - **Multi-NIC Topology & Identity Revalidation Contract**:
     Relying solely on `vendor:device` IDs is strictly **PROHIBITED** because identical NIC models share identical PCI IDs and cannot distinguish renumbered BDFs. Before modifying drivers or launching the VM, `startup_node.sh` verifies:
     1. Target device exists in sysfs (`/sys/bus/pci/devices/$BDF`) with PCI class `0x0200*` (Ethernet controller).
     2. Canonical physical sysfs device path (`readlink -f /sys/bus/pci/devices/$BDF`) matches the declared `pci_path`.
     3. Target device does NOT match the protected `host_management` interface.
   - **Failure Behavior**: If a declared interface fails topology verification, `startup_node.sh` **aborts safely (`exit 1`)** prior to driver unbind.

2. **Unconditional WAN Handoff**:
   - The selected WAN controller (`WAN_PCI_BDF`) is unconditionally transferred to `vfio-pci` upon boot, relinquishing any initial host default route to VyOS. Host management bridge (`br-mgmt`), Docker stack, and NATS initial state are pre-configured before unbinding the native host driver.

### Software & Kernel Dependencies
* **Host Operating System**: Ubuntu Server 25.04+ (x86_64) or compatible Linux distribution providing libvirt >= 11.0.0 and QEMU >= 9.0.0.
* **Kernel Parameters**: GRUB configured with `intel_iommu=on` or `amd_iommu=on` and `iommu=pt` (`/etc/default/grub`). Requires populated `/sys/kernel/iommu_groups` (`find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | grep -q .`). Enforces that the number of PCI devices in the targeted `WAN_PCI_BDF` (and `LAN_PCI_BDF` when PCI) IOMMU group **MUST EQUAL 1** (`[ $(ls /sys/bus/pci/devices/$BDF/iommu_group/devices | wc -l) -eq 1 ]`). Aborts deployment prior to driver unbind if the group contains more than 1 PCI device or function (such as multi-port NIC functions `03:00.0` and `03:00.1` sharing a group).
* **Virtualization Stack**: `qemu-kvm` (>= 9.0.0), `libvirt-daemon-system` (>= 11.0.0 required for `<filesystem><driver type='virtiofs'/><readonly/></filesystem>` and shared memfd), `libvirt-clients`, `virtiofsd` (>= 1.13.0 required for `--readonly` VirtIO-FS), `virt-install`.
* **Network Management**: `netplan.io`, `systemd-networkd`, `networkctl`, `net-tools`, `iproute2`, `iptables`.
* **Container Runtime**: `docker.io`, `docker-compose` / `docker compose`.
* **Router Image**: VyOS Golden Master QCOW2 Disk Image (`/opt/olg/images/vyos-golden.qcow2`) with pre-baked management interface (`mgmt0` at `192.168.254.1/24`), serial console (`ttyS0`), and `vyos-nats-agent.service`.
* **Auxiliary Utilities**: `dnsmasq`, `jq`, `usbutils`.

---

## 3. Network Topology & Subnet Architecture

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
│ │                                                   br1 (LAN Bridge) ┘         │ │
│ │                                                   (192.168.100.1/24)         │ │
│ │                                                   [DHCP Server: br1]         │ │
│ └──────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Subnet & Interface Mapping Table

| Interface Name | Context | IP Address / Subnet | Purpose / Role |
| :--- | :--- | :--- | :--- |
| **`br-mgmt`** | Ubuntu Host | `192.168.254.2/24` (GW: `192.168.254.1`) | Host Management Linux Bridge & Host Default Route through VyOS |
| **`eth0`** | VyOS Guest | Member of `br0` | Physical PCI WAN Interface (passed via VFIO) |
| **`br0`** | VyOS Guest | Dynamic DHCP from ISP (Single Lease) | WAN Routing Bridge & Egress SNAT Outbound Interface (Rule 100) |
| **`eth2`** | VyOS Guest | Member of `br1` | Physical LAN Interface (PCI Passthrough or USB Hostdev depending on topology) |
| **`br1`** | VyOS Guest | `192.168.100.1/24` | LAN Switch Bridge & Kea DHCP Server (`listen-interface br1`) |
| **`mgmt0`** | VyOS Guest | `192.168.254.1/24` | Management NIC (VirtIO TAP `vnet2` connected to `br-mgmt`) & Management Gateway |
| **`nats-server`** | Container | Docker Bridge (`veth`), Published at `192.168.254.2:4222` & `127.0.0.1:4222` | NATS JetStream KV Store (`cfg_desired` bucket) |
| **`ucentral-client`**| Container | Docker Bridge (`veth`) | OpenWiFi Cloud Gateway WebSocket Agent (reaches NATS via Docker bridge, internet via Host GW) |

### Deterministic Hardware Passthrough & Declarative Port Mapping Contract
> [!IMPORTANT]
> **Deterministic Hardware Passthrough & Port Mapping Contract**:
> To eliminate interface enumeration races and prevent device re-ordering across reboots, hardware devices are bound deterministically at the hypervisor and declarative levels:
> 1. **Hypervisor Hardware Address Pinning (`startup_node.sh`)**:
>    - **WAN Controller**: Pinned via explicit PCI BDF `<address domain=... bus=... slot=... function=.../>` in Libvirt domain XML (`WAN_PCI_BDF`).
>    - **LAN Controller**: Pinned via explicit PCI BDF (`LAN_PCI_BDF`) or explicit USB Bus & Device address `<address bus='$BUS' device='$DEV'/>` (`LAN_USB_BUS`, `LAN_USB_DEV`) in Libvirt domain XML.
>    - **Management TAP**: Pinned via static MAC `52:54:00:f9:ab:48` connected to `br-mgmt` on the host, bound to `mgmt0` via udev rule and interface reconciliation.
> 2. **Declarative Role-Based Port Mapping (`vyos_initial_state.json`)**:
>    - The declarative state uses OpenWiFi uCentral port selectors:
>      - `"select-ports": ["WAN*"]` $\longrightarrow$ dynamically maps the physical WAN interface (`eth0`) into WAN bridge `br0`.
>      - `"select-ports": ["LAN2"]` $\longrightarrow$ dynamically maps the secondary physical LAN interface (`eth2`) into LAN switch bridge `br1`.
>
> This guarantees that regardless of hardware enumeration timing or PCI scanning order, the exact physical WAN port is attached to `br0`, the exact physical LAN port is attached to `br1`, and `mgmt0` remains the dedicated management gateway.

### Single Upstream ISP DHCP Lease Architecture
> [!NOTE]
> **Single CPE MAC / Single Lease Topology**:
> Unlike legacy dual-lease designs, only the VyOS router VM (`br0` containing `eth0`) interacts directly with the upstream ISP modem/network, acquiring the **single external DHCP lease**.
>
> The Ubuntu Host and Docker microservice containers sit securely behind VyOS on the isolated management subnet (`192.168.254.0/24`):
> 1. **Host Gateway**: Ubuntu Host sets its default gateway to `192.168.254.1` on `br-mgmt`.
> 2. **Container Egress**: Docker containers on the Docker bridge network route internet traffic through the host's default gateway (`192.168.254.1` on `br-mgmt`).
> 3. **Outbound SNAT (Rule 100)**: VyOS applies outbound SNAT masquerade on `br0` for both the LAN subnet (`192.168.100.0/24`) and the management subnet (`192.168.254.0/24`), routing all host and container internet egress through VyOS.
>
> This architecture is designed to avoid dual DHCP lease requests and improve compatibility with carrier networks that enforce single-CPE-MAC or sticky-MAC restrictions while fully insulating the host from external WAN Layer 2 access.

### Management Bridge Architecture (`br-mgmt`)
> [!IMPORTANT]
> **Host Management Bridge Model**:
> `br-mgmt` is configured persistently by Netplan (`/etc/netplan/99-olg-bridges.yaml`) with static IP `192.168.254.2/24` and default route `default via 192.168.254.1`.
>
> Docker microservices (`nats-server` and `ucentral-client`) connect via `veth` pairs to a user-defined Docker bridge network. `nats-server` publishes port `4222` onto host IP `192.168.254.2` and loopback `127.0.0.1`. Host orchestration scripts communicate directly over `127.0.0.1:4222` / `192.168.254.2:4222`, while VyOS management interface `mgmt0` (`192.168.254.1`) connects across KVM TAP `vnet2` directly to `192.168.254.2:4222`.

---

## 4. Planned Repository File Structure

To ensure modularity and maintainability, the planned repository layout is structured as follows:

```text
olg-ubuntu-orchestrator/
├── REQUIREMENTS.md               # Master Architecture & System Requirements Document
├── SPEC.md                       # Technical Specification for Scripts & Tools
├── README.md                     # Operational Quick Start Guide
├── systemd/                      # [Planned] Systemd Service Definitions
│   └── olg-orchestrator.service  # Systemd boot reconciliation service unit
├── config/                       # [Planned] Configuration Templates
│   ├── nats.conf                 # NATS server JetStream & Operator/Account JWT resolver template
│   ├── docker-compose.yml        # Declarative Docker Compose microservices specification
│   ├── vyos_initial_state.json   # Declarative VyOS initial state JSON envelope
│   └── netplan_bridges.yaml      # Netplan host bridge configuration template
├── scripts/                      # [Planned] Orchestration & Telemetry Scripts
│   ├── startup_node.sh           # Master node setup & boot restoration script
│   ├── telemetry_dashboard.sh    # Visual 3s moving average telemetry dashboard
│   └── network_simulator.sh      # Network impairment & link simulation suite
├── tools/                        # [Planned] Auxiliary Binaries & Utilities
│   ├── dpinger                   # High-precision C telemetry binary
│   ├── nats_pki_bootstrap        # NATS Operator/Account/User JWT & decorated credentials generator binary
│   ├── nats_pki_bootstrap.go     # NATS PKI bootstrapping source code
│   ├── nats_kv_pusher            # NATS KV pre-population binary
│   ├── nats_kv_pusher.go         # NATS KV pre-population source code
│   └── rotate_credentials.sh     # Host-side atomic credential rotation & rollback tool
```

---

## 5. End-to-End Component Interaction & Execution Flow

### 1. Automated System Deployment (`./scripts/startup_node.sh`)
* Performs local offline verification of pre-installed system packages, pre-cached Docker images, and hardware interfaces (PCI WAN & USB LAN). Runtime `apt-get` package downloads and remote container image pulls are strictly prohibited to ensure 100% offline cold-boot execution before VyOS brings up the WAN.
* Reads immutable hardware profile (`/etc/olg/hardware-profile.json`) and validates physical ports, verifying 1:1 dedicated IOMMU group isolation for target PCI devices.
* **Local Appliance PKI & NATS JWT/NKey Bootstrapping & Integrity Audit**: Validates the complete set of required TLS PKI artifacts (`ca.crt`, `ca.key`, `nats-server.crt`, `nats-server.key`) and NATS Operator/Account/User JWT/NKey artifacts (`operator.jwt`, `olg_account.jwt`, `orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`), verifying keypair modulus match, CA signatures, SANs, and decorated credential validity (`jwt.ParseDecoratedJWT` and `jwt.ParseDecoratedNKey`). Self-generates or cleanly regenerates the entire appliance PKI and NATS credentials from scratch if incomplete, absent, or corrupted on cold boot via `tools/nats_pki_bootstrap`, distributing `ca.crt` to `/etc/olg/client/ca.crt` and `/etc/olg/guest-secrets/ca.crt`. (Security Invariant: Golden OS Images never contain pre-baked private keys).
* Configures Host Netplan bridge (`br-mgmt` assigned to `192.168.254.2/24` with default gateway `192.168.254.1`).
* Launches Docker microservices (`nats-server` and `ucentral-client`) attached via `veth` pairs to a user-defined Docker bridge network with TLS port `4222` published to `192.168.254.2:4222` and `127.0.0.1:4222` via `docker compose up -d`.
* Executes `./tools/nats_kv_pusher --creds /opt/olg/config/jwt/orchestrator.creds --server tls://127.0.0.1:4222 --ca-file /opt/olg/config/certs/ca.crt` to conditionally seed NATS JetStream KV store (`desired.vyos` in bucket `cfg_desired`) over verified TLS, preserving existing cloud configuration payloads if already present (or forcing baseline re-seed via `--force`).
* Configures BDF-specific VFIO driver binding (`vfio-pci`) for physical PCI WAN NIC (and secondary PCI LAN if present) via sysfs `driver_override` (prohibits global `/etc/modprobe.d/vfio.conf` `ids=` matching to protect identical host NIC models, skipping re-binding if already bound).
* Dynamically generates Libvirt domain XML containing PCI passthrough, static MACs, and native hypervisor crash handling (`<on_reboot>restart</on_reboot>`, `<on_crash>restart</on_crash>`), then defines and boots the VyOS KVM VM (`vyos-router`, preserving active instance if already running).

### 2. Declarative State Synchronization
* VyOS boots up and initializes management interface `mgmt0` (`192.168.254.1/24`, MAC `52:54:00:f9:ab:48`) from its internal management configuration.
* `vyos-nats-agent.service` starts and connects across the active management interface to NATS JetStream on host (`192.168.254.2:4222`).
* Agent fetches declarative cloud configuration (`desired.vyos`) from KV store bucket `cfg_desired`.
* Agent configures WAN bridge `br0` containing physical WAN `eth0` (DHCP from ISP), LAN bridge `br1` (`192.168.100.1/24`), DHCP server, outbound SNAT masquerade rules (Rule 100 on `br0`), and `LAN_TO_MGMT` firewall policy.

### 3. OpenWiFi Cloud Management
* `ucentral-client` connects via TLS WebSocket to OpenWiFi Cloud Gateway.
* Incoming cloud configuration payloads are validated and written to NATS JetStream KV store.
* `vyos-nats-agent` receives KV change notifications and updates VyOS dynamically.

### 4. Cold-Boot Systemd Orchestration & Pre-Baked Appliance Architecture

To guarantee zero-touch boot persistence across cold host reboots and factory provisioning, system initialization is managed by a single unified service unit pre-baked directly into the OLG Golden OS Image:

#### Pre-Baked Golden OS Image Deployment Model & Immutable Artifacts
For factory provisioning and production appliance imaging, the orchestrator scripts, VyOS Golden Master QCOW2 image (`/opt/olg/images/vyos-golden.qcow2`), Docker container images, all system packages, default configuration templates (`config/`), and systemd unit file are pre-packaged into the host OS disk image and pinned via `/opt/olg/build-manifest.json`:
1. **Immutable Container Images & Golden QCOW2 Image Verification**:
   - Container images are pinned with explicit version tags and SHA-256 digests (`nats:<version>@sha256:<digest>`, `ucentral-client:<version>@sha256:<digest>`), pre-loaded directly into local Docker storage.
   - VyOS Golden Master QCOW2 image (`/opt/olg/images/vyos-golden.qcow2`) is pre-baked with management interface `mgmt0` (`192.168.254.1/24`), serial console (`ttyS0`), `qemu-guest-agent` (`systemctl enable qemu-guest-agent.service`), and `vyos-nats-agent.service`. The parent directory `/opt/olg/images/` is owned by `root:kvm` (or `root:libvirt-qemu`) with directory mode **`1775`** (`rwxrwxr-t` with sticky bit set) to allow Libvirt/QEMU to create and manage its own ephemeral transient overlay beside the backing file, while strictly preventing non-root processes from unlinking, renaming, or replacing `root`-owned files. The master image file itself and its SHA-256 checksum are strictly secured as read-only mode **`0444 root:root`**, verified via cryptographic checksum (`/opt/olg/images/vyos-golden.qcow2.sha256`) before every boot, and cannot ever be modified in place (upgrades install a new versioned file and atomically swap the active reference).
   - **Secretless Golden Image Contract**: `vyos-golden.qcow2` is 100% generic, immutable, and secretless across all appliances. It contains no pre-baked per-device passwords, tokens, or private keys.
    - The virtual machine is configured with native Libvirt `<transient/>` disk overlay: QEMU opens the golden master image strictly read-only, routes runtime ephemeral writes to a temporary overlay (`vyos-golden.qcow2.TRANSIENT-vyos-router`), and prevents guest runtime writes from modifying the golden QCOW2 backing image. Under native Libvirt `<transient/>` disk handling (`libvirt-daemon-system >= 11.0.0`), Libvirt natively unlinks any orphaned transient overlay prior to creating a fresh ephemeral instance on domain start. Manual unlinking, modification, or deletion of `.TRANSIENT-*` overlay files is strictly prohibited whenever the VM is active or in any non-stopped state (`running`, `paused`, `pmsuspended`, `blocked`, `in shutdown`, `crashed`).
2. **Host-to-Guest Per-Device Credential Delivery via Read-Only `virtiofs` & Directory Mounts**:
   - Per-device credentials and local appliance TLS certificates are generated dynamically or provisioned during host commissioning into `/opt/olg/config/jwt/` (directory mode `0700 root:root`, private NKeys `0600 root:root`, public JWTs `0644 root:root`, `orchestrator.creds` mode `0600 root:root`), `/opt/olg/config/certs/` (directory mode `0700 root:root`, private keys `0600 root:root`, public certs `0644 root:root`), `/etc/olg/client/` (directory mode `0700 root:root`, `config.json` and `ucentral.creds` mode `0600 root:root`, `ca.crt` mode `0644 root:root`), and `/etc/olg/guest-secrets/` (directory mode `0700 root:root`, `vyos_agent.creds` and `agent.env` mode `0600 root:root`, `ca.crt` mode `0644 root:root`).
   - Host directory `/opt/olg/config` is bind-mounted to `/etc/nats:ro` in `nats-server` (enabling TLS `tls://nats-server:4222`), and `/etc/olg/client` is bind-mounted to `/etc/olg/client:ro` in `ucentral-client` (providing `config.json` with `NATSConfig` referencing `ucentral.creds` and `ca.crt`). Directory-level mounting prevents Linux single-file inode pinning during `mv` operations and ensures candidate `.tmp` staging files are immediately visible inside containers for preflight validation.
   - Libvirt mounts `/etc/olg/guest-secrets` directly into the VyOS guest as a read-only `virtiofs` filesystem (`target='guest_secrets'`). `vyos-golden.qcow2` contains guest mount point `/etc/olg/secrets` and `/etc/fstab` entry `guest_secrets /etc/olg/secrets virtiofs ro,_netdev,nofail 0 0`.
   - At guest boot, `vyos-nats-agent.service` enforces `RequiresMountsFor=/etc/olg/secrets` and loads credentials via `EnvironmentFile=/etc/olg/secrets/agent.env` to authenticate against `nats-server` over TLS on `192.168.254.2:4222`.
3. **Dynamic Zero-VM-Reboot Credential Rotation Protocol (`./tools/rotate_credentials.sh`) & Persistent Transaction Journal**:
   - *Operational Execution*: Executed via host management utility `/opt/olg/tools/rotate_credentials.sh` to provide failure-atomic, crash-consistent credential rotation across host power failures.
   - *Persistent Transaction Journal (`/etc/olg/credential-generation.json`)*: Secured as mode `0600 root:root`. Tracks generation metadata, participants list, and lifecycle state:
     $$\text{COMMITTED } (N) \longrightarrow \text{PREPARED } (N+1) \longrightarrow \text{FILES\_INSTALLED } (N+1) \longrightarrow \text{VERIFIED } (N+1) \longrightarrow \text{COMMITTED } (N+1)$$
     State transitions follow a 4-step durability protocol: write to `.tmp`, `fsync` file fd, `rename` (`mv`), and `fsync` directory fd (`/etc/olg/`).
   - **Generation Manifest & Two-Tiered Rotation Coupling**:
     - **Tier 1 (Service & Account Credential Rotation)**: Rotates User credentials (`orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`, `agent.env`) and/or Application Account claims (`olg_account.jwt` + `resolver.conf` atomic bundle) under the stable Operator authority.
     - **Tier 2 (Hierarchical Operator & Account Key Migration)**: Full atomic tree bundle (`operator.jwt` -> `sys_account.jwt`, `olg_account.jwt` -> `resolver.conf` -> user `.creds`). Standalone `operator.jwt` modification without downstream re-signing is strictly prohibited.
   - **Phase 1 (Staging & Cross-Validation)**: Candidate decorated credentials and configuration files are staged with `.tmp` suffixes in host directories. Tool registers staged files in `participants` array, cross-validates decorated JWT and NKey syntax using `tools/nats_pki_bootstrap --mode verify-creds`, and validates Account JWT signatures and `resolver.conf` syntax if updated. If validation fails, all `.tmp` files are deleted and rotation is aborted with zero changes to active files or memory.
   - **Phase 2 (Active Generation Snapshot & `PREPARED` Transition)**: Tool snapshots every participating active generation file to a corresponding `.prev` rollback copy, executes `sync`, and transitions the journal to state `PREPARED` (`generation: N+1`, `previous_generation: N`, `participants: [...]`).
   - **Phase 3 (Apply Candidates & `FILES_INSTALLED` Transition)**: Tool atomically moves candidate `.tmp` files over active files, executes `sync`, and transitions journal to state `FILES_INSTALLED` (`generation: N+1`).
   - **Phase 4 (Reload & Deterministic Verification Probes)**: If `resolver.conf` or Account JWT was modified, tool captures timestamp cursor and triggers NATS live in-memory reload (`docker exec nats-server nats-server --signal reload`). Tool executes Probe 0 (`tools/nats_kv_pusher --creds /opt/olg/config/jwt/orchestrator.creds --probe-only`), Probe 1 (restarts `ucentral-client` and verifies authenticated connection), and Probe 2 & 3 (restarts VyOS agent via QGA `guest-exec`, verifying `guest-exec-status` exitcode `0`, `systemctl is-active` `active`, and telemetry heartbeat flow across all components).
   - **Phase 5 (Commit or Automatic Rollback & Verification)**:
     - *Commit Path*: If all reloads and verification probes succeed, journal is transitioned to `VERIFIED` and committed to `COMMITTED` (`generation: N+1`, `participants: []`), and all `.prev` snapshot files are deleted.
     - *Rollback Path*: If any forward probe fails or times out, the tool sets journal state to `ROLLBACK_IN_PROGRESS` (`generation: N+1`, `previous_generation: N`), restores active files for entries in `participants` from `.prev`, reloads/restarts services, and executes deterministic rollback verification probes (Probe 0 orchestrator, Probe 1 client auth recovery, Probe 2 QGA status, Probe 3 telemetry heartbeat).
       - *Successful Rollback*: If all rollback probes succeed, journal transitions to `COMMITTED` (`generation: N`, `participants: []`), deletes `.prev` snapshots, and exits with `exit 1` (rotation failure).
       - *Failed Rollback*: If any rollback probe fails or times out, journal transitions to `ROLLBACK_FAILED` (`generation: N+1`, `previous_generation: N`, `participants: [...]`), **all `*.prev` snapshot files are strictly preserved** for forensic inspection, and a critical alert (`CRITICAL_ALERT_CONTROL_PLANE_DEGRADED_ROLLBACK_FAILED`) is emitted while strictly enforcing the **Dataplane Preservation Guarantee** (zero host reboot, zero VM reset, zero dataplane routing interruption).
   - Prior to launching network bridges, Docker containers, or the VM, `startup_node.sh` audits `/etc/olg/credential-generation.json`.
   - If missing, it initializes the journal to `{"generation": 1, "previous_generation": 0, "state": "COMMITTED", "participants": []}`.
   - If `state != "COMMITTED"` (power loss occurred mid-rotation during `PREPARED`, `FILES_INSTALLED`, `VERIFIED`, or `ROLLBACK_IN_PROGRESS`), it automatically restores only the `.prev` snapshot files corresponding to `participants` in the journal, purges orphaned `.tmp` and `.prev` files, flushes disk buffers (`sync`), reconciles journal state to the base generation (`{"generation": previous_generation, "previous_generation": $((previous_generation - 1)), "state": "COMMITTED", "participants": []}`), and logs `CREDENTIAL_TRANSACTION_RECOVERY_TRIGGERED`.
   - If `state == "ROLLBACK_FAILED"` or if the journal is corrupt, unreadable, or in an unrecognized state, `startup_node.sh` strictly **fails closed (`exit 1`)**, preserves all existing `*.prev` snapshots and creates a timestamped corrupt journal backup (`${JOURNAL_FILE}.corrupt.$(date +%s)`), refusing to overwrite the journal with a baseline `COMMITTED` state to prevent concealing partial installations.
   - If `state == "COMMITTED"`, it verifies secret permissions (`0600 root:root`) and purges any stale/orphaned `*.prev` or `*.tmp` files left behind by uncompleted post-commit unlinks.
5. **Pre-Installed Files & Binaries**: `/opt/olg/scripts/startup_node.sh`, `/opt/olg/tools/nats_pki_bootstrap`, `/opt/olg/tools/nats_kv_pusher`, `/opt/olg/tools/rotate_credentials.sh`, `/opt/olg/tools/dpinger`, and config templates are pre-placed in `/opt/olg/`.
6. **Pre-Enabled Systemd Service**: `olg-orchestrator.service` is installed into `/etc/systemd/system/` and pre-enabled (`systemctl enable olg-orchestrator.service`) during OS image building.
7. **Deterministic Zero-Touch Orchestration**: Upon powering on the OLG hardware appliance for the first time, systemd automatically executes `olg-orchestrator.service` (`startup_node.sh`), triggering hardware profile validation, credential transaction recovery, Netplan bridge setup, Docker container orchestration, NATS state seeding, VFIO driver binding, and router boot entirely offline from immutable local artifacts with zero manual intervention and zero Internet dependencies required.

#### `olg-orchestrator.service` (System Boot Reconciliation Service)
- **Unit File**: `/etc/systemd/system/olg-orchestrator.service` (`Type=oneshot`, `RemainAfterExit=yes`).
- **Ordering & Dependencies**: `After=network.target libvirtd.service docker.service`, `Requires=libvirtd.service docker.service`, `Wants=network.target`.
- **ExecStart**: `/opt/olg/scripts/startup_node.sh`.
- **Responsibility**: Reads `/etc/olg/hardware-profile.json`, restores Netplan bridge (`br-mgmt` at `192.168.254.2/24` with default route `192.168.254.1`), enforces per-BDF sysfs `vfio-pci` `driver_override`, generates dynamic domain XML with `<transient/>`, `virtiofs` secrets mount, and `<on_crash>restart</on_crash>`, starts Docker containers, boots the VM, and exits cleanly (`exit 0`).

#### Native Hypervisor Crash Recovery & Invariant Rendering
1. **Misconfiguration Prevention & Invariant Validation Contract**:
   - **Immutable Invariants**: Core management connectivity (`mgmt0` at `192.168.254.1/24`), WAN bridge routing (`br0`), outbound SNAT masquerade rules (Rule 100 on `br0`), and `LAN_TO_MGMT` inter-zone firewall policy (`192.168.100.0/24` -> `192.168.254.0/24` drop) are enforced as immutable invariants at the config rendering agent level.
   - **Validation & Conflicting State Rejection**: The configuration rendering agent validates incoming desired states (`desired.vyos`) prior to commit. If a cloud desired configuration attempts to modify, overwrite, or remove any immutable invariant, the rendering agent **rejects the conflicting configuration**, **preserves the active configuration**, and publishes a validation error to NATS status/result subjects.
   - **Non-Persistence of Cloud Configuration**: The renderer MUST commit cloud-managed configuration to the running configuration but MUST NOT save cloud-managed configuration to `/config/config.boot`, preserving cold-boot statelessness.
2. **Native KVM/Libvirt Crash Recovery**: If the VyOS guest kernel panics or crashes, Libvirt automatically intercepts the event and restarts the VM via `<on_crash>restart</on_crash>` and `<on_reboot>restart</on_reboot>` configured in the domain XML to boot the VM back up.
3. **Passive Telemetry Monitoring**: ICMP metrics collected via `dpinger` and viewed through `telemetry_dashboard.sh` serve strictly as link quality and latency telemetry. Upstream packet loss or WAN disconnects represent ISP impairments and never trigger VM restarts or driver rebinds.

---

## 6. Summary of Architectural Requirements & Design Objectives

1. **State Preservation & Invariant Rendering Requirement**: The deployment and recovery lifecycle MUST preserve committed configurations in NATS JetStream. The configuration rendering agent MUST validate incoming state against immutable invariants (`192.168.254.1/24` on `mgmt0`, `br0` WAN routing, SNAT Rule 100 on `br0`, and `LAN_TO_MGMT` firewall policy), rejecting conflicting payloads and preserving active configuration on violation. Cloud configurations MUST be committed to running memory only and MUST NOT be saved to `/config/config.boot`.
2. **Native Hypervisor Crash Recovery Requirement**: The virtualized router domain MUST configure native Libvirt crash recovery (`<on_crash>restart</on_crash>` and `<on_reboot>restart</on_reboot>`) directly within its dynamically generated domain XML, ensuring the VM automatically boots back up upon guest crash or kernel panic without requiring external supervisor scripts.
3. **Telemetry-Driven Health Monitoring Requirement**: Passive link latency and packet loss telemetry MUST be decoupled from router lifecycle management, preventing false-positive VM restarts during upstream ISP outages.
4. **Control Plane Security & Isolation Requirement**: `nats-server` MUST be published exclusively on management IP `192.168.254.2:4222` and localhost `127.0.0.1:4222` (WAN and LAN listeners strictly prohibited) with mandatory cryptographic NATS 2.0+ Operator/Account JWT authentication and subject authorization (mounted via directory bind mounts `/opt/olg/config:/etc/nats:ro` and `/etc/olg/client:/etc/olg/client:ro`) enforcing least-privilege publish/subscribe subject allow lists between orchestrator bootstrap, cloud-facing uCentral gateway, and VyOS agent components, backed by persistent host volume storage (`/opt/olg/data/nats:/data/jetstream`). Host secrets directories MUST be secured with permissions `0700` and secret files with `0600` owned by `root:root`. VyOS MUST enforce ingress firewall rules blocking traffic from the LAN subnet (`192.168.100.0/24`) to the Management subnet (`192.168.254.0/24`).
5. **Per-Device Secretless Golden Image & Directory Live-Mounted Provisioning Requirement**: VyOS golden master image (`vyos-golden.qcow2`) MUST remain 100% generic, immutable, and secretless. Per-device credentials MUST be delivered from host persistent storage via directory live mounts (Docker directory bind mounts for containers and read-only `virtiofs` for VyOS), enabling real-time credential rotation with dynamic inode resolution, zero container recreation, zero VM reboot, and zero routing interruption.
