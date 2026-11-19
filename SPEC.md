# OpenLAN Gateway (OLG) Setup: Technical Specifications & Contracts

## 1. Overview & Coding Standards

This document defines the technical specifications, structural design, input/output contracts, and internal execution logic for all scripts, tools, and configuration files in the `olg-ubuntu-orchestrator` repository.

### Global Scripting Standards
1. **Strict Shell Options**: Every bash script starts with `set -euo pipefail` to ensure immediate termination on unhandled errors, unbound variables, or failed pipe commands.
2. **Idempotency**: All setup and orchestration scripts must be fully idempotent. Re-running a script must safely clean up previous states before applying changes, without duplicating network bridges, `iptables` rules, or process instances.
3. **Privilege Enforcement**: Scripts modifying system network configurations enforce root privileges via `[ "$EUID" -eq 0 ]`.
4. **Structured Logging**: All operational events are logged to stdout with ISO-8601 timestamps and forwarded to system logging via `logger -t`.

---

## 2. Configuration Files Specification (`config/`)

### 2.1 `config/netplan_bridges.yaml` (Netplan Host Bridge Template)
* **Purpose**: Defines system-level NetworkManager / `systemd-networkd` bridge configuration for persistent host management bridge.
* **Specification**:
  * `br-mgmt`: Configured as a persistent Linux bridge assigned static IP `192.168.254.2/24` with default gateway `192.168.254.1` (pointing to VyOS management gateway `mgmt0`).
  * **Netplan Template**:
    ```yaml
    network:
      version: 2
      renderer: networkd
      bridges:
        br-mgmt:
          addresses:
            - 192.168.254.2/24
          routes:
            - to: default
              via: 192.168.254.1
    ```

### 2.2 `config/vyos_initial_state.json` (Declarative Cloud Desired State Envelope)
* **Purpose**: Contains the declarative cloud-facing network configuration state envelope pushed into NATS JetStream KV store (`cfg_desired` bucket, key `desired.vyos`). Management connectivity (`mgmt0` at `192.168.254.1/24`) is strictly pre-baked into the local VyOS appliance image and is omitted from this envelope to prevent bootstrap deadlocks.
* **Specification**:
  * **Declarative OpenWiFi Role-Based Port Mapping**: Uses OpenWiFi uCentral port selectors to bind physical interfaces dynamically to their logical roles:
    - `WAN*`: Matches the passed-through physical WAN interface (`eth0`) and enslaves it into WAN routing bridge `br0`.
    - `LAN2`: Matches the passed-through secondary physical LAN interface (`eth2`, PCI or USB) and enslaves it into LAN switch bridge `br1`.
  * Defines VyOS WAN bridge `br0` (member `eth0`) configured with `addressing: dynamic` to obtain the single Upstream DHCP Lease from the ISP for egress SNAT masquerade.
  * Defines VyOS LAN bridge `br1` (member `eth2`, supporting Physical PCI LAN or USB LAN Dongle, IP `192.168.100.1/24`, DHCP range `192.168.100.10` to `192.168.100.200`).
  * Defines SNAT outbound masquerade rule 100 on `br0` for subnets `192.168.100.0/24` and `192.168.254.0/24`.
  * Defines mandatory `LAN_TO_MGMT` firewall policy:
    - **Source**: `192.168.100.0/24` (LAN subnet).
    - **Destination**: `192.168.254.0/24` (Management subnet).
    - **Action**: `drop` (silent drop; `reject` is strictly prohibited to prevent information leakage).
    - **Attachment**: Applied directly to the routed VyOS bridge interface `br1` (`interfaces bridge br1 firewall in name LAN_TO_MGMT`).

### 2.3 `config/nats.conf` & `config/resolver.conf` (NATS Server JetStream & JWT Security Templates)
* **Purpose**: Configuration templates for the standalone `nats-server` container running on the user-defined Docker bridge network (`veth` pairs) and published on the isolated management network (`br-mgmt`).
* **Specification**:
  * **Listener**: Inside the container, listens on `port: 4222`. Published onto the host strictly on `192.168.254.2:4222` and `127.0.0.1:4222`. WAN and LAN listeners are strictly prohibited.
  * **JetStream Engine**: Configured with `store_dir: "/data/jetstream"` backed by persistent host volume `/opt/olg/data/nats:/data/jetstream`, providing persistent Key-Value store storage for bucket `cfg_desired`.
  * **Operator & Embedded Memory Account Resolver (`/opt/olg/config/resolver.conf`)**: `nats.conf` includes `include ./resolver.conf` (mode `0600 root:root`). `resolver.conf` specifies `operator: "/etc/nats/jwt/operator.jwt"`, `system_account: "<SYS_ACCOUNT_PUBKEY>"`, and `resolver: MEMORY` with `resolver_preload` mapping Account Public Keys directly to their base64-encoded Account JWT string literals (`"<ACCOUNT_PUBKEY>": "<ENCODED_ACCOUNT_JWT>"`).
  * **NATS Cryptographic User Identity & Decorated Credentials (`.creds`) Contract**: Enforces discrete user identities with signed JWT capability claims and NKey seeds, distributed as standard decorated `.creds` files (`jwt.FormatUserConfig` containing both User JWT and User NKey Seed) required by `TIP-olg-ucentral-client`:
    * `orchestrator`: Stored at `/opt/olg/config/jwt/orchestrator.creds` (`0600 root:root`); administrative JetStream access for host bootstrap, KV bucket creation (`cfg_desired`), and initial baseline seeding.
    * `ucentral_client`: Stored at `/etc/olg/client/ucentral.creds` (`0600 root:root`); cloud-facing gateway client; write permissions to publish desired configurations to KV bucket `cfg_desired` and configuration commands, and subscribe permissions for applied status and health telemetry. Prohibited from stream administration or orchestrator-level operations.
    * `vyos_agent`: Stored at `/etc/olg/guest-secrets/vyos_agent.creds` (`0600 root:root`, exported via `virtiofs` to `/etc/olg/secrets/vyos_agent.creds`); router configuration agent; read/watch permissions for desired configurations from KV bucket `cfg_desired`, and publish permissions for applied status and health telemetry. Prohibited from modifying cloud desired configuration state.

### 2.4 `config/docker-compose.yml` (Appliance Microservices Compose Contract)
* **Purpose**: Declarative Docker Compose definition copied to `/opt/olg/docker-compose.yml` during Golden Image build and managed by `startup_node.sh` via `docker compose up -d`.
* **Specification**:
  * **Networking**: Defines a user-defined isolated Docker bridge network (`name: olg-bridge`) using standard Linux `veth` pairs.
  * **Services**:
    1. **`nats-server`**:
       - **Image**: Digest-pinned immutable reference (e.g. `nats:2.10.29@sha256:<digest>`).
       - **Ports**: Published strictly on management IP `192.168.254.2:4222:4222` and localhost `127.0.0.1:4222:4222`.
       - **Volumes**:
         - `/opt/olg/data/nats:/data/jetstream` (Persistent JetStream store)
         - `/opt/olg/config:/etc/nats:ro` (Live directory bind mount containing `nats.conf`, `certs/`, and `jwt/`; directory-level mount guarantees atomic inode resolution on `mv` and exposes candidate `.tmp` staging files to the container)
       - **Command**: `nats-server -c /etc/nats/nats.conf -sd /data/jetstream`.
       - **Restart Policy**: `restart: unless-stopped`.
    2. **`ucentral-client`**:
       - **Image**: Digest-pinned immutable reference (e.g. `ucentral-client:1.0.0@sha256:<digest>`).
       - **Network**: Attached to `olg-bridge`. Connects to NATS via internal container name `nats-server:4222`.
       - **Volumes**:
         - `/etc/olg/client:/etc/olg/client:ro` (Live directory bind mount containing `config.json`, `ucentral.creds`, and `ca.crt`; directory-level mount guarantees atomic inode resolution on `mv` without container recreation)
       - **Restart Policy**: `restart: unless-stopped`.

---

## 3. Systemd Service Unit Specification (`systemd/`)

### 3.1 `systemd/olg-orchestrator.service` (Systemd Node Boot Reconciliation Service)
* **Purpose**: One-shot systemd service copied to `/etc/systemd/system/olg-orchestrator.service` on the OS image that executes cold-boot hardware binding, network bridge restoration, and exclusive VyOS VM startup. Pre-enabled during appliance OS image building.
* **Specification**:
  * `[Unit]`: `After=network.target libvirtd.service docker.service`, `Requires=libvirtd.service docker.service`, `Wants=network.target`
  * `[Service]`: `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=/opt/olg/scripts/startup_node.sh`
  * `[Install]`: `WantedBy=multi-user.target`

---

## 4. Core Automation Scripts Specification (`scripts/`)

### 4.1 `scripts/startup_node.sh` (Master Zero-Touch Setup & Boot Restoration Script)
* **Purpose**: Provides end-to-end zero-touch automated deployment and boot restoration in an entirely offline, self-contained execution model. Validates pre-installed host packages and pre-cached Docker images, deploys host Netplan bridges, binds VFIO PCI drivers, launches local Docker container microservices, seeds NATS JetStream KV state, and creates/boots the VyOS VM (systemd service units, binary tools, and container images are pre-installed during Golden OS image building to ensure zero internet dependencies prior to VyOS WAN routing).
* **Input Arguments & CLI Options Contract (`startup_node.sh [OPTIONS]`)**:
  * `--image <PATH>` (Optional): Path to VyOS Golden Master QCOW2 image (Default: `/opt/olg/images/vyos-golden.qcow2`).
  * `--force-reseed` (Optional flag): Resets desired router configuration in NATS KV store to baseline envelope (`desired.vyos` in `cfg_desired`), overwriting any cloud-applied router configuration.
  * `--recreate-vm` (Optional flag): Forces stopping the VM, verifying shutdown, resetting the ephemeral transient overlay disk, and restarting the `vyos-router` VM (safely deferred until all preflight, hardware profile, credential journal, and domain XML validations succeed).
  * `--skip-netplan` (Optional flag): Skips applying Netplan bridge configuration.
  * `--help`, `-h` (Optional flag): Displays CLI usage summary and available options.
