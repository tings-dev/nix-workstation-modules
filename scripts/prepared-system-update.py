"""Prepare one replaceable NixOS candidate; activate it only on request."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


SERVICE = "frkl-update-prepare.service"
CURRENT_SYSTEM = Path("/run/current-system")


class UpdateError(Exception):
    pass


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def run(*command, cwd=None, data=None, capture=False):
    result = subprocess.run(
        [str(part) for part in command], cwd=cwd, input=data,
        stdout=subprocess.PIPE if capture else None, check=True,
    )
    return result.stdout if capture else None


def atomic_write(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            if path.exists():
                os.fchmod(stream.fileno(), stat.S_IMODE(path.stat().st_mode))
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_json(path, value):
    atomic_write(path, (json.dumps(value, indent=2) + "\n").encode())


class Updates:
    def __init__(self, args):
        self.args = args
        self.repo = Path(args.repository).resolve()
        self.state = Path(args.state_dir).resolve()
        self.generations = self.state / "candidates"
        self.ready = self.state / "ready"
        self.last_run = self.state / "last-run.json"

    @contextmanager
    def locked(self):
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.state / "lock").open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise UpdateError("Preparation or Apply is already running; try again later.") from error
            yield

    def notify(self, title, message, urgency="normal"):
        try:
            subprocess.run(
                ["notify-send", "--app-name=System updates", f"--urgency={urgency}",
                 title, message], check=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Desktop notification unavailable: {error}", file=sys.stderr)

    def identity(self):
        if run("git", "ls-files", "--unmerged", cwd=self.repo, capture=True):
            raise UpdateError("Resolve the checkout's Git conflicts before preparing an update.")
        commit = run("git", "rev-parse", "HEAD", cwd=self.repo, capture=True).decode().strip()
        patch = run("git", "diff", "--binary", "--no-ext-diff", "--no-textconv",
                    commit, "--", cwd=self.repo, capture=True)
        fingerprint = hashlib.sha256(commit.encode() + b"\0" + patch).hexdigest()
        return commit, patch, fingerprint

    def candidate(self):
        if not self.ready.is_symlink():
            raise UpdateError("No prepared update. Run just prepare first.")
        candidate = self.ready.resolve(strict=True)
        if candidate.parent != self.generations or not candidate.name.startswith("candidate-"):
            raise UpdateError("Invalid candidate location.")
        metadata = json.loads((candidate / "metadata.json").read_text())
        if metadata["host"] != self.args.host or metadata["repository"] != str(self.repo):
            raise UpdateError("The candidate belongs to another host or checkout.")
        return candidate, metadata

    def cleanup(self, keep):
        # These are our own individual candidate directories, never the state root.
        for candidate in self.generations.iterdir():
            if (candidate != keep and candidate.name.startswith("candidate-")
                    and candidate.is_dir() and not candidate.is_symlink()):
                shutil.rmtree(candidate)

    def prepare(self):
        with self.locked():
            self.generations.mkdir(exist_ok=True)
            previous = self.ready.resolve() if self.ready.is_symlink() else None
            self.cleanup(previous)
            candidate = Path(tempfile.mkdtemp(prefix="candidate-", dir=self.generations))
            started = now()
            write_json(self.last_run, {"status": "preparing", "started_at": started})
            try:
                commit, patch, fingerprint = self.identity()
                source = candidate / "source"
                source.mkdir()
                archive = run("git", "archive", "--format=tar", commit,
                              cwd=self.repo, capture=True)
                run("tar", "-xf", "-", "-C", source, data=archive)
                if patch:
                    run("git", "apply", "--binary", "-", cwd=source, data=patch)
                if self.identity()[2] != fingerprint:
                    raise UpdateError("The checkout changed during the snapshot; prepare again.")
                original_lock = (source / "flake.lock").read_bytes()
                print(f"Updating inputs for {self.args.host} from {commit[:12]}", flush=True)
                run("nix", "flake", "update", cwd=source)
                run("nix", "build", "--no-write-lock-file", "--out-link", candidate / "system",
                    "--max-jobs", self.args.max_jobs, "--cores", self.args.cores,
                    f"path:{source}#nixosConfigurations.{self.args.host}.config.system.build.toplevel",
                    cwd=source)
                system = (candidate / "system").resolve(strict=True)
                if not (system / "bin/switch-to-configuration").is_file():
                    raise UpdateError("The build did not produce a NixOS system.")
                metadata = {
                    "host": self.args.host, "repository": str(self.repo),
                    "commit": commit, "fingerprint": fingerprint,
                    "original_lock_sha256": hashlib.sha256(original_lock).hexdigest(),
                    "prepared_lock_sha256": hashlib.sha256((source / "flake.lock").read_bytes()).hexdigest(),
                    "system": str(system), "started_at": started, "prepared_at": now(),
                }
                write_json(candidate / "metadata.json", metadata)
                replacement = self.state / "ready.new"
                replacement.unlink(missing_ok=True)
                replacement.symlink_to(candidate.relative_to(self.state))
                os.replace(replacement, self.ready)
                # The result link stays at its original absolute path: Nix's
                # indirect GC root therefore remains valid after publication.
                self.cleanup(candidate)
                write_json(self.last_run, {"status": "ready", "finished_at": now()})
            except (OSError, subprocess.SubprocessError, UpdateError) as error:
                if self.ready.resolve() != candidate:
                    shutil.rmtree(candidate)
                write_json(self.last_run, {"status": "failed", "finished_at": now(), "error": str(error)})
                self.notify("System update preparation failed",
                            f"Run journalctl --user -u {SERVICE}. The previous candidate is retained.", "critical")
                raise
            if system != CURRENT_SYSTEM.resolve():
                self.notify("System update ready", f"{self.args.host}: run njust apply {self.args.host} when convenient.")
            else:
                print("Prepared system is already current; no desktop notification sent.")
            print(f"Ready: {system}")

    def apply(self):
        with self.locked():
            candidate, metadata = self.candidate()
            if metadata.get("applied_at"):
                raise UpdateError("This candidate was already applied. Prepare a new update first.")
            if self.identity()[2] != metadata["fingerprint"]:
                raise UpdateError("The checkout changed since preparation. Run just prepare again; nothing was applied.")
            lock = self.repo / "flake.lock"
            if lock.is_symlink():
                raise UpdateError("Refusing to replace a symlinked flake.lock.")
            original_lock = lock.read_bytes()
            if hashlib.sha256(original_lock).hexdigest() != metadata["original_lock_sha256"]:
                raise UpdateError("flake.lock changed since preparation; prepare again.")
            prepared_lock = (candidate / "source/flake.lock").read_bytes()
            if hashlib.sha256(prepared_lock).hexdigest() != metadata["prepared_lock_sha256"]:
                raise UpdateError("The candidate lockfile changed; prepare again.")
            system = (candidate / "system").resolve(strict=True)
            if str(system) != metadata["system"] or not (system / "bin/switch-to-configuration").is_file():
                raise UpdateError("The candidate system is missing or changed; prepare again.")
            # --store-path bypasses evaluation/building while retaining the normal
            # NixOS generation, bootloader, activation and rollback machinery.
            system_changed = system != CURRENT_SYSTEM.resolve()
            run("sudo", self.args.rebuild_command, "switch", "--no-reexec", "--store-path", system)
            metadata["applied_at"] = now()
            write_json(candidate / "metadata.json", metadata)
            if self.identity()[2] != metadata["fingerprint"]:
                raise UpdateError(
                    f"System applied, but the checkout changed during activation. "
                    f"Merge {candidate / 'source/flake.lock'} manually; your checkout was preserved."
                )
            atomic_write(lock, prepared_lock)
            if system_changed:
                self.notify("System update applied", f"{self.args.host}: the prepared system is now active.")
            print("Applied the prepared system and copied its flake.lock into the checkout.")

    def status(self):
        if self.last_run.exists():
            print("Last preparation:", json.dumps(json.loads(self.last_run.read_text()), indent=2))
        if self.ready.is_symlink():
            candidate, metadata = self.candidate()
            print("Candidate:", json.dumps(metadata, indent=2))
            print("Snapshot:", candidate / "source")
            if not metadata.get("applied_at"):
                print("Checkout matches:", self.identity()[2] == metadata["fingerprint"])
            print("Package changes from the running system:", flush=True)
            changes = run("nix", "store", "diff-closures", "/run/current-system",
                          metadata["system"], capture=True).decode().strip()
            print(changes or "No package version or significant store-size changes.")
        else:
            print("No prepared update.")
        print(f"Logs: journalctl --user -u {SERVICE}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--rebuild-command", required=True)
    parser.add_argument("--max-jobs", default="1")
    parser.add_argument("--cores", default="2")
    parser.add_argument("action", choices=["start", "prepare", "status", "apply"])
    args = parser.parse_args()
    os.umask(0o077)
    updates = Updates(args)
    try:
        if args.action == "start":
            run("systemctl", "--user", "start", "--no-block", SERVICE)
            print("Preparation started in the background. Run just update-status for details.")
        else:
            getattr(updates, args.action)()
    except (OSError, ValueError, subprocess.SubprocessError, UpdateError) as error:
        print(f"System update: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
