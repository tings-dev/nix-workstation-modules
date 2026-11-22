"""Exercise the built CLI's argument routing with external operations stubbed."""

import json
import os
from pathlib import Path
import pwd
import socket
import stat
import subprocess
import sys
import tempfile
import unittest


FIXTURES = json.loads(Path(sys.argv.pop()).read_text())
ACTIONS = ("start", "stop", "restart", "delete", "status", "details", "ssh", "ssh-operator", "public-ssh-key", "public-age-key", "trust-host-key")


class Commands(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "operations.jsonl"
        self.home = self.root / "home with spaces"
        self.env = os.environ | {"HOME": str(self.home), "OPERATIONS": str(self.log)}
        (self.home / ".ssh").mkdir(parents=True)
        (self.home / ".ssh/agent-environments_known_hosts").write_text(
            "".join(f"agent-env-{name} {FIXTURES['publicKey']}\n"
                    for name in ("work", "alpha", "beta", "agent-laptop"))
        )

    def call(self, fixture, *args, code=0):
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            [FIXTURES[fixture]["cli"], *args],
            env=self.env,
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        operations = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, operations

    def check_target(self, fixture, name, link_id, explicit=False):
        for action in ACTIONS:
            with self.subTest(fixture=fixture, action=action, explicit=explicit):
                result, operations = self.call(fixture, action, *([name] if explicit else []))
                unit = f"microvm@{name}.service"
                if action in ("start", "restart", "delete"):
                    self.assertEqual(operations[0][0], "sudo")
                    self.assertEqual(operations[0][-2:], [action, name])
                    if action in ("start", "restart"):
                        self.assertEqual(operations[1], ["systemctl", "is-active", "--quiet", unit])
                        self.assertEqual(operations[2], ["ssh-keyscan", "-T", "1", "-p", "22", "-t", "ed25519", f"10.83.{link_id}.2"])
                        self.assertIn(f"{name} is running (SSH ready).", result.stdout)
                elif action == "stop":
                    self.assertEqual(operations, [["sudo", "systemctl", "stop", unit]])
                elif action in ("status", "details"):
                    self.assertEqual(operations[0][0], "systemctl")
                    self.assertIn(unit, operations[0])
                    if action == "details":
                        self.assertIn(f"/var/lib/microvms/{name}/private.img", result.stdout)
                elif action == "trust-host-key":
                    self.assertEqual(operations[0][:2], [action, name])
                    self.assertEqual(operations[0][2], str(self.home / ".ssh/agent-environments_known_hosts"))
                    self.assertEqual(operations[0][3], f"agent-env-{name}")
                else:
                    self.assertEqual(len(operations), 1)
                    account = "operator" if action == "ssh-operator" else "agent"
                    self.assertIn(f"{account}@10.83.{link_id}.2", operations[0])
                    self.assertIn(f"HostKeyAlias=agent-env-{name}", operations[0])
                    self.assertEqual("-t" in operations[0], action == "ssh-operator")
                    public_commands = {
                        "public-ssh-key": "cat /home/agent/.ssh/id_ed25519.pub",
                        "public-age-key": "age-keygen -y /home/agent/.config/sops/age/keys.txt",
                    }
                    if action in public_commands:
                        self.assertEqual(operations[0][-1], public_commands[action])

    def test_single_environment_is_the_default_for_every_action(self):
        self.check_target("single", "work", 101)

    def ssh_settings(self, args):
        result = subprocess.run([FIXTURES["ssh"], "-G", *args], env=self.env,
                                text=True, capture_output=True, check=True)
        settings = {}
        for line in result.stdout.splitlines():
            key, value = line.split(" ", 1)
            settings.setdefault(key, []).append(value)
        return settings

    def check_ssh_policy(self, fixture, unattended=False):
        _, operations = self.call(fixture, "ssh")
        if unattended:
            sock = Path(self.env["XDG_RUNTIME_DIR"]) / "unattended-key.sock"
            self.assertEqual(operations[:-1], [["ssh-add", "-l", str(sock)]])
        ssh, *args = operations[-1]
        self.assertEqual(ssh, "ssh")
        self.assertEqual(args[:2], ["-F", "/dev/null"])
        cli = self.ssh_settings(args)
        alias = self.ssh_settings(["-F", FIXTURES[fixture]["sshConfig"], "work"])
        for key, expected in {
            "hostname": "10.83.101.2", "port": "22", "user": "agent",
            "hostkeyalias": "agent-env-work", "stricthostkeychecking": "true",
            "globalknownhostsfile": "/dev/null", "forwardagent": "no",
            "clearallforwardings": "yes", "identitiesonly": "yes" if unattended else "no",
            "batchmode": "yes" if unattended else "no",
        }.items():
            with self.subTest(option=key):
                self.assertEqual(cli[key], [expected])
                self.assertEqual(alias[key], [expected])
        pins = ".ssh/agent-environments_known_hosts"
        account_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        self.assertEqual(cli["userknownhostsfile"], [str(self.home / pins)])
        self.assertEqual(alias["userknownhostsfile"], [str(account_home / pins)])
        self.assertEqual(cli["connecttimeout"], ["5"])
        if unattended:
            self.assertEqual(cli["identityfile"], [str(self.home / ".ssh/fixture.pub")])
            self.assertEqual(alias["identityfile"], ["~/.ssh/fixture.pub"])
            self.assertEqual(cli["identityagent"], [str(sock)])
            self.assertEqual(alias["identityagent"], [f"/run/user/{os.getuid()}/unattended-key.sock"])
        else:
            self.assertEqual(cli["identityfile"], alias["identityfile"])
            self.assertNotIn("identityagent", cli)
            self.assertNotIn("identityagent", alias)

    def test_effective_ssh_policy(self):
        self.check_ssh_policy("single")

    def test_effective_unattended_policy_uses_the_checked_socket(self):
        runtime = self.root / "custom runtime"
        runtime.mkdir()
        self.env["XDG_RUNTIME_DIR"] = str(runtime)
        result, operations = self.call("unattended", "ssh", code=1)
        self.assertIn("frkl-arm", result.stderr)
        self.assertEqual(operations, [])
        (self.home / ".ssh/fixture.pub").write_text(FIXTURES["publicKey"])
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(runtime / "unattended-key.sock"))
            self.check_ssh_policy("unattended", unattended=True)

    def test_public_keys_require_a_trusted_host_key(self):
        (self.home / ".ssh/agent-environments_known_hosts").unlink()
        for action in ("public-ssh-key", "public-age-key"):
            with self.subTest(action=action):
                result, operations = self.call("single", action, code=255)
                self.assertEqual(operations, [])
                self.assertIn("agent-env trust-host-key work", result.stderr)
                self.assertIn(f"agent-env {action} work", result.stderr)

    def test_printed_host_key_command_runs_in_bash_and_fish(self):
        (self.home / ".ssh/agent-environments_known_hosts").unlink()
        result, operations = self.call("single", "ssh", code=255)
        self.assertEqual(operations, [])
        lines = result.stderr.splitlines()
        command = next(line.strip() for line in lines if line.strip().startswith("agent-env trust-host-key "))
        command_bin = Path(FIXTURES["single"]["cli"]).parent
        for shell in ("bash", "fish"):
            with self.subTest(shell=shell):
                self.log.unlink(missing_ok=True)
                result = subprocess.run(
                    [shell, "--no-config", "-c", command] if shell == "fish" else [shell, "-c", command],
                    env=os.environ | {"PATH": str(command_bin) + ":" + os.environ["PATH"],
                                      "HOME": str(self.home), "OPERATIONS": str(self.log)},
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(self.log.read_text())[:2], ["trust-host-key", "work"])

    def test_host_named_environment_is_the_default_with_several_guests(self):
        self.check_target("matching", "agent-laptop", 102)

    def test_explicit_name_overrides_the_default(self):
        self.check_target("matching", "alpha", 101, explicit=True)
        self.check_target("single", "work", 101, explicit=True)

    def test_no_default_refuses_every_action_without_side_effects(self):
        for action in ACTIONS:
            result, operations = self.call("ambiguous", action, code=2)
            self.assertIn("No default agent environment", result.stderr)
            self.assertIn("agent-laptop", result.stderr)
            self.assertIn("Available environments: alpha, beta", result.stderr)
            self.assertEqual(operations, [])
        self.check_target("ambiguous", "beta", 102, explicit=True)

    def test_remote_commands_use_a_delimiter_when_omitting_the_name(self):
        for action in ("ssh", "ssh-operator"):
            _, operations = self.call("matching", action, "--", "printf '%s' hello")
            self.assertIn("@10.83.102.2", " ".join(operations[0]))
            self.assertEqual(operations[0][-1], "printf '%s' hello")
            self.assertNotIn("-t", operations[0])
            for rest in (("alpha", "id"), ("alpha", "--", "id")):
                _, operations = self.call("matching", action, *rest)
                self.assertIn("@10.83.101.2", " ".join(operations[0]))
                self.assertEqual(operations[0][-1], "id")

    def test_unknown_names_and_extra_arguments_cannot_fall_back_to_a_default(self):
        for action in ACTIONS:
            _, operations = self.call("matching", action, "typo", code=2)
            self.assertEqual(operations, [])
        for action in ("start", "stop", "restart", "delete", "status", "details", "public-ssh-key", "public-age-key", "trust-host-key"):
            for rest in (("alpha", "extra"), ("--", "extra")):
                _, operations = self.call("matching", action, *rest, code=2)
                self.assertEqual(operations, [])

    def test_list_and_invalid_operations_keep_their_own_syntax(self):
        result, _ = self.call("matching", "list")
        self.assertEqual(result.stdout.splitlines()[0].split(), ["NAME", "STATUS"])
        self.assertEqual({row.split()[0] for row in result.stdout.splitlines()[1:]}, {"alpha", "agent-laptop"})
        for args in ((), ("list", "alpha"), ("unknown",), ("unknown", "alpha"), ("public-key", "alpha")):
            _, operations = self.call("matching", *args, code=2)
            self.assertEqual(operations, [])