* **Execution Logic & Step Sequence**:
  1. **Offline Dependency & Immutable Artifact Verification**:
     * Performs a local preflight audit verifying that all mandatory system packages (`qemu-kvm` >= 9.0.0, `libvirt-daemon-system` >= 11.0.0 for read-only VirtIO-FS and shared memfd, `libvirt-clients`, `virtiofsd` >= 1.13.0 for `--readonly` VirtIO-FS, `virt-install`, `netplan.io`, `docker.io`, `docker-compose-v2`, `jq`, `usbutils`, `dnsmasq`) and pre-cached digest-pinned Docker container images (`nats:<version>@sha256:<digest>`, `ucentral-client:<version>@sha256:<digest>`) exist locally in Docker storage as recorded in `/opt/olg/build-manifest.json`.
     * **VyOS Golden Master Disk Immutability & Transient Storage Contract**:
       - **Directory Ownership & Sticky Bit Semantics**: The parent directory `/opt/olg/images/` is owned by `root:kvm` (or `root:libvirt-qemu`) with directory mode **`1775`** (`rwxrwxr-t` with sticky bit set). Sticky bit semantics ensure that while members of group `kvm` (`libvirt-qemu`) can create and unlink their *own* ephemeral overlay files (`*.TRANSIENT-*`), only `root` can unlink, rename, or replace files owned by `root`.
       - **Host Filesystem-Level Master Immutability Invariant**: Trusted artifacts `/opt/olg/images/vyos-golden.qcow2` and `/opt/olg/images/vyos-golden.qcow2.sha256` are owned by `root:root` with strict read-only mode **`0444`** (`r--r--r--`). The runtime QEMU/libvirt identity can manage its own transient overlays but is strictly **prohibited** from unlinking, renaming, replacing, or modifying the golden QCOW2 master or its trusted SHA-256 checksum. Golden master images are **never modified in place**.
       - **Security Labeling & DAC Isolation**: Libvirt AppArmor / SELinux DAC isolation permits read-only access to the `0444` backing store while granting create/write/unlink access strictly for the `.TRANSIENT-vyos-router` ephemeral overlay in `/opt/olg/images/`.
       - **Mandatory Preflight SHA-256 Verification**: Verifies the cryptographic integrity of `/opt/olg/images/vyos-golden.qcow2` against `/opt/olg/images/vyos-golden.qcow2.sha256` (`sha256sum -c /opt/olg/images/vyos-golden.qcow2.sha256`) before *every* VM creation or driver unbind.
       - **Atomic Versioned Upgrade Contract**: Upgrades MUST install a new versioned disk image (e.g. `/opt/olg/images/vyos-v1.4.0.qcow2` mode `0444`) and atomically switch the active reference only after cryptographic checksum verification succeeds.
     * **Strict Offline Invariant**: Runtime `apt-get install`, `apt-get update`, and remote `docker pull` commands are **strictly prohibited** during cold-boot orchestration.
     * **Failure Behavior**: If any required package, tool binary, container image digest, file permission check, or Golden QCOW2 disk checksum fails verification, the script logs the specific failure and **aborts immediately (`exit 1`)** before modifying network bridges or unbinding drivers for VFIO handoff. Golden OS images must remain complete, immutable, and cryptographically valid prior to appliance deployment.
  2. **Authoritative Hardware Profile & Interface Protection (`/etc/olg/hardware-profile.json`)**:
     * **IOMMU Kernel Preflight Verification**:
       - Verifies `/sys/kernel/iommu_groups` exists AND contains active subdirectories (`[ -d /sys/kernel/iommu_groups ] && find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | grep -q .`). Aborts deployment safely if IOMMU is disabled in BIOS/UEFI or GRUB (`intel_iommu=on` / `amd_iommu=on iommu=pt`).
       - Verifies `dmesg` for active `DMAR` / `AMD-Vi` hardware virtualization enablement.
     * **Authoritative Immutable Model Hardware Profile Contract**:
       - Each appliance model ships with its own complete, immutable firmware image. All WAN, LAN, and host management interface identities are derived from an immutable model hardware profile baked into `/etc/olg/hardware-profile.json`.
       - The orchestrator reads `/etc/olg/hardware-profile.json` on boot, resolves and validates physical ports against sysfs, and executes VFIO binding and VM passthrough without modifying or saving runtime state.
       - **Pluggable Optical SFP/SFP+ Module Contract**:
         - Interfaces terminating in SFP/SFP+ optical cages may have transceivers inserted, removed, or replaced at any time.
         - Transceiver optics MUST NOT participate in persistent port identity.
         - The orchestrator identifies NIC physical ports using stable platform information (PCI topology path / BDF / physical function), with MAC address and vendor/device IDs used as secondary verification.
         - Absence, removal, or replacement of an optical transceiver module does not invalidate hardware identity or prevent appliance boot.
       - **Format of `/etc/olg/hardware-profile.json`**:
         ```json
         {
           "host_management": {
             "pci_path": "/sys/devices/pci0000:00/0000:00:1f.6",
             "pci_bdf": "0000:00:1f.6",
             "mac": "52:54:00:de:f0:12"
           },
           "wan": {
             "pci_path": "/sys/devices/pci0000:00/0000:00:1c.4/0000:01:00.0",
             "pci_bdf": "0000:01:00.0",
             "mac": "52:54:00:12:34:56"
           },
           "lan": {
             "type": "pci",
             "pci_path": "/sys/devices/pci0000:00/0000:00:1c.5/0000:02:00.0",
             "pci_bdf": "0000:02:00.0",
             "mac": "52:54:00:78:9a:bc"
           },
           "lan_ports": [
             {
               "pci_path": "/sys/devices/pci0000:00/0000:00:1c.5/0000:02:00.0",
               "pci_bdf": "0000:02:00.0",
               "mac": "52:54:00:78:9a:bc"
             }
           ]
         }
         ```
       - **Host Management Interface Protection Invariant**: Any physical Ethernet interface listed under `host_management` is strictly retained by the Ubuntu host OS under its native Linux kernel driver. It is **PROHIBITED** from driver unbinding, VFIO override, and VM passthrough.
       - **Multi-NIC Topology & Identity Revalidation Contract**:
         Before modifying drivers or launching the VM, `startup_node.sh` validates:
         1. Target PCI device exists in sysfs (`/sys/bus/pci/devices/$BDF`) with PCI class `0x0200*` (Ethernet controller).
         2. Canonical physical sysfs device path (`readlink -f /sys/bus/pci/devices/$BDF`) matches the declared `pci_path`.
         3. Target device does NOT match the protected `host_management` interface.
       - **Failure Behavior**: If a declared interface fails topology verification, `startup_node.sh` **aborts immediately (`exit 1`)** prior to unbinding any driver.
       - **Unconditional WAN Handoff Contract**: The selected WAN controller (`WAN_PCI_BDF`) is unconditionally transferred from the host Linux kernel to `vfio-pci` for VyOS ownership on boot. Any initial host default route on this NIC is relinquished to VyOS.
       - **Safe WAN Handoff Protocol**: Pre-configures host management bridge (`br-mgmt`), Docker stack, and NATS state BEFORE unbinding native host driver. It unbinds `<BDF>`, binds to `vfio-pci`, launches the VyOS VM, and exits cleanly (`exit 0`).
     * **Strict Dedicated IOMMU Group Isolation Audit**: Prior to detaching any native host driver, verifies that `/sys/bus/pci/devices/$PCI_BDF/iommu_group` exists as a valid symlink for `WAN_PCI_BDF` (and `LAN_PCI_BDF` when `LAN_TYPE=pci`). Enforces that the number of PCI devices in the target IOMMU group MUST equal 1 (`[ $(ls /sys/bus/pci/devices/$PCI_BDF/iommu_group/devices | wc -l) -eq 1 ]`). If the group contains more than 1 PCI device or function (e.g. multi-port NIC sharing a group like `03:00.0` and `03:00.1`), deployment **ABORTS IMMEDIATELY** prior to driver unbind with error: `IOMMU Group Isolation Failure: $PCI_BDF IOMMU group contains N devices (must equal 1)`. Whole-group multi-device passthrough is not supported; strict 1:1 dedicated IOMMU group isolation is required.
  3. **Credential Transaction Journal Recovery & State Verification (`/etc/olg/credential-generation.json`)**:
     * **Crash-Consistency Audit**: To prevent booting from a split-brain or partially installed credential generation following an unclean host shutdown or sudden power loss, `startup_node.sh` audits the persistent transaction journal `/etc/olg/credential-generation.json`:
       - If `/etc/olg/credential-generation.json` is absent (initial cold boot): Initializes the journal atomically with `{"generation": 1, "previous_generation": 0, "state": "COMMITTED", "participants": [], "updated_at": "<ISO8601>"}`.
       - If present: Reads `generation`, `previous_generation`, `state`, and `participants` array.
     * **Cold-Boot Interrupted Transaction Recovery (`state != "COMMITTED"`)**:
       - **Interrupted Mid-Rotation Recovery (`state` is `PREPARED`, `FILES_INSTALLED`, `VERIFIED`, or `ROLLBACK_IN_PROGRESS`)**: (Indicating power loss occurred mid-rotation before Phase 5 finalization):
       1. **Participant-Selective Snapshot Restoration**: Iterates strictly over the `participants` array recorded in the journal and restores only those `.prev` snapshot files over active paths:
          ```bash
          # Restore only artifacts that explicitly participated in the interrupted transaction
          for participant in $(jq -r '.participants[]' /etc/olg/credential-generation.json 2>/dev/null); do
            case "$participant" in
              "operator.jwt")       [ -f /opt/olg/config/jwt/operator.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/operator.jwt.prev /opt/olg/config/jwt/operator.jwt ;;
              "sys_account.jwt")    [ -f /opt/olg/config/jwt/sys_account.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/sys_account.jwt.prev /opt/olg/config/jwt/sys_account.jwt ;;
              "olg_account.jwt")    [ -f /opt/olg/config/jwt/olg_account.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/olg_account.jwt.prev /opt/olg/config/jwt/olg_account.jwt ;;
              "resolver.conf")      [ -f /opt/olg/config/resolver.conf.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/resolver.conf.prev /opt/olg/config/resolver.conf ;;
              "orchestrator.creds") [ -f /opt/olg/config/jwt/orchestrator.creds.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/orchestrator.creds.prev /opt/olg/config/jwt/orchestrator.creds ;;
              "ucentral.creds")     [ -f /etc/olg/client/ucentral.creds.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/client/ucentral.creds.prev /etc/olg/client/ucentral.creds ;;
              "vyos_agent.creds")   [ -f /etc/olg/guest-secrets/vyos_agent.creds.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/guest-secrets/vyos_agent.creds.prev /etc/olg/guest-secrets/vyos_agent.creds ;;
              "agent.env")          [ -f /etc/olg/guest-secrets/agent.env.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/guest-secrets/agent.env.prev /etc/olg/guest-secrets/agent.env ;;
            esac
          done
          ```
       2. **Staging Cleanup**: Purges any leftover `.tmp` candidate files and orphaned `.prev` files across `/opt/olg/config/`, `/opt/olg/config/jwt/`, `/etc/olg/client/`, and `/etc/olg/guest-secrets/`.
       3. **Disk Sync**: Flushes filesystem buffers (`sync`).
       4. **Journal State Reconciliation**: Reconciles the journal back to the known-good base generation identified by `previous_generation`:
          ```bash
          PREV_GEN=$(jq -r '.previous_generation' /etc/olg/credential-generation.json)
          jq -n --arg gen "$PREV_GEN" --arg prev "$((PREV_GEN - 1))" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{generation: ($gen|tonumber), previous_generation: ($prev|tonumber), state: "COMMITTED", participants: [], updated_at: $ts}' \
            > /etc/olg/credential-generation.json.tmp
          sync
          mv /etc/olg/credential-generation.json.tmp /etc/olg/credential-generation.json
          sync
          ```
       5. **Audit Logging**: Emits system log entry `CREDENTIAL_TRANSACTION_RECOVERY_TRIGGERED: Restored known-good credential generation $PREV_GEN following power interruption in state '$state'`.
       - **Forensic Preservation & Hard Abort State (`state == "ROLLBACK_FAILED"` or Corrupt/Unrecognized State)**: If the node boots with state `ROLLBACK_FAILED` (or if participant snapshot restoration fails during crash recovery, or if the journal is unreadable, corrupt JSON, or contains an unknown state), `startup_node.sh` logs a critical safety abort `CRITICAL SAFETY ABORT: Credential transaction journal is corrupt, unreadable, or in an unrecognized state`, preserves all existing `*.prev` snapshots and creates a timestamped corrupt journal backup (`${JOURNAL_FILE}.corrupt.$(date +%s)`), strictly avoids overwriting the journal or resetting to baseline `COMMITTED`, and **aborts execution immediately (`exit 1`)**. Automatic resets that could conceal partial credential installations or split-brain configurations are strictly prohibited without explicit, verified administrative recovery.
     * **Committed State Audit & Orphaned Rollback Cleanup (`state == "COMMITTED"`)**: 
       - Verifies file permissions (`0600 root:root` for active secret files).
       - Safely purges any stale/orphaned `*.prev` and `*.tmp` snapshot files left over from prior power cuts after commit (`rm -f /opt/olg/config/jwt/*.prev /opt/olg/config/*.prev /etc/olg/client/*.prev /etc/olg/guest-secrets/*.prev /opt/olg/config/jwt/*.tmp /etc/olg/client/*.tmp /etc/olg/guest-secrets/*.tmp`), preventing future rotations from accidentally restoring stale cross-generational artifacts.
       - Proceeds to PKI audit.
  4. **Local Appliance PKI & NATS JWT/NKey Bootstrapping (Self-Bootstrapping & Integrity Audit Protocol)**:
     * **Zero Pre-baked Keys Security Invariant**: Golden OS Images must **never** contain pre-baked private keys (`ca.key`, `nats-server.key`, `*.nk`) or shared certificates, preventing fleet-wide private key compromise. Every appliance generates its own unique local Root CA, server certificates, and NATS Operator/Account/User NKeys on its initial cold boot.
     * **Complete Artifact Set & Cryptographic Integrity Audit**:
       - Checks for the complete set of required PKI artifacts in `/opt/olg/config/certs/`:
         1. `/opt/olg/config/certs/ca.crt` (Root CA Certificate)
         2. `/opt/olg/config/certs/ca.key` (Root CA Private Key)
         3. `/opt/olg/config/certs/nats-server.crt` (NATS Server Certificate)
         4. `/opt/olg/config/certs/nats-server.key` (NATS Server Private Key)
       - Checks for the complete set of required NATS JWT/NKey artifacts in `/opt/olg/config/jwt/`, `/etc/olg/client/`, and `/etc/olg/guest-secrets/`:
         1. `/opt/olg/config/jwt/operator.jwt` & `operator.nk`
         2. `/opt/olg/config/jwt/olg_account.jwt` & `olg_account.nk`
         3. `/opt/olg/config/jwt/sys_account.jwt` & `sys_account.nk`
         4. `/opt/olg/config/jwt/orchestrator.creds`
         5. `/etc/olg/client/ucentral.creds` (decorated `.creds` containing User JWT & NKey seed)
         6. `/etc/olg/guest-secrets/vyos_agent.creds` (decorated `.creds` containing User JWT & NKey seed)
         7. `/etc/olg/guest-secrets/agent.env`
       - **Integrity & Consistency Validation**: When all artifacts are present, executes preflight cryptographic validation:
         1. *TLS Keypair Match*: Verifies that `nats-server.crt` matches `nats-server.key` public key modulus (`openssl x509 -noout -modulus -in nats-server.crt` equals `openssl rsa -noout -modulus -in nats-server.key`).
         2. *CA Signature Verification*: Verifies that `nats-server.crt` validates cryptographically against `ca.crt` (`openssl verify -CAfile ca.crt nats-server.crt`).
         3. *SAN Verification*: Validates that `nats-server.crt` contains all mandatory Subject Alternative Names: `DNS:nats-server,DNS:localhost,IP:192.168.254.2,IP:127.0.0.1`.
         4. *NATS Decorated Credential Validation*: Validates that `ucentral.creds` and `vyos_agent.creds` are valid decorated NATS credentials parsable by `jwt.ParseDecoratedJWT` and `jwt.ParseDecoratedNKey`.
         5. *Permissions Audit*: Verifies directory permissions (`0700 root:root`), private key permissions (`0600 root:root`), and public cert permissions (`0644 root:root`).
     * **Audit Outcomes & Execution Branch**:
       - **Valid PKI State (Subsequent Boots)**: If all artifacts exist and pass all cryptographic and permissions checks, generation is skipped. The script synchronizes public trust stores (`/etc/olg/client/ca.crt` and `/etc/olg/guest-secrets/ca.crt`) and proceeds immediately.
       - **Incomplete / Corrupted / Absent State (Initial Boot or Interrupted Boot Recovery)**: If any required file is absent, truncated, mismatched, or fails cryptographic validation (e.g. from an unclean first-boot power interruption), `startup_node.sh` purges any partial staging artifacts and **atomically regenerates the entire appliance PKI and NATS credentials from scratch** as a single coherent generation:
         1. Ensures directories `/opt/olg/config/certs` and `/opt/olg/config/jwt` exist with directory mode `0700` owned by `root:root`.
         2. Generates an appliance-unique Root CA (`ca.key` mode `0600`, `ca.crt` mode `0644`) owned by `root:root`.
         3. Generates and issues NATS Server Certificate (`nats-server.key` mode `0600`, `nats-server.crt` mode `0644`) signed by the local CA with Subject Alternative Names: `DNS:nats-server,DNS:localhost,IP:192.168.254.2,IP:127.0.0.1`.
         4. Executes `tools/pki_init` to generate Operator Keypair/JWT, System and Application Account Keypairs/JWTs, and user decorated `.creds` files (`orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`) with strict subject permissions.
         5. Ensures directories `/etc/olg/client` and `/etc/olg/guest-secrets` exist with directory mode `0700` owned by `root:root`.
         6. Copies `ca.crt` (`0644`) to `/etc/olg/client/ca.crt` and `/etc/olg/guest-secrets/ca.crt`.
         7. Writes `/etc/olg/guest-secrets/agent.env` (`0600 root:root`) referencing `NATS_SERVER=tls://192.168.254.2:4222`, `NATS_CREDS_FILE=/etc/olg/secrets/vyos_agent.creds`, and `NATS_CA_FILE=/etc/olg/secrets/ca.crt`.
         8. Initializes `/etc/olg/client/config.json` (mode `0600 root:root`) referencing `tls://nats-server:4222`, `credentials_file: /etc/olg/client/ucentral.creds`, and `ca_file: /etc/olg/client/ca.crt`.
  5. **Automated Host Netplan Bridge Setup**: Copies `./config/netplan_bridges.yaml` to `/etc/netplan/99-olg-bridges.yaml` and executes `netplan apply` to bring up persistent host bridge `br-mgmt` (`192.168.254.2/24` with default route `default via 192.168.254.1`).
  6. **Docker Stack Deployment & Bounded NATS Readiness Gate**:
     * Launches `/opt/olg/docker-compose.yml` via idempotent `docker compose up -d`.
     * Containers attach to a user-defined Docker bridge network via `veth` interfaces. `nats-server` publishes TLS port `4222` to `192.168.254.2:4222` and `127.0.0.1:4222` (volume `/opt/olg/data/nats:/data/jetstream` and flag `-sd /data/jetstream`).
     * `ucentral-client` connects to `tls://nats-server:4222` across the bridge network using mounted `/etc/olg/client/config.json`, `ucentral.creds`, and `ca.crt`, routing internet traffic through host gateway (`192.168.254.1`).
     * **Deterministic NATS TLS & JetStream Readiness Gate**:
       - To eliminate cold-boot race conditions where NATS is still initializing listeners, resolver mappings, or JetStream storage when callers attempt KV operations, `startup_node.sh` enforces a bounded readiness check before proceeding:
         1. *Container State Check*: Polls `docker inspect -f '{{.State.Running}}' nats-server` until `true` (up to 10-second timeout).
         2. *Authenticated TLS JetStream Probe*: Executes `tools/kv_config_init --creds /opt/olg/config/jwt/orchestrator.creds --ca /opt/olg/config/certs/ca.crt --server tls://127.0.0.1:4222 --probe-only` with retry backoff (polling every 500ms up to a 15-second timeout window). The probe validates TCP connection, TLS handshake, SAN validation, Operator/Account JWT authentication, and JetStream engine readiness.
       - **Readiness Failure Policy**: If NATS fails to become ready within the 15-second window, `startup_node.sh` aborts immediately (`exit 1`) with error `ERROR: NATS JetStream readiness probe failed after 15s; aborting deployment before VFIO handoff`.
  7. **Conditional NATS JetStream State Seeding**:
     * Once the readiness gate confirms NATS is healthy, `startup_node.sh` invokes `tools/kv_config_init` to establish the baseline configuration state:
       - **If `--force-reseed` IS set (Force Overwrite)**:
         Executes `./tools/kv_config_init --creds /opt/olg/config/jwt/orchestrator.creds --ca /opt/olg/config/certs/ca.crt --payload ./config/vyos_initial_state.json --force` over TLS to unconditionally overwrite `desired.vyos` in bucket `cfg_desired`, resetting router configuration to the baseline envelope.
       - **If `--force-reseed` is NOT set (Default Conditional Seeding)**:
         Executes `./tools/kv_config_init --creds /opt/olg/config/jwt/orchestrator.creds --ca /opt/olg/config/certs/ca.crt --payload ./config/vyos_initial_state.json --if-not-exists` over TLS. `kv_config_init` inspects bucket `cfg_desired` and seeds the baseline envelope ONLY if `desired.vyos` is missing/empty, preserving any existing cloud-delivered configuration during normal boots and node recoveries.
  8. **Idempotent VFIO PCI Driver Binding (`driver_override` Contract)**:
     * **Already-Bound State Handling**: Inspects currently active driver via `readlink /sys/bus/pci/devices/$BDF/driver`. If a target device is already bound to `vfio-pci`, re-binding is skipped to prevent disrupting active device handles.
     * **Native Driver Detection & Unbind**: If bound to a native host driver (e.g., `r8169`, `e1000e`, `igb`, `ixgbe`), detaches the interface from host bridges (`nomaster`) and executes unbind.
     * **Prohibits Global Vendor/Device ID Matching**: Global `/etc/modprobe.d/vfio.conf` with `options vfio-pci ids=vendor:device` is strictly **PROHIBITED** to prevent `vfio-pci` from claiming identical NIC models used by host management/SSH.
     * **Executes BDF-Specific Sysfs Driver Override**: Binds ONLY the targeted `$WAN_PCI_BDF` (and `$LAN_PCI_BDF` when `LAN_TYPE=pci`) to `vfio-pci` using sysfs BDF override:
       ```bash
       bind_to_vfio() {
         local bdf="$1"
         local current_driver
         current_driver=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" || echo "")
         if [ "$current_driver" = "vfio-pci" ]; then
           return 0  # Already bound; skip to preserve idempotency
         fi
         echo "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind" 2>/dev/null || true
         echo "vfio-pci" > "/sys/bus/pci/devices/$bdf/driver_override"
         echo "$bdf" > /sys/bus/pci/drivers/vfio-pci/bind
       }

       bind_to_vfio "$WAN_PCI_BDF"
       if [ "$LAN_TYPE" = "pci" ]; then
         bind_to_vfio "$LAN_PCI_BDF"
       fi
       ```
  9. **VyOS Dynamic Domain XML Generation & Idempotent VM Startup**:
      * **Stateless Ephemeral Disk Lifecycle Contract via Native `<transient/>`**:
        - Master template `/opt/olg/images/vyos-golden.qcow2` is opened strictly read-only by QEMU (mode `0444 root:root`).
        - Libvirt domain XML disk configuration specifies standard `<transient/>`.
        - **Native Libvirt Ephemeral Disk Lifecycle Management**:
          - Under native Libvirt `<transient/>` disk handling (`libvirt-daemon-system >= 11.0.0`), QEMU automatically manages runtime ephemeral writes in `/opt/olg/images/vyos-golden.qcow2.TRANSIENT-vyos-router`. Libvirt natively unlinks any orphaned transient overlay prior to creating a fresh ephemeral instance on domain start.
          - **Live VM Disk Protection Invariant**: Manual unlinking, modification, or deletion of `.TRANSIENT-*` overlay files is strictly **PROHIBITED** whenever the guest domain is active or in any non-stopped state (`running`, `paused`, `pmsuspended`, `blocked`, `in shutdown`, `crashed`), preventing corruption, race conditions, or detachment of live backing storage.
          - **Ephemeral Disk Acceptance & Recovery Test**:
            - Boot VM $\rightarrow$ make guest filesystem change $\rightarrow$ hard power-cycle host $\rightarrow$ start appliance $\rightarrow$ VM starts successfully $\rightarrow$ previous runtime change absent $\rightarrow$ golden QCOW2 SHA256 checksum strictly unchanged.
      * Dynamically generates and applies `vyos-router` domain XML via `virsh define <xml>` with static management MAC (`52:54:00:f9:ab:48` for `br-mgmt`), **Native Hypervisor Auto-Restart Policies**, and **Read-Only VirtIO-FS Guest Secrets Share**:
        ```xml
        <domain type='kvm'>
          <name>vyos-router</name>
          <memory unit='KiB'>2097152</memory>
          <memoryBacking>
            <source type='memfd'/>
            <access mode='shared'/>
          </memoryBacking>
          <vcpu placement='static'>2</vcpu>
          <on_poweroff>destroy</on_poweroff>
          <on_reboot>restart</on_reboot>
          <on_crash>restart</on_crash>
          <devices>
            <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2' discard='unmap'/>
              <source file='/opt/olg/images/vyos-golden.qcow2'/>
              <target dev='vda' bus='virtio'/>
              <transient/>
            </disk>
            <filesystem type='mount' accessmode='passthrough'>
              <driver type='virtiofs'/>
              <source dir='/etc/olg/guest-secrets'/>
              <target dir='guest_secrets'/>
              <readonly/>
            </filesystem>
            <channel type='unix'>
              <source mode='bind'/>
              <target type='virtio' name='org.qemu.guest_agent.0'/>
            </channel>
            ...
          </devices>
        </domain>
        ```
      * Attaches WAN PCI controller via VFIO (`<hostdev type='pci'>` for `WAN_PCI_BDF`).
      * Attaches LAN interface according to `/etc/olg/hardware-profile.json`:
        - If `LAN_TYPE=pci`: Attaches `<hostdev type='pci'>` for `LAN_PCI_BDF`.
        - If `LAN_TYPE=usb`: Resolves active USB bus/device numbers from sysfs (`LAN_USB_BUS`, `LAN_USB_DEV`) and attaches `<hostdev mode='subsystem' type='usb'><source><address bus='$LAN_USB_BUS' device='$LAN_USB_DEV'/></source></hostdev>` to guarantee exact physical USB device targeting even when identical USB dongles exist.
      * **Idempotent VM Lifecycle & Strict State Transition Contract**:
        ```bash
        VM_STATE=$(virsh domstate vyos-router 2>/dev/null || echo "shut off")
        case "$VM_STATE" in
          "running")
            if [ "$FLAG_RECREATE_VM" = "true" ]; then
              echo "Recreate requested: initiating graceful ACPI shutdown of vyos-router..."
              virsh shutdown vyos-router 2>/dev/null || true
              SHUTDOWN_CONFIRMED=false
              # Wait up to 10 seconds for graceful shutdown
              for i in $(seq 1 20); do
                if [ "$(virsh domstate vyos-router 2>/dev/null)" = "shut off" ]; then
                  SHUTDOWN_CONFIRMED=true
                  break
                fi
                sleep 0.5
              done
              # If graceful shutdown hung or exceeded window, fallback to forceful destroy
              if [ "$SHUTDOWN_CONFIRMED" != "true" ]; then
                echo "Graceful shutdown timed out; executing forceful destroy on vyos-router..."
                virsh destroy vyos-router 2>/dev/null || true
                for i in $(seq 1 10); do
                  if [ "$(virsh domstate vyos-router 2>/dev/null)" = "shut off" ]; then
                    SHUTDOWN_CONFIRMED=true
                    break
                  fi
                  sleep 0.5
                done
              fi
              if [ "$SHUTDOWN_CONFIRMED" != "true" ]; then
                echo "ERROR: Timed out waiting for vyos-router to reach 'shut off' state even after virsh destroy. Aborting." >&2
                exit 1
              fi
              virsh start vyos-router
            else
              echo "vyos-router is already running; preserving active instance."
            fi
            ;;
          "shut off")
            echo "vyos-router is shut off; initiating clean domain startup..."
            virsh start vyos-router
            ;;
          *)
            echo "ERROR: vyos-router is in non-stopped state '$VM_STATE' (paused/blocked/crashed/in-shutdown). Manual intervention required; refusing to start or touch VM disks." >&2
            exit 1
            ;;
        esac
        ```
      * **Normalized Hostdev Hardware Reconciliation**: When `vyos-router` is already in `running` state, `startup_node.sh` parses and normalizes the physical PCI and USB hostdev assignments from `virsh dumpxml` and the desired domain XML via `extract_normalized_hostdevs`. It ignores runtime-generated guest PCI addresses, driver tags, and XML formatting artifacts. The active VM is destroyed and recreated only if physical hardware assignments actually differ. If hardware comparison cannot be completed safely (e.g. malformed XML), the running router is preserved without disruption.
  10. **Post-Boot VyOS Management Gateway Verification (Zero-SSH Declarative Model)**:
      * Following domain launch, `startup_node.sh` performs a non-invasive network health probe verifying reachability of the VyOS management gateway interface (`192.168.254.1`) on `br-mgmt`.
      * **Zero-SSH Invariant**: The host orchestrator does NOT require SSH credentials, keys, or interactive remote commands (`sshpass` and host-side SSH execution are prohibited). All in-guest configuration is managed declaratively by `vyos-nats-agent` subscribing to NATS JetStream `cfg_desired`.
      * **Kea DHCP Bridge Interface Raw Socket Rebinding**: ISC Kea DHCPv4 in VyOS uses raw packet sockets (`dhcp-socket-type: raw`). To ensure the Kea DHCP daemon reliably binds to active LAN bridge interfaces (`br1`) and serves IP addresses to client devices across dynamic commits and system reboots, an automated postconfig trigger (`vyos-postconfig-bootup.script`) and VyOS commit hook (`/config/scripts/commit/post-hooks.d/10-restart-kea`) are installed directly into the golden master image (`/opt/olg/images/vyos-golden.qcow2`) to restart `isc-kea-dhcp4-server` once interface addresses are bound.
  11. **Single VM Startup Owner Contract & Clean Service Exit**: Explicitly disables libvirt domain autostart (`virsh autostart --disable vyos-router`) to ensure `startup_node.sh` remains the sole boot-time orchestrator before handing off crash recovery to Libvirt. Exits cleanly with status code `0`.

