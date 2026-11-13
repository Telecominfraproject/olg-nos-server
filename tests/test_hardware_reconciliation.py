#!/usr/bin/env python3
"""
Unit tests for domain XML hardware reconciliation.
Proves that equivalent hardware configurations (despite runtime guest addresses,
driver tags, aliases, and formatting differences) are recognized as identical,
preventing unnecessary destruction of the active vyos-router VM.
"""

import unittest
import xml.etree.ElementTree as ET


def extract_normalized_hostdevs(xml_source):
    """
    Python implementation matching extract_normalized_hostdevs in startup_node.sh.
    Extracts physical hostdevs (PCI and USB), ignores guest-side addresses,
    and returns a sorted, comma-separated normalized device signature.
    """
    try:
        if xml_source.strip().startswith("<"):
            root = ET.fromstring(xml_source)
        else:
            root = ET.parse(xml_source).getroot()
    except Exception as e:
        raise ValueError(f"XML parse error: {e}")

    devs = []
    for hostdev in root.findall(".//devices/hostdev"):
        htype = hostdev.get("type")
        source_elem = hostdev.find("source")
        if source_elem is None:
            continue
        addr = source_elem.find("address")
        if htype == "pci" and addr is not None:
            dom = int(addr.get("domain", "0"), 16)
            bus = int(addr.get("bus", "0"), 16)
            slot = int(addr.get("slot", "0"), 16)
            fn = int(addr.get("function", "0"), 16)
            devs.append(f"pci:{dom:04x}:{bus:02x}:{slot:02x}.{fn:x}")
        elif htype == "usb":
            if addr is not None and addr.get("bus") is not None and addr.get("device") is not None:
                bus = int(addr.get("bus"))
                dev = int(addr.get("device"))
                devs.append(f"usb:bus={bus}:dev={dev}")
            else:
                vendor = source_elem.find("vendor")
                product = source_elem.find("product")
                if vendor is not None and product is not None:
                    vid = vendor.get("id", "").lower().strip()
                    pid = product.get("id", "").lower().strip()
                    devs.append(f"usb:vendor={vid}:product={pid}")

    devs.sort()
    return ",".join(devs)


