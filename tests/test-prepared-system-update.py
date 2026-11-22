"""Exercise preparation, replacement and Apply with real Git and fake Nix/root tools."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/prepared-system-update.py"
# Loading the helper for tests must not leave bytecode in the checkout.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("prepared_updates", SCRIPT)
UPDATES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATES)


class PreparedUpdatesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        self.env = os.environ | {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "UPDATE_TEST_LOG": str(self.log),
            "UPDATE_TEST_ROOT": str(self.root),
        }
        self.git("init", "--quiet")
        (self.repo / "flake.nix").write_text("original config\n")
        (self.repo / "flake.lock").write_text('{"original": true}\n')
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "initial")
        common = '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["UPDATE_TEST_ROOT"])
with pathlib.Path(os.environ["UPDATE_TEST_LOG"]).open("a") as stream:
    stream.write(json.dumps([pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
'''
        self.command("nix", common + '''
if sys.argv[1:3] == ["flake", "update"]:
    pathlib.Path("flake.lock").write_text('{"updated": "' + os.environ.get("UPDATE_VERSION", "one") + '"}\\n')
    if os.environ.get("UPDATE_FAIL") == "update":
        sys.exit(11)
elif sys.argv[1] == "build":
    assert "--no-write-lock-file" in sys.argv
    assert sys.argv[sys.argv.index("--cores") + 1] == "2"
    snapshot = pathlib.Path.cwd()
    (root / "snapshot-config").write_bytes((snapshot / "flake.nix").read_bytes())
    if os.environ.get("UPDATE_FAIL") == "build":
        sys.exit(12)
    system = root / ("system-" + os.environ.get("UPDATE_VERSION", "one"))
    (system / "bin").mkdir(parents=True, exist_ok=True)
    (system / "bin/switch-to-configuration").touch()
    pathlib.Path(sys.argv[sys.argv.index("--out-link") + 1]).symlink_to(system)
elif sys.argv[1:3] == ["store", "diff-closures"]:
    assert sys.argv[3] == "/run/current-system"
    assert (pathlib.Path(sys.argv[4]) / "bin/switch-to-configuration").is_file()
    if os.environ.get("UPDATE_FAIL") == "diff":
        sys.exit(14)
    print(os.environ.get("UPDATE_DIFF", "firefox: 144.0 -> 145.0"))
else:
    raise AssertionError(sys.argv)
''')
        self.command("sudo", common + '''
assert sys.argv[1:5] == ["/test/nixos-rebuild", "switch", "--no-reexec", "--store-path"]
assert (pathlib.Path(sys.argv[5]) / "bin/switch-to-configuration").is_file()
if os.environ.get("UPDATE_FAIL") == "apply":
    sys.exit(13)
if os.environ.get("EDIT_DURING_APPLY"):
    pathlib.Path(os.environ["EDIT_DURING_APPLY"]).write_text("concurrent edit\\n")
''')
        for command in ["notify-send", "systemctl"]:
            self.command(command, common)

    def command(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{body}")
        path.chmod(0o700)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env,
                              check=True, capture_output=True).stdout

    def invoke(self, action, success=True, **environment):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--repository", str(self.repo),
             "--state-dir", str(self.state), "--host", "laptop",
             "--rebuild-command", "/test/nixos-rebuild", action],
            env=self.env | environment, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def commands(self, name=None):
        commands = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [entry for entry in commands if name is None or entry[0] == name]

    def candidate(self):
        return (self.state / "ready").resolve()

    def updates(self):
        return UPDATES.Updates(SimpleNamespace(
            repository=str(self.repo), state_dir=str(self.state), host="laptop",
            rebuild_command="/test/nixos-rebuild", max_jobs="1", cores="2",
        ))

    def test_unchanged_system_suppresses_ready_and_applied_notices(self):
        current = self.root / "current-system"
        current.symlink_to(self.root / "system-one")
        with patch.object(UPDATES, "CURRENT_SYSTEM", current), patch.dict(os.environ, self.env):
            self.updates().prepare()
            self.assertEqual(self.commands("notify-send"), [])
            self.assertTrue((self.candidate() / "system").is_symlink())
            self.updates().apply()
        self.assertEqual(self.commands("notify-send"), [])
        self.assertEqual((self.repo / "flake.lock").read_text(), '{"updated": "one"}\n')

    def test_different_system_notifies_even_without_package_version_changes(self):
        current = self.root / "current-system"
        current.symlink_to(self.root / "system-old")
        with patch.object(UPDATES, "CURRENT_SYSTEM", current), patch.dict(os.environ, self.env | {"UPDATE_DIFF": ""}):
            self.updates().prepare()
        self.assertEqual(len(self.commands("notify-send")), 1)
        self.assertIn("System update ready", self.commands("notify-send")[0])

    def test_failure_still_notifies_when_candidate_matches_running_system(self):
        current = self.root / "current-system"
        current.symlink_to(self.root / "system-one")
        with patch.object(UPDATES, "CURRENT_SYSTEM", current), patch.dict(os.environ, self.env):
            self.updates().prepare()
            with patch.dict(os.environ, {"UPDATE_FAIL": "build"}):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.updates().prepare()
        self.assertEqual(len(self.commands("notify-send")), 1)
        self.assertIn("System update preparation failed", self.commands("notify-send")[0])

    def test_isolated_dirty_snapshot_and_apply_exact_system(self):
        (self.repo / "flake.nix").write_text("uncommitted config\n")
        (self.repo / "flake.lock").write_text('{"uncommitted": true}\n')
        (self.repo / "new.nix").write_text("staged module\n")
        self.git("add", "new.nix")
        index_before = self.git("diff", "--cached", "--binary")
        before = self.git("diff", "HEAD", "--binary")
        self.invoke("prepare")
        candidate = self.candidate()
        self.assertEqual(self.git("diff", "HEAD", "--binary"), before)
        self.assertEqual((candidate / "source/new.nix").read_text(), "staged module\n")
        self.assertEqual((self.root / "snapshot-config").read_text(), "uncommitted config\n")
        self.assertEqual(len(self.commands("sudo")), 0)
        nix_before = self.commands("nix")
        self.invoke("apply")
        self.assertEqual(self.commands("nix"), nix_before, "Apply must not evaluate, fetch or build")
        self.assertEqual(self.commands("sudo")[0][-1], str(self.root / "system-one"))
        self.assertEqual((self.repo / "flake.lock").read_text(), '{"updated": "one"}\n')
        self.assertEqual(self.git("diff", "--cached", "--binary"), index_before)
        self.assertTrue(json.loads((candidate / "metadata.json").read_text())["applied_at"])
        self.invoke("apply", success=False)
        self.assertEqual(len(self.commands("sudo")), 1)

    def test_next_success_replaces_unapplied_candidate_and_old_root(self):
        self.invoke("prepare")
        old = self.candidate()
        self.invoke("prepare", UPDATE_VERSION="two")
        new = self.candidate()
        self.assertNotEqual(old, new)
        self.assertFalse(old.exists())
        self.assertEqual(list((self.state / "candidates").iterdir()), [new])
        self.assertEqual((new / "system").resolve(), self.root / "system-two")
        self.assertTrue((new / "system").is_symlink())
        self.invoke("apply")
        self.assertEqual(self.commands("sudo")[0][-1], str(self.root / "system-two"))

    def test_failed_update_or_build_keeps_previous_candidate(self):
        self.invoke("prepare")
        old = self.candidate()
        original_lock = (self.repo / "flake.lock").read_bytes()
        for failure in ["update", "build"]:
            with self.subTest(failure=failure):
                self.invoke("prepare", success=False, UPDATE_FAIL=failure)
                self.assertEqual(self.candidate(), old)
                self.assertEqual(list((self.state / "candidates").iterdir()), [old])
                self.assertEqual(json.loads((self.state / "last-run.json").read_text())["status"], "failed")
                self.assertEqual((self.repo / "flake.lock").read_bytes(), original_lock)
        self.assertIn("--urgency=critical", self.commands("notify-send")[-1])
        self.invoke("apply")

    def test_changed_checkout_or_lock_refuses_apply(self):
        self.invoke("prepare")
        for file in ["flake.nix", "flake.lock"]:
            with self.subTest(file=file):
                path = self.repo / file
                original = path.read_bytes()
                path.write_text("changed after build\n")
                self.invoke("apply", success=False)
                self.assertEqual(len(self.commands("sudo")), 0)
                self.assertEqual(path.read_text(), "changed after build\n")
                path.write_bytes(original)

    def test_failed_activation_keeps_checkout_and_allows_retry(self):
        self.invoke("prepare")
        before = (self.repo / "flake.lock").read_bytes()
        self.invoke("apply", success=False, UPDATE_FAIL="apply")
        self.assertEqual((self.repo / "flake.lock").read_bytes(), before)
        self.assertNotIn("applied_at", json.loads((self.candidate() / "metadata.json").read_text()))
        self.invoke("apply")

    def test_checkout_edit_during_activation_is_preserved(self):
        self.invoke("prepare")
        before = (self.repo / "flake.lock").read_bytes()
        result = self.invoke("apply", success=False, EDIT_DURING_APPLY=str(self.repo / "flake.nix"))
        self.assertIn("System applied, but the checkout changed", result.stderr)
        self.assertEqual((self.repo / "flake.lock").read_bytes(), before)
        self.assertEqual((self.repo / "flake.nix").read_text(), "concurrent edit\n")

    def test_lock_excludes_prepare_and_apply(self):
        self.state.mkdir()
        with (self.state / "lock").open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for action in ["prepare", "apply"]:
                self.invoke(action, success=False)
        self.assertEqual(self.commands(), [])

    def test_start_is_nonblocking_and_status_handles_no_candidate(self):
        status = self.invoke("status")
        self.assertIn("No prepared update.", status.stdout)
        self.assertEqual(self.commands("nix"), [])
        self.invoke("start")
        self.assertEqual(self.commands("systemctl"), [["systemctl", "--user", "start", "--no-block", "frkl-update-prepare.service"]])

    def test_status_lists_changes_from_running_system_without_building(self):
        self.invoke("prepare")
        before = self.git("diff", "HEAD", "--binary")
        old_commands = self.commands("nix")
        changes = "firefox: 144.0 -> 145.0\nnew-app: ∅ -> 1.0\nold-app: 2.0 -> ∅"
        status = self.invoke("status", UPDATE_DIFF=changes)
        self.assertIn("Package changes from the running system:", status.stdout)
        self.assertIn(changes, status.stdout)
        self.assertEqual(self.commands("nix")[len(old_commands):], [
            ["nix", "store", "diff-closures", "/run/current-system", str(self.root / "system-one")],
        ])
        self.assertEqual(self.commands("sudo"), [])
        self.assertEqual(self.git("diff", "HEAD", "--binary"), before)

    def test_status_reports_no_package_changes(self):
        self.invoke("prepare")
        status = self.invoke("status", UPDATE_DIFF="")
        self.assertIn("No package version or significant store-size changes.", status.stdout)

    def test_status_comparison_failure_does_not_claim_no_changes(self):
        self.invoke("prepare")
        status = self.invoke("status", success=False, UPDATE_FAIL="diff")
        self.assertNotIn("No package version or significant store-size changes.", status.stdout)

    def test_status_compares_applied_candidate_against_current_system(self):
        self.invoke("prepare")
        self.invoke("apply")
        status = self.invoke("status", UPDATE_DIFF="")
        self.assertIn('"applied_at"', status.stdout)
        self.assertIn("No package version or significant store-size changes.", status.stdout)

    def test_abandoned_work_is_removed_and_tampered_candidate_refused(self):
        self.invoke("prepare")
        abandoned = self.state / "candidates/candidate-abandoned"
        abandoned.mkdir()
        (abandoned / "partial-build").touch()
        self.invoke("prepare")
        self.assertFalse(abandoned.exists())
        (self.candidate() / "source/flake.lock").write_text("tampered\n")
        self.invoke("apply", success=False)
        self.assertEqual(self.commands("sudo"), [])


if __name__ == "__main__":
    unittest.main()