---

#### 4.2 `scripts/telemetry_dashboard.sh` (Real-Time Visual Telemetry Dashboard)
* **Purpose**: Pipes raw metrics from `dpinger` into a visual dashboard displaying timestamped Latency (ms), Jitter (ms), Packet Loss (%), and Health Taxonomy classification.
* **Input Arguments**:
  * `$1`: Target IP (Default: `1.1.1.1`).
  * `$2`: Probe Send Interval (Default: `1s`).
  * `$3`: Averaging Window (Default: `8s`).
* **Health Taxonomy Rules**:
  * **BLACKOUT**: Packet Loss $\ge 95\%$.
  * **CRITICAL**: Packet Loss $> 20\%$ OR Latency $> 220\text{ms}$ OR Jitter $> 60\text{ms}$.
  * **POOR**: Packet Loss $> 3\%$ OR Latency $> 130\text{ms}$ OR Jitter $> 30\text{ms}$.
  * **FAIR**: Packet Loss $> 1\%$ OR Latency $> 70\text{ms}$ OR Jitter $> 15\text{ms}$.
  * **GOOD**: Latency $> 30\text{ms}$ OR Jitter $> 5\text{ms}$.
  * **EXCELLENT**: Latency $\le 30\text{ms}$ and Jitter $\le 5\text{ms}$.

