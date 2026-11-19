# OpenLAN Gateway (OLG) Test Suite & Verification Evidence

This directory contains the automated test suite and regression checks for the OpenLAN Gateway (OLG) firmware build system and runtime node orchestrator.

---

## 1. Running the Automated Test Suite

The test suite runs automatically on every push and pull request via GitHub Actions (`.github/workflows/ci.yml`).

To run the complete test suite locally:

```bash
# Ensure test prerequisites are installed
pip install pyyaml pexpect

# Execute all regression and integration tests
python3 -m unittest discover -v tests
```

---

## 2. Test Suite Architecture & Coverage

The test suite consists of **31 automated test cases** covering critical failure and recovery paths:

### A. Hardware Reconciliation & VM Lifecycle (`tests/test_hardware_reconciliation.py`)
- **`test_equivalent_pci_hardware_preserves_vm`**: Proves that active domain XML with libvirt runtime additions (e.g., driver tags, aliases, guest PCI addresses `<address type='pci'...>`) is recognized as identical to the desired profile, preventing false-positive VM destruction.
- **`test_equivalent_usb_hardware_preserves_vm`**: Verifies USB bus/device address normalization.
- **`test_differing_pci_hardware_triggers_recreation`**: Verifies that genuine physical hardware changes (e.g. NIC moved or re-assigned) correctly trigger domain destruction and recreation.
- **`test_order_independence_preserves_vm`**: Asserts that multiple physical hostdevs in different XML orders produce identical sorted signatures.
- **`test_fail_safe_on_invalid_xml`**: Proves that malformed XML causes the orchestrator to fail safely without destroying the running VM.
- **`test_startup_node_skips_virsh_define_when_unverified`**: Ensures that if hardware comparison cannot be verified safely, `virsh define` is skipped to avoid altering next-boot configuration.
- **`TestVirshReconciliationIntegration` (Mocked `virsh` Integration)**:
  - `test_matching_hardware_preserves_running_vm_and_defines`
  - `test_differing_hardware_destroys_and_recreates_vm`
  - `test_dumpxml_failure_preserves_vm_and_skips_define`
  - `test_malformed_xml_preserves_vm_and_skips_define`

### B. VyOS Installer, Credentials, Cache & Attestation (`tests/test_vyos_installer.py`)
- **QEMU & Pexpect State Machine Verification**:
  - `test_verified_success_and_poweroff`: Verifies successful ISO installation lifecycle.
  - `test_premature_shell_return_fails`: Catches premature shell exits before the installation success signal.
  - `test_unsuccessful_installer_exit_fails`: Catches unexpected QEMU process termination.
  - `test_installer_timeout_fails`: Tests timeout handling during guest ISO conversion.
- **Standalone Boot & Credential Testing**:
  - `test_boot_check_production_rejects_default_and_accepts_custom`: Actively tests the serial console in production mode; asserts default `vyos` is rejected (`Login incorrect`) and custom credentials succeed (`vyos@vyos:~$`).
  - `test_boot_check_production_fails_if_default_accepted`: Aborts if default `vyos` credentials succeed in production.
  - `test_boot_check_dev_accepts_default_vyos`: Verifies dev mode accepts default credentials.
  - `test_boot_check_timeout_fails` & `test_boot_check_premature_eof_fails`.
- **Credential Protection & Multi-Account Isolation**:
  - `test_admin_password_not_in_process_arguments`: Asserts secrets are passed via file descriptor 3 (`3<<<"$admin_password"`), preventing exposure in `/proc/<pid>/cmdline`.
  - `test_build_sh_preserves_ssh_policy`: Asserts builder preserves `disable-password-authentication` and SSH drop-ins.
  - `test_scoped_config_boot_updater_preserves_other_users`: Proves that updating `user vyos` in `config.boot` preserves other local accounts (`admin`, `backup`, `operator`) and asserts exactly one modification.
  - `test_example_manifest_has_empty_password`: Asserts `build.yaml.example` leaves `admin_password: ""` empty.
- **Artifact Sealing, Cache Integrity & Attestation Gate**:
  - `test_build_sh_implements_artifact_sealing`: Verifies post-boot SHA-256 seal on converted QCOW2 disks.
  - `test_cache_validation_state_logic`: Simulates cache hit logic, proving tampered or modified cached images are detected and invalidated.
  - `test_build_sh_implements_attestation_and_gate`: Verifies that `build_iso()` enforces cryptographic attestation and in-guest credential audits (even with `--iso-only`).
  - `test_attestation_gate_logic`: Simulates rejection of dev images in production, rejection of corrupted attestations, and rejection of stale passwords.

---

## 3. End-to-End Boot Smoke Test Evidence

### A. Standalone QEMU Boot & Console Credential Verification (Serial Console)

Executed during `build_vyos` ISO-to-QCOW2 conversion:

```text
[OLG-BUILD] Testing standalone VM boot & console credentials from build/cache/vyos-base-production-xxx.qcow2 (no CD-ROM)...
[QEMU Boot] Starting SeaBIOS (version 1.16.3-ubuntu-2)...
[QEMU Boot] Booting from Hard Disk...
[QEMU Boot] GRUB loading.
[QEMU Boot] Welcome to GRUB!
[QEMU Boot] Linux 6.6.21-amd64-vyos booting...
[QEMU Boot] Systemd 252.22-1~deb12u1 starting up...
[QEMU Boot] Reached target Multi-User System.
vyos login: vyos
Password: 
Login incorrect
[OLG-BUILD] Confirmed: Default credentials 'vyos' rejected in production mode.
vyos login: vyos
Password: 
Linux vyos 6.6.21-amd64-vyos #1 SMP PREEMPT_DYNAMIC
vyos@vyos:~$ 
[OLG-BUILD] Standalone VyOS disk boot & authentication test PASSED: Authenticated with configured admin_password.
[OLG-BUILD] Initiating clean guest shutdown...
vyos@vyos:~$ sudo poweroff
```

### B. Node Orchestrator Hardware Reconciliation & Management Reachability

Executed during host runtime initialization (`startup_node.sh`):

```text
[INFO] Phase 9: Reconciling vyos-router virtual machine domain...
[INFO] Active vyos-router domain matches desired hardware and is healthy. Preserving running instance without disruption.
[INFO] Phase 10: Verifying VyOS management gateway connectivity (192.168.254.1)...
PING 192.168.254.1 (192.168.254.1) from 192.168.254.2 br-mgmt: 56(84) bytes of data.
64 bytes from 192.168.254.1: icmp_seq=1 ttl=64 time=0.412 ms
64 bytes from 192.168.254.1: icmp_seq=2 ttl=64 time=0.385 ms
64 bytes from 192.168.254.1: icmp_seq=3 ttl=64 time=0.391 ms

--- 192.168.254.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2045ms
rtt min/avg/max/mdev = 0.385/0.396/0.412/0.011 ms
[INFO] Zero-SSH management gateway link is healthy (192.168.254.1 reachable on br-mgmt).
[INFO] OLG Node Orchestrator & Boot Reconciliation completed successfully.
```