class TestHardwareReconciliation(unittest.TestCase):

    def test_equivalent_pci_hardware_preserves_vm(self):
        """Desired domain XML vs active runtime dumpxml with libvirt runtime additions."""
        desired_xml = """
        <domain type='kvm'>
          <devices>
            <hostdev mode='subsystem' type='pci' managed='yes'>
              <source>
                <address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/>
              </source>
            </hostdev>
          </devices>
        </domain>
        """

        # Runtime XML from virsh dumpxml contains driver, alias, and guest-side address
        runtime_dumpxml = """
        <domain type='kvm' id='5'>
          <name>vyos-router</name>
          <devices>
            <disk type='file' device='disk'>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
            </disk>
            <interface type='bridge'>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
            </interface>
            <hostdev mode='subsystem' type='pci' managed='yes'>
              <driver name='vfio'/>
              <source>
                <address domain='0x0' bus='0x7' slot='0x0' function='0x0'/>
              </source>
              <alias name='hostdev0'/>
              <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
            </hostdev>
          </devices>
        </domain>
        """

        desired_hw = extract_normalized_hostdevs(desired_xml)
        runtime_hw = extract_normalized_hostdevs(runtime_dumpxml)

        self.assertEqual(desired_hw, "pci:0000:07:00.0")
        self.assertEqual(runtime_hw, "pci:0000:07:00.0")
        self.assertEqual(desired_hw, runtime_hw, "Equivalent PCI hardware must match to avoid VM destruction")

    def test_equivalent_usb_hardware_preserves_vm(self):
        """Desired USB device vs runtime dumpxml with runtime USB controller and alias."""
        desired_xml = """
        <domain type='kvm'>
          <devices>
            <hostdev mode='subsystem' type='usb' managed='yes'>
              <source>
                <address bus='2' device='3'/>
              </source>
            </hostdev>
          </devices>
        </domain>
        """

        runtime_dumpxml = """
        <domain type='kvm' id='2'>
          <name>vyos-router</name>
          <devices>
            <hostdev mode='subsystem' type='usb' managed='yes'>
              <source>
                <address bus='002' device='003'/>
              </source>
              <alias name='hostdev0'/>
              <address type='usb' bus='0' port='1'/>
            </hostdev>
          </devices>
        </domain>
        """

        desired_hw = extract_normalized_hostdevs(desired_xml)
        runtime_hw = extract_normalized_hostdevs(runtime_dumpxml)

        self.assertEqual(desired_hw, "usb:bus=2:dev=3")
        self.assertEqual(runtime_hw, "usb:bus=2:dev=3")
        self.assertEqual(desired_hw, runtime_hw, "Equivalent USB hardware must match to avoid VM destruction")

    def test_differing_pci_hardware_triggers_recreation(self):
        """Changing physical PCI address (e.g. NIC moved or re-assigned) triggers recreation."""
        desired_xml = """
        <domain type='kvm'>
          <devices>
            <hostdev mode='subsystem' type='pci' managed='yes'>
              <source>
                <address domain='0x0000' bus='0x08' slot='0x00' function='0x0'/>
              </source>
            </hostdev>
          </devices>
        </domain>
        """

        runtime_dumpxml = """
        <domain type='kvm' id='2'>
          <devices>
            <hostdev mode='subsystem' type='pci' managed='yes'>
              <source>
                <address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/>
              </source>
            </hostdev>
          </devices>
        </domain>
        """

        desired_hw = extract_normalized_hostdevs(desired_xml)
        runtime_hw = extract_normalized_hostdevs(runtime_dumpxml)

        self.assertNotEqual(desired_hw, runtime_hw)
        self.assertEqual(desired_hw, "pci:0000:08:00.0")
        self.assertEqual(runtime_hw, "pci:0000:07:00.0")

    def test_order_independence_preserves_vm(self):
        """Multiple hostdevs in different XML orders must produce identical sorted signatures."""
        xml_order_a = """
        <domain><devices>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <source><address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/></source>
          </hostdev>
          <hostdev mode='subsystem' type='usb' managed='yes'>
            <source><address bus='2' device='3'/></source>
          </hostdev>
        </devices></domain>
        """

        xml_order_b = """
        <domain><devices>
          <hostdev mode='subsystem' type='usb' managed='yes'>
            <source><address bus='2' device='3'/></source>
          </hostdev>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <source><address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/></source>
          </hostdev>
        </devices></domain>
        """

        self.assertEqual(extract_normalized_hostdevs(xml_order_a), extract_normalized_hostdevs(xml_order_b))

    def test_fail_safe_on_invalid_xml(self):
        """Malformed XML raises an exception so orchestrator fails safely without destroying VM."""
        malformed_xml = "<domain><devices><hostdev incomplete..."
        with self.assertRaises(ValueError):
            extract_normalized_hostdevs(malformed_xml)

    def test_startup_node_skips_virsh_define_when_unverified(self):
        """Verify startup_node.sh does NOT execute virsh define when hardware comparison is unverified."""
        import pathlib
        startup_script = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "startup_node.sh"
        content = startup_script.read_text()

        # HW_VERIFIED must be initialized to false
        self.assertIn('HW_VERIFIED="false"', content)
        # HW_VERIFIED must only be set to true when physical hardware matches
        self.assertIn('HW_VERIFIED="true"', content)
        # virsh define in else branch must be guarded by HW_VERIFIED == true
        self.assertIn('if [ "$HW_VERIFIED" = "true" ]; then', content)
        self.assertIn('virsh define "$DOMAIN_XML_FILE"', content)
        self.assertIn('Active vyos-router instance preserved without modification (hardware comparison was unverified; persistent definition untouched)', content)