---

### 4.3 `scripts/network_simulator.sh` (Network Impairment Emulation Suite)
* **Purpose**: Uses Linux Traffic Control (`tc netem`) and `iptables` rules to inject controlled network impairments for telemetry testing.
* **Modes**:
  * `excellent` / `reset`: Clears all `tc` qdiscs and `iptables` drop rules.
  * `good`: Injects 40ms delay, 5ms jitter.
  * `fair`: Injects 80ms delay, 20ms jitter, 2% loss.
  * `poor`: Injects 150ms delay, 40ms jitter, 5% loss.
  * `critical`: Injects 250ms delay, 80ms jitter, 15% loss.
  * `blackout`: Injects 500ms delay, 100ms jitter, 95% loss.
  * `simulate-egress-drop`: Drops outbound ICMP to external health check targets (`1.1.1.1`, `8.8.8.8`, `9.9.9.9`) to test telemetry visualization without affecting router state.

---

## 5. Auxiliary Tools Specification (`tools/`)

#### 5.1 `tools/pki_init` & `tools/pki_init.go`
* **Purpose**: Compiled Go utility that generates and manages the NATS 2.0+ Operator / Account / User cryptographic identity hierarchy using standard `github.com/nats-io/nkeys` and `github.com/nats-io/jwt/v2`. Generates Operator and Account Keypairs/JWTs, issues signed User JWTs with explicit publish/subscribe permissions, and outputs standard decorated `.creds` files formatted via `jwt.FormatUserConfig` (containing both User JWT and User NKey Seed).
* **CLI Arguments & Modes**:
  * `--mode bootstrap` (default): Initializes the complete appliance NATS PKI:
    - Operator Keypair (`/opt/olg/config/jwt/operator.nk`) & JWT (`/opt/olg/config/jwt/operator.jwt`).
    - System Account Keypair (`/opt/olg/config/jwt/sys_account.nk`) & JWT (`/opt/olg/config/jwt/sys_account.jwt`).
    - Application Account Keypair (`/opt/olg/config/jwt/olg_account.nk`) & JWT (`/opt/olg/config/jwt/olg_account.jwt`).
    - Issues `orchestrator.creds` -> `/opt/olg/config/jwt/orchestrator.creds` (`0600 root:root`).
    - Issues `ucentral.creds` -> `/etc/olg/client/ucentral.creds` (`0600 root:root`).
    - Issues `vyos_agent.creds` -> `/etc/olg/guest-secrets/vyos_agent.creds` (`0600 root:root`).
  * `--mode rotate-user --user <NAME> --out <PATH>`: Generates a new User Keypair, signs a new User JWT using active Account NKey (`/opt/olg/config/jwt/olg_account.nk`), and writes a candidate decorated `.creds` file to `<PATH>`.
  * `--mode verify-creds --creds <PATH>`: Validates that `<PATH>` contains a valid decorated NATS credential parsable by `jwt.ParseDecoratedJWT` and `jwt.ParseDecoratedNKey`.

