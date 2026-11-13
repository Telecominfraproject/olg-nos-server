#!/usr/bin/env python3
"""
Unit tests for VyOS ISO automated installer state machine and verification logic.
Tests premature shell return, unsuccessful installer exit, timeout, and successful completion.
"""

import unittest
import sys
import re

PATTERNS = [
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
    "TIMEOUT",                                              # 12
    "EOF"                                                   # 13
]

class MockPexpectChild:
    """Mock pexpect spawn object that delivers simulated sequence of terminal events."""
    def __init__(self, events):
        self.events = list(events)
        self.sent = []
        self.killed = False

    def expect(self, patterns, timeout=60):
        while self.events:
            event = self.events.pop(0)
            if isinstance(event, int):
                return event
            for i, pat in enumerate(patterns):
                if isinstance(pat, str) and re.search(pat, event):
                    return i
        return 13  # EOF

    def send(self, data):
        self.sent.append(data)

    def kill(self, sig):
        self.killed = True


def run_installer_state_machine(child, admin_password="test_password"):
    """
    Executes the installer state machine against a child process.
    Returns (install_completed, install_success_seen).
    Raises RuntimeError on premature exit, failure, or timeout.
    """
    install_started = False
    install_success_seen = False
    install_completed = False
    iterations = 0

    while iterations < 50:
        iterations += 1
        idx = child.expect(PATTERNS, timeout=10)

        if idx == 0:  # vyos login:
            child.send("vyos\r")
        elif idx == 1:  # Password prompt
            if not install_started:
                child.send("vyos\r")
            else:
                child.send(f"{admin_password}\r")
        elif idx == 2:  # Shell prompt
            if not install_started:
                install_started = True
                child.send("install image\r")
            else:
                if not install_success_seen:
                    child.kill(9)
                    raise RuntimeError("Installer exited back to shell prematurely without verified success signal")
                install_completed = True
                child.send("sudo poweroff\r")
                break
        elif idx == 3:  # [y/N]
            child.send("y\r")
        elif idx in (4, 8, 9):
            child.send(f"{admin_password}\r")
        elif idx in (5, 11):
            child.send("\r")
        elif idx == 6:  # Success notification
            install_success_seen = True
        elif idx == 7:
            child.send("Auto\r")
        elif idx == 10:
            child.send("\r")
        elif idx == 12:  # TIMEOUT
            child.kill(9)
            raise TimeoutError("Installer timed out waiting for expected pattern")
        elif idx == 13:  # EOF
            if install_completed and install_success_seen:
                break
            child.kill(9)
            raise RuntimeError("QEMU terminated prematurely before installation finished")

    if not install_completed or not install_success_seen:
        raise AssertionError("Installation assertion failed (incomplete or unverified)")

    return install_completed, install_success_seen


BOOT_PATTERNS = [
    r"(vyos login:|login:)\s*",           # 0
    r"[Pp]assword:\s*",                  # 1
    r"vyos@vyos:.*[#$]\s*",              # 2
    r"(Login incorrect|invalid login)",  # 3
    "TIMEOUT",                           # 4
    "EOF",                               # 5
]

def run_boot_check_state_machine(child, admin_password="vyos"):
    default_rejected = False
    auth_success = False

    while True:
        idx = child.expect(BOOT_PATTERNS, timeout=90)
        if idx == 0:  # login:
            child.send("vyos\r")
        elif idx == 1:  # Password:
            if admin_password != "vyos" and not default_rejected:
                child.send("vyos\r")
            else:
                child.send(f"{admin_password}\r")
        elif idx == 2:  # vyos@vyos:~$
            if admin_password != "vyos" and not default_rejected:
                child.kill(9)
                raise AssertionError("Security Assertion Failed: Default credentials 'vyos' were accepted in production mode")
            auth_success = True
            child.send("sudo poweroff\r")
            child.kill(9)
            return True
        elif idx == 3:  # Login incorrect
            default_rejected = True
        elif idx == 4:  # TIMEOUT
            child.kill(9)
            raise TimeoutError("Timed out waiting for login/shell prompt")
        elif idx == 5:  # EOF
            if auth_success:
                return True
            child.kill(9)
            raise RuntimeError("QEMU terminated prematurely without authenticating")


