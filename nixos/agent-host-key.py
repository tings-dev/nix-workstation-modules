"""Trust a guest's public SSH server key from its current host-side console."""

import fcntl
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def invocation(systemctl, unit):
    result = subprocess.run(
        [systemctl, "show", unit, "-p", "ActiveState", "-p", "InvocationID"],
        check=True, capture_output=True, text=True,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines())
    identity = fields.get("InvocationID", "")
    if fields.get("ActiveState") != "active" or not re.fullmatch(
        r"[a-f0-9]{32}", identity,
    ):
        raise ValueError("guest is not running; start it and retry")
    return identity


def console_key(name, systemctl, journalctl, sudo):
    unit = f"microvm@{name}.service"
    identity = invocation(systemctl, unit)
    # Inherit stderr so sudo can display its authentication prompt. Only the
    # console text is captured, and the query is restricted to this boot/unit.
    result = subprocess.run(
        [sudo, journalctl, f"_SYSTEMD_INVOCATION_ID={identity}",
         "-u", unit, "-o", "cat", "--no-pager", "--quiet"],
        check=True, stdout=subprocess.PIPE, text=True,
    )
    pattern = (
        r"AGENT_SSH_HOST_KEY " + re.escape(name)
        + r" (ssh-ed25519 [A-Za-z0-9+/]+={0,2})(?:\s|$)"
    )
    keys = set(re.findall(pattern, result.stdout))
    if not keys:
        raise ValueError(
            "no host key published for this boot yet; wait for "
            "SSH readiness and retry"
        )
    if len(keys) != 1:
        raise ValueError("this boot published conflicting host keys")
    if invocation(systemctl, unit) != identity:
        raise ValueError("guest restarted while reading its key; retry")
    return keys.pop()


def save_key(known_hosts, alias, key, ssh_keygen):
    known_hosts.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Keep the lock inode stable while replacing the data file atomically.
    lock = known_hosts.with_name(known_hosts.name + ".lock")
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        content = b""
        if known_hosts.exists() or known_hosts.is_symlink():
            info = known_hosts.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise ValueError(
                    f"{known_hosts}: expected a regular file owned by you"
                )
            content = known_hosts.read_bytes()
            found = subprocess.run(
                [ssh_keygen, "-F", alias, "-f", str(known_hosts)],
                capture_output=True, text=True, errors="replace",
            )
            if found.returncode not in (0, 1):
                raise ValueError(f"cannot inspect {known_hosts}")
            if found.returncode == 0:
                records = [line.split() for line in found.stdout.splitlines()
                           if line and not line.startswith("#")]
                if not records or any(
                    len(record) < 3 or record[0].startswith("@")
                    or record[1:3] != key.split() for record in records
                ):
                    raise ValueError(
                        f"a different or revoked key is pinned for {alias} "
                        f"in {known_hosts}; existing entries were left "
                        "unchanged. Review the guest's current console key "
                        "before removing its old pin after a deliberate reset."
                    )
                return False
        if content and not content.endswith(b"\n"):
            content += b"\n"
        content += f"{alias} {key}\n".encode()
        descriptor, temporary = tempfile.mkstemp(
            prefix=".agent-env-known-hosts-", dir=known_hosts.parent,
        )
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, known_hosts)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return True


def trust(name, known_hosts, alias, systemctl, journalctl, ssh_keygen, sudo):
    if re.fullmatch(r"[a-z][a-z0-9-]{0,11}", name) is None:
        raise ValueError("invalid agent environment name")
    if re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]*", alias) is None:
        raise ValueError("invalid SSH host-key alias")
    key = console_key(name, systemctl, journalctl, sudo)
    # Validate the key itself before creating or modifying any trust files.
    fingerprint = subprocess.run(
        [ssh_keygen, "-l", "-f", "/dev/stdin"],
        input=f"{alias} {key}\n", capture_output=True, text=True, check=True,
    ).stdout.strip()
    added = save_key(Path(known_hosts), alias, key, ssh_keygen)
    action = "Saved" if added else "Already trusted"
    print(f"{action}: {fingerprint}\nKnown-hosts file: {known_hosts}",
          file=sys.stderr)
    print(f"{alias} {key}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 8:
            raise ValueError(
                "expected NAME KNOWN_HOSTS HOST_KEY_ALIAS "
                "SYSTEMCTL JOURNALCTL SSH_KEYGEN SUDO"
            )
        trust(*sys.argv[1:])
    except subprocess.CalledProcessError as error:
        sys.exit(f"Could not trust guest host key: {error}")
    except (OSError, ValueError) as error:
        sys.exit(f"Could not trust guest host key: {error}")