#### 5.2 `tools/kv_config_init` & `tools/kv_config_init.go`
* **Purpose**: Compiled Go utility that securely connects via TLS to the NATS JetStream server (`tls://127.0.0.1:4222` or `tls://192.168.254.2:4222`) using the local appliance Root CA (`/opt/olg/config/certs/ca.crt`) with standard certificate verification against configured SANs (`127.0.0.1`, `192.168.254.2`, `localhost`, `nats-server`), authenticates using orchestrator credentials via decorated credentials file (`/opt/olg/config/jwt/orchestrator.creds` or CLI flag `--creds`), initializes Key-Value bucket `cfg_desired`, and publishes `./config/vyos_initial_state.json` under key `desired.vyos`.
* **CLI Arguments & Flags**:
  * `--server <URL>`: NATS TLS endpoint (default `tls://127.0.0.1:4222`).
  * `--ca-file <PATH>`: Appliance Root CA certificate path (default `/opt/olg/config/certs/ca.crt`). Normal certificate validation is strictly enabled.
  * `--creds <PATH>`: Path to orchestrator decorated NATS `.creds` file (default `/opt/olg/config/jwt/orchestrator.creds` or env `NATS_CREDS_FILE`).
  * `--payload <FILE>`: Path to baseline state JSON (default `./config/vyos_initial_state.json`).
  * `--bucket <NAME>`: Target KV bucket name (default `cfg_desired`).
  * `--key <KEY>`: Target KV key name (default `desired.vyos`).
  * `--force`: Overwrites `desired.vyos` unconditionally with the provided baseline JSON payload, resetting router configuration in the KV store.
  * `--if-not-exists` (default): Inspects bucket `cfg_desired` and populates `desired.vyos` **only if the key does not already exist**, preserving existing cloud-delivered configuration state during node recovery.
* **Connection Resilience**: Retries TLS connection with exponential backoff up to 10 times if NATS server container is still initializing.

### 5.3 `tools/dpinger`
* **Purpose**: High-precision compiled C telemetry binary. Sends continuous ICMP Echo requests at configured interval (`-s 1s`) over a sliding window (`-t 8s`), streaming raw `<latency_us> <stddev_us> <loss_pct>` to stdout.

### 5.4 `tools/rotate_credentials.sh` (Planned Host-Side Credential Rotation & Automated Rollback Tool)
* **Purpose**: Planned host-side management utility specified for execution by operators or administrative orchestrators to perform atomic, zero-VM-reboot credential rotations across NATS, `ucentral-client`, and `vyos-router` (VyOS Guest Agent) with automated failure detection and deterministic rollback guarantees.
* **CLI Parameters (Required Interface Specification)**:
  * `--client-creds <PATH>`: Path to candidate uCentral client decorated `.creds` file (staged as `/etc/olg/client/ucentral.creds.tmp`).
  * `--agent-creds <PATH>`: Path to candidate VyOS agent decorated `.creds` file (staged as `/etc/olg/guest-secrets/vyos_agent.creds.tmp`).
  * `--agent-env <PATH>`: Path to candidate VyOS agent environment file (staged as `/etc/olg/guest-secrets/agent.env.tmp`).
  * `--timeout <SEC>`: In-flight verification timeout per probe (default `10s`).
  * `--rollback-on-failure`: Automatically execute generation rollback if any probe fails (default `true`).
* **Execution Flow Contract**: Executes the 5-phase transaction protocol specified in §7.5 (Staging & Preflight Cryptographic Validation, Active Snapshot, Apply, Multi-Service Reload & Deterministic Verification Probes, and Commit or Automatic Rollback & Verification).

---

## 6. Execution Dependencies & Verification Matrix

```text
               +----------------------------------+
               |  olg-orchestrator.service        | (One-Shot Boot Service)
               |  (systemd/olg-orchestrator.service)|
               +----------------+-----------------+
                                |
             (Provisions Host, Starts Containers, Boots VM)
                                |
                                v
               +----------------------------------+
               |  Clean Service Completion        | (Exits 0)
               +----------------+-----------------+
                                |
                                v
               +----------------------------------+
               |  Libvirt Native Crash Handler    | <--- Automatically boots VM back up
               |  (<on_crash>restart</on_crash>)  |      on guest kernel panic / crash
               +----------------+-----------------+
                                |
                                v
               +----------------------------------+
               |  dpinger Telemetry Stream        | <--- Continuous Latency & Loss
               |  (scripts/telemetry_dashboard.sh)|      Metrics (Passive Telemetry)
               +----------------+-----------------+
```

### 6.1 Boot, Crash Recovery & Renderer Invariant Validation Contract
1. **Direct One-Shot Boot Execution**: `startup_node.sh` applies host Netplan management bridge configuration (`br-mgmt`), starts Docker microservices on the user-defined Docker bridge network, seeds baseline NATS JetStream KV state, binds VFIO PCI drivers, defines and boots the VyOS router VM, and exits `0` cleanly.
2. **Native Hypervisor Crash Recovery**: Configured natively via `<on_crash>restart</on_crash>` and `<on_reboot>restart</on_reboot>` in the domain XML so that Libvirt automatically boots the VM back up if the guest crashes or panics, without requiring external supervisor scripts.
3. **Passive Telemetry Monitoring**: Egress ICMP metrics are continuously observed via `dpinger` and `telemetry_dashboard.sh` for link health reporting. Packet loss is strictly an external metric and does not trigger VM lifecycle events.
4. **Renderer Immutable Invariants & Validation Contract**:
   - **Immutable Invariants**: The configuration rendering agent strictly enforces the following immutable baseline invariants:
     - Core management interface IP address and link (`mgmt0` at `192.168.254.1/24`, MAC `52:54:00:f9:ab:48`), which is initialized exclusively by the internal management layer and is **never** dependent on or overridden by `desired.vyos`.
     - Physical WAN bridge identity and dynamic DHCP configuration (`br0` containing physical WAN `eth0`).
     - Outbound SNAT masquerade rule 100 on `br0`.
     - `LAN_TO_MGMT` firewall policy dropping inter-zone traffic (`192.168.100.0/24` -> `192.168.254.0/24`).
   - **Cloud Payload Validation & Rejection Contract**:
     - The rendering agent validates desired configuration states (`desired.vyos` from `cfg_desired`) prior to applying or committing changes.
     - If an incoming cloud desired configuration attempts to modify, overwrite, or remove any immutable invariant (e.g. altering `mgmt0`, disabling SNAT Rule 100, or dropping `LAN_TO_MGMT` firewall):
       - The renderer **rejects** the conflicting configuration payload.
       - The currently active, valid configuration is **preserved** without disruption.
       - A validation failure status event is published to `status.>` and `result.>` to alert the cloud control plane.

---

## 7. Control Plane Security & Management Isolation

### 7.1 NATS Listener Scope & Interface Prohibitions
* **Management Listener Scope**: `nats-server` runs on a user-defined Docker bridge network via `veth` pairs. Port `4222` is published strictly to the management IP address `192.168.254.2:4222` (on `br-mgmt`) and localhost `127.0.0.1:4222`.
* **WAN Interface Prohibitions**: Publishing or binding `nats-server` to the physical WAN PCI NIC or `0.0.0.0` is strictly **PROHIBITED**.
* **LAN Interface Prohibitions**: Publishing or binding `nats-server` to LAN interface (`eth2` / Physical PCI or USB LAN) or `192.168.100.0/24` is strictly **PROHIBITED**.

