import ctypes
import json
import os
import re
import sys


def open_share(share):
    source = share["source"]
    descriptor = os.open("/", os.O_PATH | os.O_DIRECTORY)
    try:
        # Pin every component without following symlinks, including during
        # concurrent renames. The resulting descriptor is the export authority.
        for part in source.split("/")[1:]:
            child = os.open(
                part,
                os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        if (info.st_uid, info.st_gid) != (share["hostUid"], share["hostGid"]):
            raise ValueError(f"{source}: owner must match hostUid:hostGid")
        return descriptor
    except (OSError, ValueError):
        os.close(descriptor)
        raise


def mount(source, target, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mount.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_ulong,
        ctypes.c_void_p,
    ]
    if libc.mount(source, target, None, flags, None) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), os.fsdecode(target))


def backing_path(descriptor):
    # Bind-mounted aliases have different visible paths but the same backing
    # filesystem path. Include that path when rejecting overlapping exports.
    with open(f"/proc/self/fdinfo/{descriptor}") as stream:
        mount_id = next(
            line.split()[1] for line in stream if line.startswith("mnt_id:")
        )
    with open("/proc/self/mountinfo") as stream:
        fields = next(
            line.split() for line in stream if line.split()[0] == mount_id
        )
    root, mountpoint = [
        re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), value)
        for value in fields[3:5]
    ]
    visible = os.readlink(f"/proc/self/fd/{descriptor}")
    relative = os.path.relpath(visible, mountpoint)
    if relative == ".." or relative.startswith("../"):
        raise ValueError("source moved outside its mount during validation")
    return os.path.normpath(os.path.join(root, relative))


def export(manifest, export_root, backend, arguments):
    with open(manifest) as stream:
        shares = json.load(stream)
    source_arg = next(
        arg for arg in arguments if arg.startswith("--shared-dir=")
    )
    source = source_arg.removeprefix("--shared-dir=")
    # Open descriptors in the namespace where they will be bind-mounted;
    # Linux refuses a bind from an FD belonging to the previous namespace.
    os.unshare(os.CLONE_NEWNS)
    mount(None, b"/", (1 << 18) | (1 << 14))  # MS_PRIVATE | MS_REC
    descriptors = []
    try:
        identities = []
        selected = None
        # Validate the entire grant set before exporting any of it.
        for share in shares:
            descriptor = open_share(share)
            descriptors.append(descriptor)
            info = os.fstat(descriptor)
            backing = backing_path(descriptor)
            for device, inode, path in identities:
                if device == info.st_dev and (
                    inode == info.st_ino
                    or os.path.commonpath([path, backing]) in [path, backing]
                ):
                    raise ValueError(
                        f"{share['source']}: overlaps another share"
                    )
            identities.append((info.st_dev, info.st_ino, backing))
            if share["source"] == source:
                selected = descriptor
        if selected is None:
            raise ValueError(f"{source}: not a declared share")
        # A non-recursive bind excludes host submounts. Mounting the pinned FD
        # at a root-owned path also closes the validation-to-backend path race.
        mount(
            f"/proc/self/fd/{selected}".encode(),
            os.fsencode(export_root),
            1 << 12,
        )  # MS_BIND, deliberately not MS_REC
        arguments[arguments.index(source_arg)] = f"--shared-dir={export_root}"
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
    # virtiofsd applies its own namespace/pivot_root sandbox, seccomp, ID
    # translation and read-only policy to this pinned, non-recursive export.
    os.execv(backend, [backend, *arguments])


if __name__ == "__main__":
    try:
        export(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
    except (OSError, ValueError, StopIteration) as error:
        sys.exit(f"Invalid agent share: {error}")
