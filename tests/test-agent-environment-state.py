"""Real state directories; fake systemd, with real lsof owner checks."""

import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "state", Path(__file__).resolve().parents[1] / "nixos/agent-environment-state.py"
)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = {
            "names": ["alpha", "beta"],
            "stateDir": str(self.root / "state"),
            "runtimeDir": str(self.root / "run"),
            "gcRootsDir": str(self.root / "gcroots"),
            "lockDir": str(self.root / "locks"),
            "systemctl": "systemctl",
            "tmpfiles": "tmpfiles",
            "lsof": shutil.which("lsof"),
        }
        for key in ("stateDir", "runtimeDir", "gcRootsDir", "lockDir"):
            Path(self.config[key]).mkdir()
        self.alpha = Path(self.config["stateDir"]) / "alpha"
        self.alpha.mkdir()
        (self.alpha / "private.img").write_text("private work")
        self.beta = self.alpha.with_name("beta")
        self.beta.mkdir()
        (self.beta / "private.img").write_text("other guest")
        self.shared = self.root / "shared"
        self.shared.mkdir()
        (self.shared / "work").write_text("shared work")
        self.masks = set()
        self.active = set()
        self.calls = []
        self.stop_failure = False
        self.start_failure = False
        self.addCleanup(patch.stopall)
        patch.object(state, "run", side_effect=self.fake_run).start()
        patch("sys.stdout", new=io.StringIO()).start()

    def fake_run(self, *args):
        self.calls.append(args)
        command, action, *arguments = args
        output = ""
        if command == "tmpfiles":
            self.alpha.mkdir(exist_ok=True)
        elif action == "show":
            unit, _, prop, _ = arguments
            if prop == "LoadState":
                output = "masked" if unit in self.masks else "loaded"
            else:
                output = "active" if unit in self.active else "inactive"
        elif action == "mask":
            self.masks.update(arguments[1:])
        elif action == "unmask":
            self.masks.difference_update(arguments[1:])
        elif action == "stop":
            if self.stop_failure:
                raise subprocess.CalledProcessError(1, args)
            self.active.difference_update(arguments)
        elif action == "start":
            if self.start_failure:
                raise subprocess.CalledProcessError(1, args)
            if arguments[0].startswith("install-microvm"):
                self.assertTrue(self.alpha.is_dir())
                (self.alpha / "current").symlink_to(self.shared)
            else:
                self.active.add(arguments[0])
        return subprocess.CompletedProcess(args, 0, output, "")

    def manage(self, action="delete", name="alpha"):
        state.manage(self.config, action, name)

    def test_delete_running_guest_and_leftovers_only(self):
        self.active.update(("microvm@alpha.service", "microvm@beta.service"))
        (self.alpha / "current").symlink_to(self.shared)
        (self.alpha / "nested").mkdir()
        (self.alpha / "nested/stale-file").write_text("leftover")
        runtime = Path(self.config["runtimeDir"]) / "agent-shares-alpha"
        runtime.mkdir()
        (runtime / "export").symlink_to(self.shared)
        roots = Path(self.config["gcRootsDir"])
        for name in ("alpha", "booted-alpha", "old-alpha", "beta"):
            (roots / name).symlink_to(self.alpha / "current")
        self.manage()
        self.assertFalse(self.alpha.exists())
        self.assertFalse(runtime.exists())
        self.assertEqual((self.beta / "private.img").read_text(), "other guest")
        self.assertEqual((self.shared / "work").read_text(), "shared work")
        self.assertEqual(list(roots.iterdir()), [roots / "beta"])
        self.assertEqual(self.active, {"microvm@beta.service"})
        self.assertEqual(self.masks, set())

    def test_delete_is_repeatable_and_start_recreates_directory(self):
        self.manage()
        self.manage()
        self.manage("start")
        self.assertTrue((self.alpha / "current").is_symlink())
        self.assertFalse((self.alpha / "private.img").exists())
        self.assertEqual(self.calls[-3:], [
            ("tmpfiles", "--create", f"--prefix={self.alpha}"),
            ("systemctl", "start", "install-microvm-alpha.service"),
            ("systemctl", "start", "microvm@alpha.service"),
        ])

    def test_unknown_names_and_operations_do_nothing(self):
        for name in ("unknown", "../shared", "alpha/..", "-alpha"):
            with self.assertRaises(ValueError):
                self.manage(name=name)
        with self.assertRaises(ValueError):
            self.manage("unknown")
        self.assertEqual(self.calls, [])
        self.assertTrue((self.alpha / "private.img").exists())

    def test_restart_stops_before_installing_and_preserves_state(self):
        for running in (True, False):
            with self.subTest(running=running):
                self.calls.clear()
                (self.alpha / "current").unlink(missing_ok=True)
                self.active = {"microvm@beta.service"}
                if running:
                    self.active.add("microvm@alpha.service")
                self.manage("restart")
                self.assertEqual(self.calls, [
                    ("systemctl", "stop", "microvm@alpha.service"),
                    ("tmpfiles", "--create", f"--prefix={self.alpha}"),
                    ("systemctl", "start", "install-microvm-alpha.service"),
                    ("systemctl", "start", "microvm@alpha.service"),
                ])
                self.assertEqual(self.active, {"microvm@alpha.service", "microvm@beta.service"})
                self.assertEqual((self.alpha / "private.img").read_text(), "private work")
                self.assertEqual((self.shared / "work").read_text(), "shared work")

    def test_restart_aborts_if_stop_fails(self):
        self.stop_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.manage("restart")
        self.assertEqual(self.calls, [("systemctl", "stop", "microvm@alpha.service")])
        self.assertEqual((self.alpha / "private.img").read_text(), "private work")

    def test_restart_start_failure_preserves_disk(self):
        self.active.add("microvm@alpha.service")
        self.start_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.manage("restart")
        self.assertNotIn("microvm@alpha.service", self.active)
        self.assertEqual((self.alpha / "private.img").read_text(), "private work")

    def test_symlinked_state_directory_or_parent_is_refused(self):
        shutil.rmtree(self.alpha)
        self.alpha.symlink_to(self.shared)
        with self.assertRaises(ValueError):
            self.manage()
        self.alpha.unlink()
        directory = Path(self.config["stateDir"])
        directory.rename(directory.with_name("saved"))
        directory.symlink_to(directory.with_name("saved"))
        with self.assertRaises(ValueError):
            self.manage()
        self.assertEqual((self.shared / "work").read_text(), "shared work")

    def test_stop_failure_preserves_disk_and_operator_masks(self):
        self.masks.add("microvm@alpha.service")
        self.stop_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.manage()
        self.assertTrue((self.alpha / "private.img").exists())
        self.assertEqual(self.masks, {"microvm@alpha.service"})

    def test_mount_in_state_directory_is_refused(self):
        # Include a same-filesystem bind mount, which --one-file-system misses.
        mountinfo = f"1 0 0:1 / {self.alpha}/nested rw - ext4 /dev/vda rw\n"
        with patch("builtins.open", return_value=io.StringIO(mountinfo)):
            with self.assertRaisesRegex(ValueError, "contains mount"):
                self.manage()
        self.assertTrue((self.alpha / "private.img").exists())
        self.assertEqual(self.masks, set())

    def test_open_disk_is_refused(self):
        # Keep an actual file descriptor open; lsof must see the test process.
        with (self.alpha / "private.img").open():
            with self.assertRaisesRegex(ValueError, "open files"):
                self.manage()
        self.assertTrue((self.alpha / "private.img").exists())
        self.assertEqual(self.masks, set())

    def test_lsof_warning_or_failure_is_refused(self):
        for code, stderr in ((1, "cannot stat filesystem"), (2, ""), (0, "")):
            result = subprocess.CompletedProcess([], code, "", stderr)
            with patch.object(state.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(ValueError, "incomplete lsof"):
                    self.manage()
            self.assertTrue((self.alpha / "private.img").exists())

    def test_unexpected_gc_root_is_refused_before_disk_deletion(self):
        root = Path(self.config["gcRootsDir"]) / "alpha"
        root.write_text("unexpected file")
        with self.assertRaisesRegex(ValueError, "GC-root symlink"):
            self.manage()
        self.assertTrue((self.alpha / "private.img").exists())
        self.assertEqual(self.masks, set())


if __name__ == "__main__":
    unittest.main()
