"""Check first-start policy and preservation of mutable state without networking."""

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


COMMAND = sys.argv[1:]
EXISTING = b"""<configuration version="40">
    <folder id="notes" path="/home/fixture/notes" type="receiveonly">
        <device id="PEER"/><versioning type="staggered"/>
    </folder>
    <device id="PEER"><address>tcp://100.64.1.2:22000</address></device>
    <gui><address>127.0.0.1:8384</address><apikey>fixture-api-key</apikey>
        <user>fixture</user><password>fixture-hash</password></gui>
    <options>
        <listenAddress>default</listenAddress>
        <listenAddress>quic://0.0.0.0:22000</listenAddress>
        <globalAnnounceEnabled>true</globalAnnounceEnabled>
        <localAnnounceEnabled>true</localAnnounceEnabled>
        <natEnabled>true</natEnabled><relaysEnabled>true</relaysEnabled>
        <stunKeepaliveStartS>180</stunKeepaliveStartS>
        <maxSendKbps>123</maxSendKbps>
    </options>
</configuration>"""


class SyncthingPreparation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="syncthing test ")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.environment = {
            name: value for name, value in os.environ.items() if not name.startswith("ST")
        }
        self.environment.update(
            HOME=str(self.home),
            XDG_STATE_HOME=str(self.home / "state"),
            XDG_CONFIG_HOME=str(self.home / "config"),
        )
        self.state = self.home / "state/syncthing"
        self.legacy = self.home / "config/syncthing"

    def run_prepare(self, success=True):
        result = subprocess.run(
            COMMAND, env=self.environment, cwd=self.home, capture_output=True, text=True
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)

    def seed(self, directory):
        directory.mkdir(parents=True)
        (directory / "config.xml").write_bytes(EXISTING)
        (directory / "cert.pem").write_bytes(b"fixture certificate")
        (directory / "key.pem").write_bytes(b"fixture private identity")

    def assert_policy(self, directory):
        root = ET.parse(directory / "config.xml").getroot()
        options = root.find("options")
        self.assertEqual(
            [element.text for element in options.findall("listenAddress")],
            ["tcp://0.0.0.0:22000"],
        )
        for name in (
            "globalAnnounceEnabled", "localAnnounceEnabled", "natEnabled", "relaysEnabled"
        ):
            self.assertEqual(options.findtext(name), "false", name)
        self.assertEqual(options.findtext("stunKeepaliveStartS"), "0")
        self.assertEqual(stat.S_IMODE((directory / "config.xml").stat().st_mode), 0o600)
        return root

    def test_fresh_instance_generates_and_retains_identity(self):
        self.run_prepare()
        self.assert_policy(self.state)
        identity = [(self.state / name).read_bytes() for name in ("cert.pem", "key.pem")]
        self.assertTrue(all(identity))
        self.run_prepare()
        self.assert_policy(self.state)
        self.assertEqual(
            [(self.state / name).read_bytes() for name in ("cert.pem", "key.pem")], identity
        )
        self.assertFalse(self.legacy.exists())

    def test_existing_gui_choices_and_identity_survive_repeated_preparation(self):
        self.seed(self.state)
        expected = ET.fromstring(EXISTING)
        for _ in range(2):
            self.run_prepare()
            actual = self.assert_policy(self.state)
            for name in ("folder", "device", "gui"):
                self.assertEqual(ET.tostring(actual.find(name)), ET.tostring(expected.find(name)))
            self.assertEqual(actual.findtext("options/maxSendKbps"), "123")
            self.assertEqual((self.state / "key.pem").read_bytes(), b"fixture private identity")

    def test_legacy_configuration_is_preserved_in_place(self):
        self.seed(self.legacy)
        # An empty modern directory must not hide the legacy configuration.
        self.state.mkdir(parents=True)
        self.run_prepare()
        self.assert_policy(self.legacy)
        self.assertFalse((self.state / "config.xml").exists())
        self.assertEqual((self.legacy / "key.pem").read_bytes(), b"fixture private identity")

    def test_modern_configuration_takes_precedence(self):
        self.seed(self.state)
        self.seed(self.legacy)
        self.run_prepare()
        self.assert_policy(self.state)
        self.assertEqual((self.legacy / "config.xml").read_bytes(), EXISTING)

    def test_default_xdg_locations(self):
        del self.environment["XDG_STATE_HOME"]
        del self.environment["XDG_CONFIG_HOME"]
        self.run_prepare()
        self.assert_policy(self.home / ".local/state/syncthing")

    def test_invalid_configuration_fails_without_overwriting_it(self):
        self.seed(self.state)
        invalid = b"<configuration>truncated"
        (self.state / "config.xml").write_bytes(invalid)
        self.run_prepare(success=False)
        self.assertEqual((self.state / "config.xml").read_bytes(), invalid)
        self.assertEqual((self.state / "key.pem").read_bytes(), b"fixture private identity")
        self.assertEqual(list(self.state.glob(".config-*")), [])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
