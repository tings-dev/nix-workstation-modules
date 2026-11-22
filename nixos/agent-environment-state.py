"""Privileged operations on the state of explicitly declared environments."""

import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run(*arguments):
    return subprocess.run(
        arguments, capture_output=True, text=True, check=True,
    )


def checked_directory(path):
    # Reject symlinks in every component, even for an already absent guest.
    if path.resolve() != path:
        raise ValueError(f"{path}: symlink or non-canonical state path")
    if path.exists() and not path.is_dir():
        raise ValueError(f"{path}: expected a directory")


def check_idle(config, path):
    checked_directory(path)
    # Refuse bind mounts too, including those on the same filesystem. rmtree
    # never follows symlinks, but would otherwise descend into mounted shares.
    with open("/proc/self/mountinfo") as stream:
        for line in stream:
            mountpoint = Path(re.sub(
                r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), line.split()[4]
            ))
            if mountpoint == path or path in mountpoint.parents:
                raise ValueError(f"{path}: contains mount {mountpoint}")
    if not path.exists():
        return
    result = subprocess.run(
        [config["lsof"], "-t", "+D", str(path)],
        capture_output=True, text=True,
    )
    # lsof exits 1 for no matches. Warnings (e.g. inaccessible filesystems)
    # are not proof that a disk has no owners; fail closed on those as well.
    if result.returncode != 1 or result.stdout or result.stderr:
        raise ValueError(
            f"{path}: open files or incomplete lsof inspection\n"
            f"{result.stdout}{result.stderr}"
        )


def delete(config, name, state):
    systemctl = config["systemctl"]
    units = [f"microvm@{name}.service", f"install-microvm-{name}.service"]
    paths = [state, Path(config["runtimeDir"]) / f"agent-shares-{name}"]
    roots = [Path(config["gcRootsDir"]) / prefix for prefix in (
        name, f"booted-{name}", f"old-{name}",
    )]
    masked = []
    try:
        # Block direct starts of the template instance during deletion. The
        # installer is stopped below; deployments must not race deletion.
        # Unlike the instance, the installer has an /etc unit file, which takes
        # precedence over a --runtime mask. Preserve existing operator masks.
        for unit in units[:1]:
            load = run(systemctl, "show", unit, "-p", "LoadState", "--value")
            if load.stdout.strip() != "masked":
                run(systemctl, "mask", "--runtime", unit)
                masked.append(unit)
                load = run(
                    systemctl, "show", unit, "-p", "LoadState", "--value",
                )
                if load.stdout.strip() != "masked":
                    raise ValueError(f"{unit}: runtime mask ineffective")
        run(systemctl, "stop", *units)
        # Stopping the VM also stops its PartOf TAP/virtiofs/booted services.
        for unit in units:
            active = run(
                systemctl, "show", unit, "-p", "ActiveState", "--value",
            )
            if active.stdout.strip() != "inactive":
                raise ValueError(f"{unit}: did not become inactive")
        # Complete all checks before deleting any selected state.
        for path in paths:
            check_idle(config, path)
        for root in roots:
            checked_directory(root.parent)
            if root.exists() and not root.is_symlink():
                raise ValueError(f"{root}: expected a GC-root symlink")
        for path in paths:
            if path.exists():
                shutil.rmtree(path)
        for root in roots:
            root.unlink(missing_ok=True)
    finally:
        if masked:
            run(systemctl, "unmask", "--runtime", *masked)
    print(f"Deleted private state for {name}. Its declaration is unchanged.")


def manage(config, action, name):
    if (name not in config["names"]
            or re.fullmatch(r"[a-z][a-z0-9-]{0,11}", name) is None):
        raise ValueError(f"Unknown agent environment: {name}")
    if action not in ("start", "restart", "delete"):
        raise ValueError(f"Unknown state operation: {action}")
    state = Path(config["stateDir"]) / name
    # Serialize starts, restarts and deletes. Leave the lock inode in
    # place so waiters always lock the same file; it contains no guest state.
    lock = Path(config["lockDir"]) / f"agent-env-{name}.lock"
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        checked_directory(state)
        if action == "delete":
            delete(config, name, state)
        else:
            if action == "restart":
                # Stop all PartOf services before selecting the latest runner
                # so the VM and its exports use the same configuration.
                run(config["systemctl"], "stop", f"microvm@{name}.service")
            # The upstream installer assumes its working directory exists.
            run(config["tmpfiles"], "--create", f"--prefix={state}")
            run(
                config["systemctl"], "start",
                f"install-microvm-{name}.service",
            )
            run(config["systemctl"], "start", f"microvm@{name}.service")


if __name__ == "__main__":
    try:
        if os.geteuid() != 0:
            raise ValueError("must run as root")
        if len(sys.argv) != 4:
            raise ValueError("expected MANIFEST {start|restart|delete} NAME")
        with open(sys.argv[1]) as manifest:
            manage(json.load(manifest), sys.argv[2], sys.argv[3])
    except subprocess.CalledProcessError as error:
        sys.exit(
            f"Agent environment command failed: {error}\n"
            f"{error.stdout or ''}{error.stderr or ''}"
        )
    except (OSError, ValueError) as error:
        sys.exit(f"Agent environment state operation failed: {error}")