class TestVyOSInstallerStateMachine(unittest.TestCase):
    def test_premature_shell_return_fails(self):
        """Verify that returning to shell before success signal raises an error and kills QEMU."""
        # Simulated sequence: boots, logs in, runs install image, but wizard crashes back to shell
        events = [
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",            # Triggers install image
            "Some fatal python traceback...",
            "vyos@vyos:~$ ",            # Premature shell return!
        ]
        child = MockPexpectChild(events)
        with self.assertRaises(RuntimeError) as ctx:
            run_installer_state_machine(child)
        self.assertIn("prematurely without verified success signal", str(ctx.exception))
        self.assertTrue(child.killed)

    def test_unsuccessful_installer_exit_fails(self):
        """Verify that premature EOF before success signal raises an error."""
        events = [
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",
            13,  # Unexpected EOF
        ]
        child = MockPexpectChild(events)
        with self.assertRaises(RuntimeError) as ctx:
            run_installer_state_machine(child)
        self.assertIn("terminated prematurely", str(ctx.exception))
        self.assertTrue(child.killed)

    def test_installer_timeout_fails(self):
        """Verify that timeout triggers TimeoutError and process kill."""
        events = [
            "vyos login: ",
            12,  # TIMEOUT
        ]
        child = MockPexpectChild(events)
        with self.assertRaises(TimeoutError):
            run_installer_state_machine(child)
        self.assertTrue(child.killed)

    def test_verified_success_and_poweroff(self):
        """Verify that receiving the success signal followed by shell return successfully completes."""
        events = [
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",
            "What would you like to set the vyos admin password to? (Default: vyos): ",
            "The image installed successfully; you can reboot now.",
            "vyos@vyos:~$ ",
        ]
        child = MockPexpectChild(events)
        completed, success_seen = run_installer_state_machine(child, admin_password="secret_pass")
        self.assertTrue(completed)
        self.assertTrue(success_seen)
        self.assertIn("sudo poweroff\r", child.sent)

    def test_boot_check_dev_accepts_default_vyos(self):
        """Verify that standalone boot in dev mode authenticates with default vyos password."""
        events = [
            "GRUB loading...",
            "Linux kernel 6.6.x booting...",
            "Systemd starting multi-user target...",
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",
        ]
        child = MockPexpectChild(events)
        res = run_boot_check_state_machine(child, admin_password="vyos")
        self.assertTrue(res)
        self.assertIn("vyos\r", child.sent)
        self.assertIn("sudo poweroff\r", child.sent)

    def test_boot_check_production_rejects_default_and_accepts_custom(self):
        """Verify that production boot check rejects default 'vyos' and authenticates with custom password."""
        events = [
            "GRUB loading...",
            "vyos login: ",
            "Password: ",
            "Login incorrect",
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",
        ]
        child = MockPexpectChild(events)
        res = run_boot_check_state_machine(child, admin_password="CustomSecret2026!")
        self.assertTrue(res)
        # Asserts first password attempt was 'vyos\r', second was 'CustomSecret2026!\r'
        self.assertIn("vyos\r", child.sent)
        self.assertIn("CustomSecret2026!\r", child.sent)
        self.assertIn("sudo poweroff\r", child.sent)

    def test_boot_check_production_fails_if_default_accepted(self):
        """Verify that production boot check aborts if default 'vyos' credentials are accepted."""
        events = [
            "vyos login: ",
            "Password: ",
            "vyos@vyos:~$ ",  # Wrong: should have rejected vyos!
        ]
        child = MockPexpectChild(events)
        with self.assertRaises(AssertionError):
            run_boot_check_state_machine(child, admin_password="CustomSecret2026!")

    def test_boot_check_timeout_fails(self):
        """Verify that standalone boot timeout raises TimeoutError."""
        child = MockPexpectChild([4])
        with self.assertRaises(TimeoutError):
            run_boot_check_state_machine(child)

    def test_boot_check_premature_eof_fails(self):
        """Verify that standalone boot crash / premature EOF raises RuntimeError."""
        child = MockPexpectChild([5])
        with self.assertRaises(RuntimeError):
            run_boot_check_state_machine(child)