### 7.2 Per-User Subject Authorization & NATS JWT/NKey Security Model
* **Mandatory Cryptographic Authentication & Authorization**: Anonymous access to `nats-server` and JetStream KV store (`cfg_desired`) is strictly disabled. NATS authentication and authorization are configured via NATS 2.0+ Operator, Account, and User JWT claims with NKey cryptographic challenge-response authentication.
* **JetStream KV Operational Protocol & API Scope**:
  - JetStream Key-Value operations in client libraries (such as Go `nats.js.KeyValue()`, `kv.Get()`, `kv.Put()`, and `kv.Watch()`) require access to both data subjects (`$KV.cfg_desired.>`) and JetStream system API subjects for stream discovery, direct message retrieval, consumer creation, and ephemeral request/reply inboxes (`_INBOX.>`).
  - Underlying JetStream streams for KV buckets are prefixed with `KV_` (e.g., bucket `cfg_desired` corresponds to stream `KV_cfg_desired`).
* **Capability Matrix & Role Segregation Contract**:
  | Capability | `orchestrator` | `ucentral_client` | `vyos_agent` |
  | :--- | :--- | :--- | :--- |
  | **KV `cfg_desired` Put / Update** | **YES** | **YES** | **NO** |
  | **KV `cfg_desired` Get / Watch** | **YES** | **YES** | **YES** |
  | **Stream Lifecycle (Create/Delete Streams)** | **YES** | **NO** | **NO** |
  | **Ephemeral Consumer Management (`KV_cfg_desired`)** | **YES** | **YES** | **YES** |
  | **Publish Status / Health / Results** | **YES** | **NO** | **YES** |
  | **Subscribe Status / Health / Results** | **YES** | **YES** | **NO** |
* **Per-User Permissions & Decorated `.creds` Specification**:
  1. **`orchestrator` (`/opt/olg/config/jwt/orchestrator.creds`)**:
     - **Role**: Host boot reconciliation and initial state seeding (`startup_node.sh`, `kv_config_init`).
     - **Permissions**: Administrative JetStream access to create/update streams, buckets, and seed initial envelopes (`publish: [">"]`, `subscribe: [">"]`).
  2. **`ucentral_client` (`/etc/olg/client/ucentral.creds`)**:
     - **Role**: Cloud-facing gateway client connecting over the Docker bridge network.
     - **Decorated Credential Contract**: Formatted with `jwt.FormatUserConfig` containing signed User JWT and User NKey Seed. Parsed and verified directly by `TIP-olg-ucentral-client` via `jwt.ParseDecoratedJWT` and `jwt.ParseDecoratedNKey`.
     - **Publish Permissions**:
       - `$KV.cfg_desired.>` (Put/update desired state)
       - `cmd.>` (Issue commands to router)
       - `$JS.API.STREAM.INFO.KV_cfg_desired` (Discover bucket info)
       - `$JS.API.DIRECT.GET.KV_cfg_desired.>` (Direct KV reads)
       - `$JS.API.CONSUMER.CREATE.KV_cfg_desired` (Create ephemeral stream-level consumers)
       - `$JS.API.CONSUMER.CREATE.KV_cfg_desired.>` (Create named/durable consumer watchers)
       - `$JS.API.CONSUMER.INFO.KV_cfg_desired.>` (Inspect ephemeral watchers)
       - `$JS.API.CONSUMER.MSG.NEXT.KV_cfg_desired.>` (Pull messages from consumer)
       - `$JS.API.CONSUMER.DELETE.KV_cfg_desired.>` (Delete ephemeral watchers)
       - `_INBOX.>` (Request/reply response handling)
     - **Subscribe Permissions**:
       - `status.>`, `health.>`, `result.>` (Subscribe to router telemetry and results)
       - `_INBOX.>` (Receive JetStream API responses)
     - **Prohibitions**: Cannot delete streams/buckets, modify orchestrator settings, or publish false router status events.
  3. **`vyos_agent` (`/etc/olg/guest-secrets/vyos_agent.creds`)**:
     - **Role**: Router configuration agent inside VyOS VM connecting over management link `mgmt0` (`192.168.254.1` $\rightarrow$ `192.168.254.2:4222`).
     - **Publish Permissions**:
       - `status.>`, `health.>`, `result.>` (Publish applied router status and health telemetry)
       - `$JS.API.STREAM.INFO.KV_cfg_desired` (Discover bucket info)
       - `$JS.API.DIRECT.GET.KV_cfg_desired.>` (Direct KV reads)
       - `$JS.API.CONSUMER.CREATE.KV_cfg_desired` (Create ephemeral stream-level consumers)
       - `$JS.API.CONSUMER.CREATE.KV_cfg_desired.>` (Create named/durable consumer watchers)
       - `$JS.API.CONSUMER.INFO.KV_cfg_desired.>` (Inspect ephemeral watchers)
       - `$JS.API.CONSUMER.MSG.NEXT.KV_cfg_desired.>` (Pull messages / watch updates from consumer)
       - `$JS.API.CONSUMER.DELETE.KV_cfg_desired.>` (Delete ephemeral watchers)
       - `_INBOX.>` (Request/reply response handling)
     - **Subscribe Permissions**:
       - `$KV.cfg_desired.>` (Subscribe and watch desired configuration)
       - `cmd.>` (Receive command notifications)
       - `_INBOX.>` (Receive JetStream API responses)
     - **Prohibitions**: Cannot write or overwrite cloud desired configurations (`$KV.cfg_desired.>` publish denied) or perform stream lifecycle deletion.
* **Exact NATS Server Configuration Contract (`/opt/olg/config/nats.conf`)**:
  ```text
  port: 4222

  tls {
    cert_file: "/etc/nats/certs/nats-server.crt"
    key_file:  "/etc/nats/certs/nats-server.key"
    ca_file:   "/etc/nats/certs/ca.crt"
  }

  jetstream {
    store_dir: "/data/jetstream"
  }

  include ./resolver.conf
  ```

* **Exact NATS Memory Resolver Configuration Contract (`/opt/olg/config/resolver.conf`)**:
  ```text
  # NATS 2.0+ Operator & Embedded Memory Account Resolver
  operator: "/etc/nats/jwt/operator.jwt"
  system_account: "<SYS_ACCOUNT_PUBKEY>"

  resolver: MEMORY
  resolver_preload: {
    "<APP_ACCOUNT_PUBKEY>": "<ENCODED_APP_ACCOUNT_JWT>"
    "<SYS_ACCOUNT_PUBKEY>": "<ENCODED_SYS_ACCOUNT_JWT>"
  }
  ```

* **Secrets Provisioning & Permissions**:
  - Appliance NATS PKI directory `/opt/olg/config/jwt/` with directory mode `0700 root:root`; private NKeys (`operator.nk`, `olg_account.nk`, `sys_account.nk`) with file mode `0600 root:root`; public JWTs (`operator.jwt`, `olg_account.jwt`, `sys_account.jwt`) with file mode `0644 root:root`; `orchestrator.creds` with file mode `0600 root:root`.
  - Local appliance TLS certificates directory `/opt/olg/config/certs/` with directory mode `0700 root:root`; private keys (`ca.key`, `nats-server.key`) with file mode `0600 root:root`; public certificates (`ca.crt`, `nats-server.crt`) with file mode `0644 root:root`.
  - Client configuration directory `/etc/olg/client/` with directory mode `0700 root:root` containing `config.json` (file mode `0600 root:root`, pointing to `tls://nats-server:4222`, `credentials_file: /etc/olg/client/ucentral.creds`, `ca_file: /etc/olg/client/ca.crt`), `ucentral.creds` (decorated `.creds` file mode `0600 root:root`), and `ca.crt` (file mode `0644 root:root`).
  - Guest secrets directory `/etc/olg/guest-secrets/` with directory mode `0700 root:root` containing `vyos_agent.creds` (decorated `.creds` file mode `0600 root:root`), `agent.env` (file mode `0600 root:root`, `NATS_SERVER=tls://192.168.254.2:4222`, `NATS_CREDS_FILE=/etc/olg/secrets/vyos_agent.creds`, `NATS_CA_FILE=/etc/olg/secrets/ca.crt`), and `ca.crt` (file mode `0644 root:root`).
  - Blanket wildcard access (`$JS.API.>`) is strictly prohibited to guarantee least-privilege isolation.

### 7.3 Persistent JetStream Storage Path
* **Host Data Persistence**: NATS JetStream storage MUST be persisted across container resets and host reboots via host directory `/opt/olg/data/nats`.
* **Container Volume Mount Contract**: Mounted into the `nats-server` container at `/data/jetstream` using Docker Compose volume mount `/opt/olg/data/nats:/data/jetstream` with daemon flag `-sd /data/jetstream`.

### 7.4 VyOS LAN-to-Management Subnet Firewall Policy Contract
* **Ingress Firewall Policy**: VyOS MUST enforce a dedicated firewall ruleset (`LAN_TO_MGMT`) attached directly to routed bridge interface `br1` (`interfaces bridge br1 firewall in name LAN_TO_MGMT`).
* **Rule Specification**:
  - **Command Structure**: `set firewall name LAN_TO_MGMT default-action accept`, `set firewall name LAN_TO_MGMT rule 10 action drop`, `set firewall name LAN_TO_MGMT rule 10 destination address 192.168.254.0/24`.
  - **Match Target**: Destination IPv4 subnet `192.168.254.0/24` (Management network).
  - **Action**: `drop` (silent drop; `reject` is strictly prohibited to prevent information leakage).
  - **Exceptions**: None. Inter-zone routing from LAN (`192.168.100.0/24`) to Management (`192.168.254.0/24`) is strictly blocked.
* **Isolation Guarantee**: Downstream LAN clients cannot reach `nats-server`, `ucentral-client`, or Host OS (`br-mgmt` at `192.168.254.2`). Writes to `desired.vyos` are strictly restricted to authenticated management plane components.

### 7.5 Host-to-Guest Per-Device Credential Provisioning & Dynamic Zero-VM-Reboot Rotation Contract (`virtiofs` & Directory Mounts)
* **Secretless Golden Image Architectural Separation**:
  - **Golden Image (`/opt/olg/images/vyos-golden.qcow2`)**: 100% generic, immutable, and secretless across all appliance deployments. Contains system binaries, `vyos-nats-agent`, config renderer, `qemu-guest-agent` (pre-enabled via `systemctl enable qemu-guest-agent.service`), bootstrap management interface configuration (`mgmt0` at `192.168.254.1/24`), and systemd units.
  - **Persistent Host State**: Per-device identities, local appliance TLS certificates, and NATS JWT/NKey credentials (`/opt/olg/config/jwt/`, `/opt/olg/config/certs/`, `/etc/olg/client/config.json`, `/etc/olg/client/ucentral.creds`, `/etc/olg/client/ca.crt`, `/etc/olg/guest-secrets/vyos_agent.creds`, `/etc/olg/guest-secrets/agent.env`, `/etc/olg/guest-secrets/ca.crt`) generated during host provisioning and secured with strict host permissions (directories `0700 root:root`, secret files/keys `0600 root:root`, public certs `0644 root:root`).