class TestVirshReconciliationIntegration(unittest.TestCase):
    """Integration tests executing the actual startup_node.sh reconciliation logic against mocked virsh binaries."""

    def _run_reconciliation(self, runtime_xml=None, desired_xml_content=None, dumpxml_exit_code=0, domstate="running", flag_recreate="false"):
        import tempfile, subprocess, pathlib
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = pathlib.Path(tmp_dir)
            bin_dir = tmp_path / "bin"
            bin_dir.mkdir()
            mock_virsh = bin_dir / "virsh"
            log_file = tmp_path / "virsh.log"

            mock_virsh.write_text(f"""#!/usr/bin/env bash
echo "$@" >> "{log_file}"
case "$1" in
  domstate)
    echo "{domstate}"
    ;;
  dumpxml)
    if [ "{dumpxml_exit_code}" -ne 0 ]; then
      exit {dumpxml_exit_code}
    fi
    cat "{tmp_path}/dumpxml.xml" 2>/dev/null
    ;;
  destroy|undefine|define|start)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
""")
            mock_virsh.chmod(0o755)

            if runtime_xml is not None:
                (tmp_path / "dumpxml.xml").write_text(runtime_xml)

            desired_file = tmp_path / "desired.xml"
            desired_file.write_text(desired_xml_content or "")

            startup_script = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "startup_node.sh"

            bash_test = f"""
export PATH="{bin_dir}:$PATH"
log_info() {{ echo "[INFO] $*"; }}
log_warn() {{ echo "[WARN] $*"; }}
log_error() {{ echo "[ERROR] $*"; }}

source <(sed -n '/extract_normalized_hostdevs()/,/^}}/p' "{startup_script}")

DOMAIN_XML_FILE="{desired_file}"
FLAG_RECREATE_VM="{flag_recreate}"

source <(sed -n '/VM_STATE=\\$(virsh domstate/,/virsh autostart/p' "{startup_script}")
"""
            res = subprocess.run(["bash", "-c", bash_test], capture_output=True, text=True)
            virsh_calls = log_file.read_text().splitlines() if log_file.exists() else []
            return res.returncode, res.stdout, res.stderr, virsh_calls

    def test_matching_hardware_preserves_running_vm_and_defines(self):
        """When hardware matches, running VM is NOT destroyed and virsh define updates persistent config."""
        desired = """<domain><devices>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <source><address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/></source>
          </hostdev>
        </devices></domain>"""

        runtime = """<domain><devices>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <driver name='vfio'/>
            <source><address domain='0x0' bus='0x7' slot='0x0' function='0x0'/></source>
            <address type='pci' domain='0x0000' bus='0x06' slot='0x00' function='0x0'/>
          </hostdev>
        </devices></domain>"""

        code, out, err, calls = self._run_reconciliation(runtime_xml=runtime, desired_xml_content=desired)
        self.assertEqual(code, 0)
        self.assertIn("Active vyos-router domain matches desired hardware and is healthy", out)
        virsh_str = " ".join(calls)
        self.assertNotIn("destroy vyos-router", virsh_str)
        self.assertIn("define", virsh_str)

    def test_differing_hardware_destroys_and_recreates_vm(self):
        """When physical PCI hardware differs, running VM is destroyed, undefined, redefined, and started."""
        desired = """<domain><devices>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <source><address domain='0x0000' bus='0x08' slot='0x00' function='0x0'/></source>
          </hostdev>
        </devices></domain>"""

        runtime = """<domain><devices>
          <hostdev mode='subsystem' type='pci' managed='yes'>
            <source><address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/></source>
          </hostdev>
        </devices></domain>"""

        code, out, err, calls = self._run_reconciliation(runtime_xml=runtime, desired_xml_content=desired)
        self.assertEqual(code, 0)
        self.assertIn("Hardware configuration mismatch between active domain and dynamic profile", out)
        virsh_str = " ".join(calls)
        self.assertIn("destroy vyos-router", virsh_str)
        self.assertIn("undefine vyos-router", virsh_str)
        self.assertIn("define", virsh_str)
        self.assertIn("start vyos-router", virsh_str)

    def test_dumpxml_failure_preserves_vm_and_skips_define(self):
        """When virsh dumpxml fails, VM is NOT destroyed and virsh define is NOT executed."""
        desired = "<domain><devices/></domain>"
        code, out, err, calls = self._run_reconciliation(runtime_xml="", desired_xml_content=desired, dumpxml_exit_code=1)
        self.assertEqual(code, 0)
        self.assertIn("Failed to dump XML for running vyos-router domain", out)
        self.assertIn("hardware comparison was unverified; persistent definition untouched", out)
        virsh_str = " ".join(calls)
        self.assertNotIn("destroy vyos-router", virsh_str)
        self.assertNotIn("define", virsh_str)

    def test_malformed_xml_preserves_vm_and_skips_define(self):
        """When XML parsing errors occur, VM is preserved and virsh define is NOT executed."""
        desired = "<domain><devices/></domain>"
        runtime_malformed = "<domain><devices><hostdev unclosed..."
        code, out, err, calls = self._run_reconciliation(runtime_xml=runtime_malformed, desired_xml_content=desired)
        self.assertEqual(code, 0)
        self.assertIn("Hardware comparison could not be completed safely", out)
        self.assertIn("hardware comparison was unverified; persistent definition untouched", out)
        virsh_str = " ".join(calls)
        self.assertNotIn("destroy vyos-router", virsh_str)
        self.assertNotIn("define", virsh_str)


if __name__ == "__main__":
    unittest.main()