class TestVyosKeaDhcpHooks(unittest.TestCase):
    """Verify that build.sh embeds automated Kea DHCP restart postconfig and commit hooks."""

    def test_build_script_has_kea_hooks(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        self.assertTrue(build_sh_path.exists(), "build.sh should exist")
        content = build_sh_path.read_text()

        # Check postconfig bootup script restart trigger
        self.assertIn("systemctl is-active isc-kea-dhcp4-server", content)
        self.assertIn("systemctl restart isc-kea-dhcp4-server", content)

        # Check commit hook creation
        self.assertIn("commit/post-hooks.d/10-restart-kea", content)

        # Check build validation assertion
        self.assertIn("Kea DHCP raw socket rebind hooks missing", content)


class TestQemuAcceleratorResolution(unittest.TestCase):
    """Verify that QEMU accelerator resolution supports KVM and TCG fallback, and is scoped correctly in build.sh."""

    def test_accelerator_scope_in_build_sh(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        self.assertTrue(build_sh_path.exists())
        content = build_sh_path.read_text()

        # Ensure convert_vyos_iso_to_qcow2 defines accel before both Python heredocs
        conv_func = content[content.find("convert_vyos_iso_to_qcow2()"):content.find("build_vyos_disk()")]
        self.assertIn('local accel="tcg"', conv_func)
        self.assertIn('accel="kvm"', conv_func)

        # Ensure both invocations receive $accel in the same function scope
        self.assertIn('python3 - "$iso_path" "$output_qcow2" "$accel" 3<<<"$admin_password"', conv_func)
        self.assertIn('python3 - "$output_qcow2" "$accel"', conv_func)

    def test_admin_password_not_in_process_arguments(self):
        """Verify that admin_password is passed via FD 3 and not exposed in process arguments."""
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()
        conv_func = content[content.find("convert_vyos_iso_to_qcow2()"):content.find("build_vyos_disk()")]

        # Must not pass admin_password as a positional command-line argument
        self.assertNotIn('"$accel" "$admin_password"', conv_func)
        # Must pass via restricted file descriptor 3
        self.assertIn('3<<<"$admin_password"', conv_func)
        self.assertIn('os.fdopen(3', conv_func)

    def test_kvm_and_tcg_command_args(self):
        def build_cmd(accel):
            cmd = ["qemu-system-x86_64"]
            if accel == "kvm":
                cmd.extend(["-accel", "kvm", "-accel", "tcg"])
            else:
                cmd.extend(["-accel", "tcg"])
            return cmd

        kvm_cmd = build_cmd("kvm")
        self.assertIn("-accel", kvm_cmd)
        self.assertEqual(kvm_cmd[kvm_cmd.index("-accel") + 1], "kvm")

        tcg_cmd = build_cmd("tcg")
        self.assertIn("-accel", tcg_cmd)
        self.assertEqual(tcg_cmd[tcg_cmd.index("-accel") + 1], "tcg")


class TestSshPolicyPreservation(unittest.TestCase):
    """Verify that build.sh preserves SSH policy and does not strip disable-password-authentication or drop-ins."""

    def test_build_sh_preserves_ssh_policy(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()

        # Must not unconditionally delete disable-password-authentication
        self.assertNotIn("disable-password-authentication/d", content)

        # Must not unconditionally delete sshd_config.d drop-ins
        self.assertNotIn("rm -f /etc/ssh/sshd_config.d", content)
        self.assertNotIn("rm -f \"$root_target/etc/ssh/sshd_config.d", content)


class TestProductionCredentialValidation(unittest.TestCase):
    """Verify that build.sh enforces expected credential fields and cryptographically verifies password hashes."""

    def test_build_sh_requires_and_verifies_credentials(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()

        # Must fail if config.boot or shadow files are absent
        self.assertIn("Required VyOS configuration file 'config.boot' not found", content)
        self.assertIn("Required user credentials database '/etc/shadow' not found", content)

        # Must fail if user 'vyos' is missing
        self.assertIn("Required administrative user 'vyos' missing from", content)
        self.assertIn("Expected exactly 1 'system login user vyos' encrypted-password", content)

        # Must assert write success and strictly scope config.boot to user vyos
        self.assertIn("Failed to update encrypted-password for user 'vyos' in", content)
        self.assertIn("Failed to write password hash for user 'vyos' in", content)
        self.assertIn("update_vyos_config_boot_password", content)
        self.assertIn("extract_vyos_config_boot_password", content)

        # Must verify stored hash against configured admin_password
        self.assertIn('openssl passwd -6 -salt "$salt" "$admin_password"', content)
        self.assertIn('openssl passwd -6 -salt "$bsalt" "$admin_password"', content)
        self.assertIn('Stored shadow hash in $shf does not match configured admin_password', content)
        self.assertIn('Stored config.boot hash for user \'vyos\' in $CFG_BOOT does not match configured admin_password', content)

        # Must reject default 'vyos' credentials in production
        self.assertIn('openssl passwd -6 -salt "$salt" "vyos"', content)
        self.assertIn('openssl passwd -6 -salt "$bsalt" "vyos"', content)

        # Admin password must be read from manifest
        self.assertIn("admin_password=$(jq -r '.base_image.admin_password // .admin_password // empty' <<< \"$vyos_json\")", content)

    def test_scoped_config_boot_updater_preserves_other_users(self):
        """Verify that updating user vyos password in config.boot preserves all other user accounts."""
        import tempfile, subprocess, sys, pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()

        sample_config = """system {
    host-name vyos
    login {
        user admin {
            authentication {
                encrypted-password '$6$adminsalt$adminhash'
            }
        }
        user vyos {
            authentication {
                encrypted-password '$6$vyossalt$oldvyoshash'
                plaintext-password ''
            }
        }
        user backup {
            authentication {
                encrypted-password '$6$backupsalt$backuphash'
            }
        }
    }
}
"""
        with tempfile.NamedTemporaryFile("w+", delete=False) as tf:
            tf.write(sample_config)
            tf.flush()
            tmp_path = tf.name

        try:
            # Run bash helper via build.sh functions
            test_script = f"""
source <(sed -n '/update_vyos_config_boot_password()/,/^}}/p' "{build_sh_path}")
source <(sed -n '/extract_vyos_config_boot_password()/,/^}}/p' "{build_sh_path}")
update_vyos_config_boot_password "{tmp_path}" '$6$newsalt$NEWVYOSHASH'
extract_vyos_config_boot_password "{tmp_path}"
"""
            res = subprocess.run(["bash", "-c", test_script], capture_output=True, text=True, check=True)
            new_hash = res.stdout.strip()
            self.assertEqual(new_hash, "$6$newsalt$NEWVYOSHASH")

            updated_content = pathlib.Path(tmp_path).read_text()
            # Assert other user accounts were NOT modified
            self.assertIn("encrypted-password '$6$adminsalt$adminhash'", updated_content)
            self.assertIn("encrypted-password '$6$backupsalt$backuphash'", updated_content)
            # Assert vyos was modified exactly once
            self.assertIn("encrypted-password '$6$newsalt$NEWVYOSHASH'", updated_content)
            self.assertNotIn("oldvyoshash", updated_content)
        finally:
            pathlib.Path(tmp_path).unlink(missing_ok=True)


    def test_example_manifest_has_empty_password(self):
        """Verify that build.yaml.example does not provide a hardcoded password that passes production validation."""
        import pathlib, yaml
        example_path = pathlib.Path(__file__).resolve().parent.parent / "build.yaml.example"
        with open(example_path) as f:
            data = yaml.safe_load(f)
        admin_pass = data.get("vyos", {}).get("base_image", {}).get("admin_password")
        self.assertEqual(admin_pass, "", "build.yaml.example must leave admin_password empty to prevent shared default credentials")


class TestCachedQcow2Integrity(unittest.TestCase):
    """Verify that build.sh cryptographically seals converted QCOW2 caches and invalidates modified images."""

    def test_build_sh_implements_artifact_sealing(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()

        # Must record SHA-256 after standalone boot
        self.assertIn('sha256sum "$cached_base" | awk \'{print $1}\'', content)
        self.assertIn('echo "$act_base_qcow2_sha" > "${cached_base}.sha256"', content)
        self.assertIn('qcow2_sha=${act_base_qcow2_sha}', content)

        # Must verify SHA-256 before reusing cache
        self.assertIn('actual_cached_sha=$(sha256sum "$cached_base" | awk \'{print $1}\')', content)
        self.assertIn('if [ "$actual_cached_sha" = "$recorded_sha" ]; then', content)

        # Must invalidate and delete cache on checksum mismatch
        self.assertIn('Cached converted disk SHA-256 artifact checksum mismatch', content)
        self.assertIn('rm -f "$cached_base" "$cached_base_sig" "${cached_base}.sha256"', content)

    def test_cache_validation_state_logic(self):
        """Simulate cache validation logic against clean and modified QCOW2 files."""
        import tempfile, hashlib

        with tempfile.TemporaryDirectory() as tmp_dir:
            import pathlib
            tmp_path = pathlib.Path(tmp_dir)
            cached_base = tmp_path / "vyos-base-test.qcow2"
            cached_sig = tmp_path / "vyos-base-test.sig"
            cached_sha = tmp_path / "vyos-base-test.qcow2.sha256"

            # 1. Setup clean cache
            clean_content = b"original-valid-qcow2-bytes"
            cached_base.write_bytes(clean_content)
            clean_sha = hashlib.sha256(clean_content).hexdigest()
            cached_sha.write_text(clean_sha + "\n")
            expected_sig_base = "iso_sha_123 size=10G mode=production pass_sha=456"
            cached_sig.write_text(f"{expected_sig_base} qcow2_sha={clean_sha}\n")

            def verify_cache(disk_path, sig_path, sha_path, expected_base, mock_qemu_ok=True):
                if not (disk_path.exists() and sig_path.exists() and sha_path.exists()):
                    return False, "missing_files"
                rec_sig = sig_path.read_text().strip()
                rec_sha = sha_path.read_text().strip().split()[0]
                exp_full = f"{expected_base} qcow2_sha={rec_sha}"
                if rec_sig != exp_full:
                    return False, "sig_mismatch"
                act_sha = hashlib.sha256(disk_path.read_bytes()).hexdigest()
                if act_sha != rec_sha:
                    return False, "sha_mismatch"
                if not mock_qemu_ok:
                    return False, "qemu_check_failed"
                return True, "valid"

            # Valid cache succeeds
            ok, reason = verify_cache(cached_base, cached_sig, cached_sha, expected_sig_base)
            self.assertTrue(ok)
            self.assertEqual(reason, "valid")

            # Tampered disk fails sha_mismatch
            cached_base.write_bytes(b"tampered-modified-bytes")
            ok, reason = verify_cache(cached_base, cached_sig, cached_sha, expected_sig_base)
            self.assertFalse(ok)
            self.assertEqual(reason, "sha_mismatch")

            # Missing sha file fails
            cached_sha.unlink()
            ok, reason = verify_cache(cached_base, cached_sig, cached_sha, expected_sig_base)
            self.assertFalse(ok)
            self.assertEqual(reason, "missing_files")


class TestProductionIsoAttestationGate(unittest.TestCase):
    """Verify that build_iso enforces image attestation and rejects dev or unverified images in production mode."""

    def test_build_sh_implements_attestation_and_gate(self):
        import pathlib
        build_sh_path = pathlib.Path(__file__).resolve().parent.parent / "build.sh"
        content = build_sh_path.read_text()

        # Must generate attestation file in build_vyos
        self.assertIn('.attestation.json', content)
        self.assertIn('Generated cryptographic image attestation at:', content)
        self.assertIn('credentials_verified: $credentials_verified', content)

        # build_iso must invoke verify_golden_image_attestation_and_credentials
        self.assertIn('verify_golden_image_attestation_and_credentials "$golden_disk" "$BUILD_MODE"', content)

        # Must reject dev images in production mode
        self.assertIn('Cannot package a development image into a production ISO', content)

        # Must reject missing or corrupt attestation
        self.assertIn('Golden master image attestation missing at', content)
        self.assertIn('Image attestation SHA-256 mismatch', content)

        # Must perform direct in-guest credential audit via NBD
        self.assertIn('Performing direct in-guest credential audit on', content)
        self.assertIn('Direct in-guest credential audit PASSED', content)

    def test_attestation_gate_logic(self):
        """Simulate the attestation gate logic across different image states and modes."""
        import tempfile, hashlib, json, pathlib

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = pathlib.Path(tmp_dir)
            disk = tmp_path / "vyos-golden.qcow2"
            sha_file = tmp_path / "vyos-golden.qcow2.sha256"
            attestation_file = tmp_path / "vyos-golden.qcow2.attestation.json"

            disk_content = b"valid-vyos-golden-bytes"
            disk.write_bytes(disk_content)
            disk_sha = hashlib.sha256(disk_content).hexdigest()
            sha_file.write_text(f"{disk_sha}  vyos-golden.qcow2\n")

            pass_hash = hashlib.sha256(b"SecretProdPass2026").hexdigest()

            def make_attestation(mode="production", sha=disk_sha, pass_h=pass_hash, verified=True):
                att = {
                    "artifact": "vyos-golden.qcow2",
                    "build_mode": mode,
                    "qcow2_sha256": sha,
                    "admin_password_hash_sha256": pass_h,
                    "built_at": "2026-11-13T10:00:00Z",
                    "credentials_verified": verified,
                }
                attestation_file.write_text(json.dumps(att))

            def verify_attestation(expected_mode="production", expected_pass="SecretProdPass2026"):
                if not disk.exists():
                    return False, "missing_disk"
                if not sha_file.exists():
                    return False, "missing_sha_file"
                if not attestation_file.exists():
                    return False, "missing_attestation"

                act_sha = hashlib.sha256(disk.read_bytes()).hexdigest()
                rec_sha = sha_file.read_text().split()[0]
                if act_sha != rec_sha:
                    return False, "disk_sha_mismatch"

                try:
                    att = json.loads(attestation_file.read_text())
                except Exception:
                    return False, "corrupted_attestation"

                if act_sha != att.get("qcow2_sha256"):
                    return False, "attestation_sha_mismatch"
                if not att.get("credentials_verified"):
                    return False, "unverified_credentials"

                if expected_mode == "production":
                    if att.get("build_mode") != "production":
                        return False, "dev_image_rejected_for_production"
                    if expected_pass:
                        exp_p_hash = hashlib.sha256(expected_pass.encode()).hexdigest()
                        if att.get("admin_password_hash_sha256") != exp_p_hash:
                            return False, "stale_password"

                return True, "valid"

            # 1. Valid production image succeeds
            make_attestation(mode="production")
            ok, reason = verify_attestation(expected_mode="production")
            self.assertTrue(ok)
            self.assertEqual(reason, "valid")

            # 2. Dev image packaged in production mode is REJECTED
            make_attestation(mode="dev", pass_h=hashlib.sha256(b"vyos").hexdigest())
            ok, reason = verify_attestation(expected_mode="production")
            self.assertFalse(ok)
            self.assertEqual(reason, "dev_image_rejected_for_production")

            # 3. Dev image packaged in dev mode is ACCEPTED
            ok, reason = verify_attestation(expected_mode="dev")
            self.assertTrue(ok)
            self.assertEqual(reason, "valid")

            # 4. Modified disk fails attestation
            make_attestation(mode="production")
            disk.write_bytes(b"modified-tampered-qcow2")
            ok, reason = verify_attestation(expected_mode="production")
            self.assertFalse(ok)
            self.assertEqual(reason, "disk_sha_mismatch")

            # 5. Stale password (changed in build.yaml after image build) is REJECTED
            disk.write_bytes(disk_content)
            make_attestation(mode="production", pass_h=hashlib.sha256(b"OldPassword").hexdigest())
            ok, reason = verify_attestation(expected_mode="production", expected_pass="NewPassword")
            self.assertFalse(ok)
            self.assertEqual(reason, "stale_password")

            # 6. Missing attestation is REJECTED
            attestation_file.unlink()
            ok, reason = verify_attestation(expected_mode="production")
            self.assertFalse(ok)
            self.assertEqual(reason, "missing_attestation")


if __name__ == "__main__":
    unittest.main()