* **Directory-Level Bind Mount Contract (Inode & Staging Safety)**:
  - **`nats-server`**: Host directory `/opt/olg/config` is bind-mounted to container directory `/etc/nats:ro`. Directory-level mounting prevents Linux kernel single-file inode pinning during `mv` replacement and ensures staged candidate files (`/opt/olg/config/jwt/*.tmp`, `/opt/olg/config/nats.conf.tmp`) are immediately visible inside `/etc/nats/` for validation.
  - **`ucentral-client`**: Host directory `/etc/olg/client` is bind-mounted to container directory `/etc/olg/client:ro` (or `/app/env:ro`). Directory-level mounting guarantees that `mv ucentral.creds.tmp ucentral.creds` updates the directory entry so that `docker restart ucentral-client` opens the new inode and re-reads `/etc/olg/client/config.json` without requiring container recreation.
  - **`vyos-router` (Guest Mount & Agent Channel Contract)**:
    - Libvirt exports `/etc/olg/guest-secrets` as a read-only `virtiofs` filesystem with tag `guest_secrets` (`<source dir='/etc/olg/guest-secrets'/><target dir='guest_secrets'/><readonly/>`).
    - Libvirt domain XML configures a dedicated VirtIO serial channel for QEMU Guest Agent (`<channel type='unix'><source mode='bind'/><target type='virtio' name='org.qemu.guest_agent.0'/></channel>`).
    - The golden image (`vyos-golden.qcow2`) contains mount point `/etc/olg/secrets` and guest `/etc/fstab` entry:
      ```
      guest_secrets /etc/olg/secrets virtiofs ro,_netdev,nofail 0 0
      ```
    - `vyos-nats-agent.service` defines `RequiresMountsFor=/etc/olg/secrets` to guarantee the systemd fstab mount generator mounts `guest_secrets` before the agent process initializes:
      ```ini
      [Unit]
      Description=VyOS NATS Configuration Agent
      RequiresMountsFor=/etc/olg/secrets
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      EnvironmentFile=/etc/olg/secrets/agent.env
      ExecStart=/usr/local/bin/vyos-nats-agent
      Restart=always
      RestartSec=5s
      ```