class TrustHostKey(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.known = self.root / "home with spaces/.ssh/agent-environments_known_hosts"
        self.log = self.root / "key-operations.jsonl"
        script = "#!" + sys.executable + "\n" + '''
import json,os,sys
from pathlib import Path
log = Path(os.environ['KEY_OPERATIONS'])
previous = log.read_text().splitlines() if log.exists() else []
name = Path(sys.argv[0]).name
with log.open('a') as stream:
    stream.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'systemctl':
    assert sys.argv[1:] == ['show', 'microvm@work.service', '-p', 'ActiveState', '-p', 'InvocationID']
    repeated = any(json.loads(line)[0] == 'systemctl' for line in previous)
    identity = 'b' * 32 if repeated and os.environ.get('CHANGED_BOOT') else 'a' * 32
    print('ActiveState=' + os.environ.get('UNIT_STATE', 'active'))
    print('InvocationID=' + identity)
else:
    assert sys.argv[1:] == ['journalctl-fixture', '_SYSTEMD_INVOCATION_ID=' + 'a' * 32, '-u', 'microvm@work.service', '-o', 'cat', '--no-pager', '--quiet']
    if os.environ.get('JOURNAL_FAIL'):
        sys.exit(23)
    print(os.environ['JOURNAL'])
'''
        for name in ("systemctl", "sudo"):
            path = self.root / name
            path.write_text(script)
            path.chmod(0o755)

    def call(self, code=0, **extra):
        self.log.unlink(missing_ok=True)
        journal = "AGENT_SSH_HOST_KEY work " + FIXTURES["publicKey"]
        result = subprocess.run(
            [FIXTURES["hostKeyProgram"], "work", str(self.known), "fixture-pin",
             str(self.root / "systemctl"), "journalctl-fixture",
             FIXTURES["sshKeygen"], str(self.root / "sudo")],
            env=os.environ | {"KEY_OPERATIONS": str(self.log), "JOURNAL": journal} | extra,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def record(self):
        return "fixture-pin " + " ".join(FIXTURES["publicKey"].split()[:2]) + "\n"

    def test_creates_private_file_and_repeated_calls_are_idempotent(self):
        result = self.call()
        self.assertEqual(result.stdout, self.record())
        self.assertIn("Saved:", result.stderr)
        self.assertEqual(self.known.read_text(), self.record())
        self.assertEqual(stat.S_IMODE(self.known.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.known.parent.stat().st_mode), 0o700)
        result = self.call()
        self.assertEqual(result.stdout, self.record())
        self.assertIn("Already trusted:", result.stderr)
        self.assertEqual(self.known.read_text(), self.record())

    def test_preserves_other_entries_and_adds_a_missing_newline(self):
        self.known.parent.mkdir(parents=True)
        original = ("other-host " + FIXTURES["publicKey"].strip()).encode()
        self.known.write_bytes(original)
        self.call()
        self.assertEqual(self.known.read_bytes(), original + b"\n" + self.record().encode())
        self.assertEqual(stat.S_IMODE(self.known.stat().st_mode), 0o600)

    def test_existing_hashed_pin_is_recognized_without_rewriting(self):
        self.known.parent.mkdir(parents=True)
        self.known.write_text(self.record())
        subprocess.run([FIXTURES["sshKeygen"], "-H", "-f", str(self.known)],
                       capture_output=True, check=True)
        original = self.known.read_bytes()
        result = self.call()
        self.assertIn("Already trusted:", result.stderr)
        self.assertEqual(self.known.read_bytes(), original)

    def test_different_or_revoked_pins_are_preserved(self):
        key = self.root / "different-key"
        subprocess.run([FIXTURES["sshKeygen"], "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        self.known.parent.mkdir(parents=True)
        for content in (
            "fixture-pin " + key.with_suffix('.pub').read_text(),
            "@revoked " + self.record(),
        ):
            with self.subTest(content=content):
                self.known.write_text(content)
                result = self.call(code=1)
                self.assertIn("different or revoked key", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.known.read_text(), content)

    def test_stopped_unready_conflicting_and_changed_boots_do_not_create_files(self):
        for extra, message in (
            ({"UNIT_STATE": "inactive"}, "not running"),
            ({"JOURNAL": "no key record"}, "no host key published"),
            ({"JOURNAL": "AGENT_SSH_HOST_KEY other " + FIXTURES["publicKey"]}, "no host key published"),
            ({"JOURNAL": "AGENT_SSH_HOST_KEY work " + FIXTURES["publicKey"] + "\nAGENT_SSH_HOST_KEY work ssh-ed25519 AAAA\n"}, "conflicting"),
            ({"CHANGED_BOOT": "1"}, "restarted"),
            ({"JOURNAL_FAIL": "1"}, "Could not trust"),
            ({"JOURNAL": "AGENT_SSH_HOST_KEY work ssh-ed25519 AAAA\n"}, "Could not trust"),
        ):
            with self.subTest(extra=extra):
                result = self.call(code=1, **extra)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.known.parent.exists())

    def test_symlinked_known_hosts_file_is_not_followed(self):
        target = self.root / "unrelated"
        target.write_text("keep this file")
        self.known.parent.mkdir(parents=True)
        self.known.symlink_to(target)
        result = self.call(code=1)
        self.assertIn("regular file owned by you", result.stderr)
        self.assertEqual(target.read_text(), "keep this file")
        self.assertTrue(self.known.is_symlink())


if __name__ == "__main__":
    unittest.main()
