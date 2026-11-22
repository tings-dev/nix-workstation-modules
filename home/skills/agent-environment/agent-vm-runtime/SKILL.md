---
name: agent-vm-runtime
description: Use rootless containers and user services, inspect persistent/shared state, or handle baseline changes and credentials inside this repository's agent VMs.
---

# Runtime operations inside an agent VM

Run development sessions as `agent`. The separate `operator` account is for
human administration. Read the section relevant to the current operation.

## Containers and user services

Use rootless `podman`; `docker` is its compatibility wrapper:

```sh
podman info --format '{{.Host.Security.Rootless}}'
podman run --rm docker.io/library/alpine:latest echo ready
```

Container storage and named volumes persist. Pin image digests for reproducible
work. Bind mounts can modify shared host files. The physical host's container
socket and Nix daemon are not shared with the VM.

Put your own service definitions in `~/.config/systemd/user/`, then use:

```sh
systemctl --user daemon-reload
systemctl --user enable --now NAME.service
journalctl --user -u NAME.service
```

Replace `NAME.service` with your unit's name. User lingering keeps services
running after logout; enabled services start on VM boot. VM stops terminate
processes. Resume supported agents explicitly after a restart; saved state does
not imply the original process survived.

## Storage and cleanup

Use `findmnt -T PATH` to distinguish private storage from shared folders before
broad cleanup; shares can appear anywhere, including below home. Writable shares
modify the physical host's originals immediately. Limit cleanup to identified
task-owned files, taking other sessions' work into account. Never reset the VM
by recursively deleting home: that can traverse shares.

Home files, Nix profiles/store, dependencies, containers and SSH/VPN identities
survive ordinary updates and restarts. `/tmp` and `/run` are temporary. A disk
reset is destructive operator work, separate from updating the baseline.

## Baseline changes

Home Manager owns managed shell files, skills and the canonical
`~/.codex/AGENTS.md`. Customize unmanaged files and user profiles. Propose changes
to managed files in the workstation repository instead of running a competing
Home Manager activation. Baseline activation merges selected Codex preferences;
other guest-local provider settings remain mutable.

The operator reviews and deploys from a checkout outside writable shares, then
restarts the VM. Routine updates preserve the private disk. Changes to shares,
resources, networking and system services follow the same deployment boundary.

## Credentials and network access

Authenticate providers inside the VM; keep tokens in private guest-local files,
outside Git, Nix expressions, store paths and shared folders. Use the existing
guest-generated outgoing SSH identity. Have the operator authorize its public
key on needed targets; preserve the identity during ordinary work. Personal
host credentials and SSH-agent forwarding are not available.

Public internet access is available, while direct host/LAN access is restricted.
VPN access depends on explicit grants and guest-local enrollment. Request
operator configuration changes when new access is needed. Deleting local keys,
logging out or stopping the VM does not revoke credentials already exported;
revocation happens at the provider or authorized target.