* **Dynamic Zero-VM-Reboot Credential Rotation Protocol (`tools/rotate_credentials.sh`)**:
  > [!IMPORTANT]
  > **Planned Automated Tool Execution Contract**: This 5-phase transaction sequence MUST be implemented by the planned host-side management tool `tools/rotate_credentials.sh` (`/opt/olg/tools/rotate_credentials.sh` on the host). The tool provides deterministic crash-consistency across sudden power interruptions via a persistent transaction journal (`/etc/olg/credential-generation.json`), automatic failure detection, live service reloading, and immediate automated rollback if any post-reload verification probe fails or times out. The planned CLI interface is designed for invocation via host CLI/SSH (`/opt/olg/tools/rotate_credentials.sh --client-creds ... --agent-creds ... --agent-env ...`).

  * **Persistent Transaction Journal (`/etc/olg/credential-generation.json`)**:
    - **Ownership & Permissions**: Mode `0600 root:root`.
    - **Schema & States**:
      ```json
      {
        "generation": 18,
        "previous_generation": 17,
        "state": "COMMITTED",
        "participants": [],
        "updated_at": "2026-09-24T10:00:00Z"
      }
      ```
    - **Lifecycle State Machine**:
      $$\text{COMMITTED } (N) \longrightarrow \text{PREPARED } (N+1) \longrightarrow \text{FILES\_INSTALLED } (N+1) \longrightarrow \text{VERIFIED } (N+1) \longrightarrow \text{COMMITTED } (N+1)$$
    - **Crash-Consistent Atomic Write & Durability Protocol**: All journal state transitions follow a strict 4-step durability protocol:
      $$\text{Write Temp File } (\texttt{/etc/olg/credential-generation.json.tmp}) \longrightarrow \text{fsync(temp\_fd)} \longrightarrow \text{rename(temp, journal)} \longrightarrow \text{fsync(dir\_fd } \texttt{/etc/olg}\text{)}$$
      Flushing the containing directory file descriptor (`/etc/olg/`) after `rename(2)` ensures that directory entry metadata is durably written to non-volatile storage, guaranteeing the journal state survives sudden host power failure without torn writes or lost directory links.

  * **Generation Manifest & Two-Tiered Rotation Coupling Contract**:
    NATS cryptographic rotation is strictly categorized into two transactional coupling tiers:
    1. **Tier 1 (Service & Account Credential Rotation)**:
       Rotates User credentials (`orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`, `agent.env`) and/or Application Account claims (`olg_account.jwt` + `resolver.conf` atomic bundle) under the stable Operator authority:
       $$\text{Tier 1 Manifest} \subseteq \{\texttt{olg\_account.jwt}, \texttt{resolver.conf}, \texttt{orchestrator.creds}, \texttt{ucentral.creds}, \texttt{vyos\_agent.creds}, \texttt{agent.env}\}$$
    2. **Tier 2 (Hierarchical Operator & Account Key Migration)**:
       If the root Operator signing identity is migrated (`operator.jwt`), the transaction strictly requires the complete atomic tree bundle: `operator.jwt` $\rightarrow$ (`sys_account.jwt`, `olg_account.jwt`) $\rightarrow$ `resolver.conf` $\rightarrow$ (`orchestrator.creds`, `ucentral.creds`, `vyos_agent.creds`, `agent.env`). Standalone replacement of `operator.jwt` without coordinated downstream account and user re-signing is strictly prohibited.

  1. **Phase 1: Candidate Staging & Cross-Validation**:
     - Candidate credentials and configuration files are staged with `.tmp` suffixes in their respective host directories:
       - `/opt/olg/config/jwt/operator.jwt.tmp` (if Operator updated)
       - `/opt/olg/config/jwt/olg_account.jwt.tmp` (if Account claims updated)
       - `/opt/olg/config/resolver.conf.tmp` (if Account resolver preload updated)
       - `/opt/olg/config/jwt/orchestrator.creds.tmp` (if Orchestrator creds updated)
       - `/etc/olg/client/ucentral.creds.tmp`
       - `/etc/olg/guest-secrets/vyos_agent.creds.tmp`
       - `/etc/olg/guest-secrets/agent.env.tmp`
     - **Participant Registration**: The tool compiles the exact list of staged files into a `participants` array (e.g. `["ucentral.creds", "vyos_agent.creds", "agent.env"]`).
     - **Preflight Cryptographic & Syntax Validation**:
       - Validates that `ucentral.creds.tmp`, `vyos_agent.creds.tmp`, and `orchestrator.creds.tmp` are valid decorated NATS credentials parsable by `jwt.ParseDecoratedJWT` and `jwt.ParseDecoratedNKey` via `tools/pki_init --mode verify-creds`.
       - If `olg_account.jwt.tmp` or `resolver.conf.tmp` are staged, verifies account JWT signatures against `operator.jwt` and validates `resolver.conf.tmp` memory resolver preload syntax.
     - **Failure Handling**: If any preflight validation check fails (non-zero exit code), all `.tmp` files are deleted, the transaction is aborted, and all active configuration files and running states remain 100% untouched.
  2. **Phase 2: Active Generation Snapshot & Journal `PREPARED` Transition**:
     - The tool snapshots every active artifact participating in the transaction (Generation $N$) to its corresponding `.prev` rollback copy:
       ```bash
       [ -f /opt/olg/config/jwt/operator.jwt.tmp ] && cp /opt/olg/config/jwt/operator.jwt /opt/olg/config/jwt/operator.jwt.prev
       [ -f /opt/olg/config/jwt/olg_account.jwt.tmp ] && cp /opt/olg/config/jwt/olg_account.jwt /opt/olg/config/jwt/olg_account.jwt.prev
       [ -f /opt/olg/config/resolver.conf.tmp ] && cp /opt/olg/config/resolver.conf /opt/olg/config/resolver.conf.prev
       [ -f /opt/olg/config/jwt/orchestrator.creds.tmp ] && cp /opt/olg/config/jwt/orchestrator.creds /opt/olg/config/jwt/orchestrator.creds.prev
       [ -f /etc/olg/client/ucentral.creds.tmp ] && cp /etc/olg/client/ucentral.creds /etc/olg/client/ucentral.creds.prev
       [ -f /etc/olg/guest-secrets/vyos_agent.creds.tmp ] && cp /etc/olg/guest-secrets/vyos_agent.creds /etc/olg/guest-secrets/vyos_agent.creds.prev
       [ -f /etc/olg/guest-secrets/agent.env.tmp ] && cp /etc/olg/guest-secrets/agent.env /etc/olg/guest-secrets/agent.env.prev
       sync
       ```
     - Tool transitions transaction journal to state **`PREPARED`** with `generation: $((N + 1))`, `previous_generation: $N`, and the populated `participants` array via atomic rename.
  3. **Phase 3: Apply Candidate Files & Journal `FILES_INSTALLED` Transition**:
     - The tool atomically moves all staged candidate files over their active target paths:
       ```bash
       [ -f /opt/olg/config/jwt/operator.jwt.tmp ] && mv /opt/olg/config/jwt/operator.jwt.tmp /opt/olg/config/jwt/operator.jwt
       [ -f /opt/olg/config/jwt/olg_account.jwt.tmp ] && mv /opt/olg/config/jwt/olg_account.jwt.tmp /opt/olg/config/jwt/olg_account.jwt
       [ -f /opt/olg/config/resolver.conf.tmp ] && mv /opt/olg/config/resolver.conf.tmp /opt/olg/config/resolver.conf
       [ -f /opt/olg/config/jwt/orchestrator.creds.tmp ] && mv /opt/olg/config/jwt/orchestrator.creds.tmp /opt/olg/config/jwt/orchestrator.creds
       [ -f /etc/olg/client/ucentral.creds.tmp ] && mv /etc/olg/client/ucentral.creds.tmp /etc/olg/client/ucentral.creds
       [ -f /etc/olg/guest-secrets/vyos_agent.creds.tmp ] && mv /etc/olg/guest-secrets/vyos_agent.creds.tmp /etc/olg/guest-secrets/vyos_agent.creds
       [ -f /etc/olg/guest-secrets/agent.env.tmp ] && mv /etc/olg/guest-secrets/agent.env.tmp /etc/olg/guest-secrets/agent.env
       sync
       ```
     - Tool transitions transaction journal to state **`FILES_INSTALLED`** with `generation: $((N + 1))` via atomic rename.
  4. **Phase 4: Reload & Deterministic In-Flight Verification Probes (with Defined Timeouts)**:
     - **4a. Correlated NATS Live Reload (if Account JWT / resolver.conf modified)**:
       - If `resolver.conf` or Account JWT was modified, capture timestamp cursor: `RELOAD_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")`.
       - Signal NATS in-memory reload: `docker exec nats-server nats-server --signal reload`.
       - **Probe**: Verifies `docker exec` exit code `0` and confirms log entry `Reloaded server configuration` in `docker logs --since "$RELOAD_START" nats-server` within a 5-second timeout window.
     - **4b. Host Orchestrator Credential & NATS API Verification Probe (Probe 0)**:
       - Validates that newly installed `orchestrator.creds` can authenticate and issue JetStream requests against NATS:
         `tools/kv_config_init --creds /opt/olg/config/jwt/orchestrator.creds --ca /opt/olg/config/certs/ca.crt --server tls://127.0.0.1:4222 --probe-only`
       - Guarantees `exitcode: 0` before proceeding to microservice client checks.
     - **4c. Cloud Client Restart & Auth Verification (Probe 1)**:
       - Tool restarts client container: `docker restart ucentral-client` (re-reads mounted `/etc/olg/client/config.json` and `/etc/olg/client/ucentral.creds` on start).
       - **Probe**: Polls `docker inspect -f '{{.State.Running}}' ucentral-client` (verifies `true`) and scans container logs to confirm successful NATS JetStream TLS connection with zero `Authorization Violation` or authentication error entries within a 5-second timeout window.
     - **4d. VyOS Agent Restart & QGA Execution-Status Verification (Probe 2 & 3)**:
       - Tool executes QGA ping: `virsh qemu-agent-command vyos-router '{"execute":"guest-ping"}'`.
       - Tool invokes guest restart:
         ```bash
         RES=$(virsh qemu-agent-command vyos-router '{"execute":"guest-exec", "arguments":{"path":"systemctl", "arg":["restart","vyos-nats-agent.service"], "capture-output":true}}')
         PID=$(echo "$RES" | jq -r '.return.pid')
         ```
       - **Probe 2 (QGA Status Polling)**: Tool polls `guest-exec-status` every 500ms (up to 10s timeout):
         ```bash
         virsh qemu-agent-command vyos-router "{\"execute\":\"guest-exec-status\", \"arguments\":{\"pid\":$PID}}"
         ```
         Guarantees `exited: true` and `exitcode: 0`.
       - **Probe 3 (Authoritative Control Plane Telemetry Heartbeat)**: Verifies `systemctl is-active vyos-nats-agent.service` returns `active` and `vyos-nats-agent` publishes healthy telemetry on `health.>` / `status.>` with **zero VM reboot**, **zero kernel re-initialization**, and **zero routing/forwarding plane downtime**.
  5. **Phase 5: Transaction Finalization OR Automatic Rollback & Verification**:
     - **Commit Path (All Phase 4 Probes Succeeded)**:
       - Tool transitions journal to state **`VERIFIED`** and immediately commits to state **`COMMITTED`** (`{"generation": $((N + 1)), "previous_generation": $N, "state": "COMMITTED", "participants": []}`).
       - Deletes all rollback snapshot files (`*.prev`):
         ```bash
         rm -f /opt/olg/config/jwt/*.prev /opt/olg/config/*.prev /etc/olg/client/*.prev /etc/olg/guest-secrets/*.prev
         ```
       - Exits cleanly (`exit 0`).
     - **Rollback Path & Post-Rollback Deterministic Verification (Any Forward Probe Failed or Timed Out)**:
       - If any forward reload, QGA exit status (`exitcode != 0`), or authentication probe fails or times out during Phase 4, the tool initiates an immediate automated rollback to Generation $N$:
         1. **Journal `ROLLBACK_IN_PROGRESS` Transition**: Atomically sets state to `ROLLBACK_IN_PROGRESS` (`{"generation": $((N + 1)), "previous_generation": $N, "state": "ROLLBACK_IN_PROGRESS", "participants": [...]}`). The journal maintains `generation: N+1` and `previous_generation: N` throughout the rollback attempt, guaranteeing that any cold-boot power loss during rollback recovery deterministically restores the known-good base Generation $N$ (`previous_generation`).
         2. **Participant-Selective File Restoration**: Moves only the snapshots of participating files back over active files:
            ```bash
            for participant in "${PARTICIPANTS[@]}"; do
              case "$participant" in
                "operator.jwt")       [ -f /opt/olg/config/jwt/operator.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/operator.jwt.prev /opt/olg/config/jwt/operator.jwt ;;
                "sys_account.jwt")    [ -f /opt/olg/config/jwt/sys_account.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/sys_account.jwt.prev /opt/olg/config/jwt/sys_account.jwt ;;
                "olg_account.jwt")    [ -f /opt/olg/config/jwt/olg_account.jwt.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/olg_account.jwt.prev /opt/olg/config/jwt/olg_account.jwt ;;
                "resolver.conf")      [ -f /opt/olg/config/resolver.conf.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/resolver.conf.prev /opt/olg/config/resolver.conf ;;
                "orchestrator.creds") [ -f /opt/olg/config/jwt/orchestrator.creds.prev ] && cp --preserve=mode,ownership,timestamps /opt/olg/config/jwt/orchestrator.creds.prev /opt/olg/config/jwt/orchestrator.creds ;;
                "ucentral.creds")     [ -f /etc/olg/client/ucentral.creds.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/client/ucentral.creds.prev /etc/olg/client/ucentral.creds ;;
                "vyos_agent.creds")   [ -f /etc/olg/guest-secrets/vyos_agent.creds.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/guest-secrets/vyos_agent.creds.prev /etc/olg/guest-secrets/vyos_agent.creds ;;
                "agent.env")          [ -f /etc/olg/guest-secrets/agent.env.prev ] && cp --preserve=mode,ownership,timestamps /etc/olg/guest-secrets/agent.env.prev /etc/olg/guest-secrets/agent.env ;;
              esac
            done
            sync
            ```
         3. **Rollback Service Restart / Reload**:
            - If `resolver.conf` or Account JWT was updated, signal NATS in-memory reload back to Generation $N$:
              ```bash
              docker exec nats-server nats-server --signal reload
              ```
            - Restart client: `docker restart ucentral-client`.
            - Invoke guest agent restart via QGA:
              ```bash
              virsh qemu-agent-command vyos-router '{"execute":"guest-ping"}'
              RES=$(virsh qemu-agent-command vyos-router '{"execute":"guest-exec", "arguments":{"path":"systemctl", "arg":["restart","vyos-nats-agent.service"], "capture-output":true}}')
              PID=$(echo "$RES" | jq -r '.return.pid')
              ```
         4. **Deterministic Rollback Verification Probes (Mirroring Phase 4 Probes)**:
            - **Rollback Probe 0 (Orchestrator Probe)**: `tools/kv_config_init --creds /opt/olg/config/jwt/orchestrator.creds --ca /opt/olg/config/certs/ca.crt --server tls://127.0.0.1:4222 --probe-only` returns `0`.
            - **Rollback Probe 1 (Cloud Client Auth Recovery)**: Verifies `docker inspect -f '{{.State.Running}}' ucentral-client` == `true` and checks container logs for successful authenticated NATS reconnection with zero `Authorization Violation` entries within 5 seconds.
            - **Rollback Probe 2 (QGA Agent Exec-Status)**: Polls QGA `guest-exec-status` for `$PID` every 500ms (up to 10s) to verify `exited: true` and `exitcode: 0`.
            - **Rollback Probe 3 (Service Active & Telemetry Heartbeat)**: Verifies `systemctl is-active vyos-nats-agent.service` returns `active` and confirms valid NATS telemetry on `health.>` / `status.>` within 10 seconds.
         5. **Journal State Reconciliation & Rollback Termination**:
            - **Successful Rollback Path**: If all rollback verification probes succeed, Generation $N$ operational state is verified fully restored.
              - Atomically updates journal to state **`COMMITTED`**: `{"generation": $N, "previous_generation": $((N - 1)), "state": "COMMITTED", "participants": []}`.
              - Deletes rollback snapshot files: `rm -f /opt/olg/config/jwt/*.prev /opt/olg/config/*.prev /etc/olg/client/*.prev /etc/olg/guest-secrets/*.prev`.
              - Logs audit warning event `CREDENTIAL_ROTATION_ABORTED_ROLLBACK_SUCCESSFUL` and exits with `exit 1` (rotation failure, active system healthy).
            - **Failed Rollback Escalation Path (Any Rollback Probe Failed or Timed Out)**:
              - Atomically updates journal to state **`ROLLBACK_FAILED`**: `{"generation": $((N + 1)), "previous_generation": $N, "state": "ROLLBACK_FAILED", "participants": [...], "updated_at": "<ISO8601>"}`.
              - **Snapshot Retention Invariant**: In `ROLLBACK_FAILED`, **all `*.prev` snapshot files are strictly preserved** (unlinking prohibited) to provide human operators with forensic recovery material.
              - Emits critical alert `CRITICAL_ALERT_CONTROL_PLANE_DEGRADED_ROLLBACK_FAILED` to systemd journal / syslog with failing probe diagnostics.
              - Writes `/var/run/olg/status.json` (`control_plane_status: "DEGRADED"`).
              - Strictly enforces **Dataplane Preservation Guarantee** (zero host reboot, zero VM reset, zero dataplane routing interruption).
### 7.6 Cloud-Managed Configuration Non-Persistence Contract (`/config/config.boot`)
* **In-Memory Running Configuration Enforcement**:
  - The configuration renderer MUST commit cloud-managed configuration changes received from NATS JetStream to the active running VyOS configuration (`commit`).
  - The renderer MUST NOT save cloud-managed configuration to the guest boot configuration file (`/config/config.boot`).
* **Stateless Clean Boot Guarantee**: On every cold boot or hypervisor recovery, VyOS boots cleanly from its immutable baseline state, initializes the management network (`mgmt0`), and fetches the authoritative desired state fresh from persistent NATS JetStream KV storage (`desired.vyos`), preventing state drift and configuration pollution on the transient disk.

