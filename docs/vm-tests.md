# VM tests

Keep large VM disks and test artifacts on disk-backed storage outside the host's
`$XDG_RUNTIME_DIR`. Reserve the runtime directory for sockets and small session
state. Keep its value unchanged for host D-Bus and SSH-agent connections.

## Before and during a run

1. Check the host runtime filesystem with `df -h "$XDG_RUNTIME_DIR"`.
2. Create a private working directory, for example
   `task_vm_dir=$(mktemp -d /var/tmp/workstation-modules-vm-test.XXXXXX)`.
   Verify its backing filesystem with `findmnt -T "$task_vm_dir"`.
   Proceed only when it is outside
   `$XDG_RUNTIME_DIR` and on disk-backed storage, rather than tmpfs or ramfs.
3. Prefer daemon-backed execution with `nix build -L` for the selected check.
   Verify the daemon's actual build workspace with `findmnt`; the client's
   `TMPDIR` does not select it. Proceed with VM execution only on disk-backed
   storage.

   Before any direct test-driver run, inspect that driver's state-directory
   selection. The pinned driver uses `XDG_RUNTIME_DIR` ahead of `TMPDIR`,
   regardless of its working directory or `-o` output option. Its CLI has no
   separate state-directory option. Use the daemon-backed check while keeping
   the host's `XDG_RUNTIME_DIR` unchanged. A direct harness needs an explicit
   disk-backed driver temporary directory before VM startup.
4. After startup, inspect the actual writable VM image paths. Confirm they are
   on disk-backed storage outside `$XDG_RUNTIME_DIR`; an output-directory option
   alone is insufficient evidence of disk placement.
5. Check `df -h "$XDG_RUNTIME_DIR"` during tests, especially disk creation and
   store seeding, and after failures. If usage grows unexpectedly, identify the
   writer and stop it before the runtime filesystem fills.

## Cleanup on success, failure or cancellation

Stop the disposable VMs through their test driver or service and wait for their
processes to exit. Check that no process still has each image open, using
`lsof -- /path/to/image` or `fuser -v -- /path/to/image` with sufficient privileges
to see its owners. An inaccessible process is not evidence that an image is idle.

After preserving any needed diagnostic logs, remove only the identified
disposable test files, including state retained by failed runs. Never remove an
image still used by a running VM. Finish by checking `df -h "$XDG_RUNTIME_DIR"`
and accounting for any retained test artifacts in the handoff.

## Runtime coverage

### Lifecycle and development

The network runtime check boots a disposable NixOS physical host with nested KVM and
deploys two guests using the production host module and extended production
guest composition. It uses nixpkgs' explicitly public disposable Ed25519 key,
temporary private disks, no shares and no enrollment. It exercises failed and
unknown starts, strict host-key and client authentication, account restrictions,
resource settings, blocked guest connections, and persistence through restart.
Controlled HTTP and DNS endpoints exercise successful public IPv4 egress and
return traffic, blocked private and explicitly protected public LANs sharing the
same uplink, alternate host addresses, other guests, and two simulated routed
host VPN links. The guest fixture alone allows root SSH with the disposable key
so tests can remove its firewall, spoof addresses and supply IPv6 routes and
neighbors. The production guest still forbids root SSH and sudo. Connection
outcomes are checked as both `agent` and root, after reload and stop/start, with
both guests present. A non-agent client retains its LAN and routed VPN access;
stopping the host firewall stops both guests. No real public service or VPN
enrollment is used by the test.
Its home fixtures omit the large development home bundle; the separate
development check uses the complete production development composition. It
boots a guest through `agent-env`, exercises tools, generic Linux runtime
libraries, project Nix shells/builds, persistent user packages, an offline Python
dependency, an agent-owned service and a rootless container volume over SSH.
Offline project source and build dependencies have explicit user-owned GC roots.
It switches the disposable physical host to a second guest configuration that
removes the original test fixtures, then checks installed packages and fresh
builds, verifies store contents, collects an unrooted package, and repeats checks
after restart. No host folders or provider credentials are required.

Both checks require actual nested KVM; a missing or unusable KVM device fails the test.
Evaluation and runner builds alone do **not** demonstrate a working boot.

### Shared folders

The runtime check boots a disposable physical host with two production-composed
agent environments, temporary host folders outside the projects tree, different
host UID/GID pairs and public disposable SSH keys. SSH probes cover two-way live
writes, new files/directories/symlinks, host ownership, privileged chown,
read-only mutation attempts and a privileged second read-write mount. They also
exercise internal and escaping symlinks, excluded host submounts, denied
credentials/control sockets/unrelated folders, distinct grants/private state,
pinned exports after a host path replacement, and preservation through restart.
Lifecycle starts reject missing/file/symlink/wrong-owner sources and bind aliases.
Configuration contracts cover malformed paths, invalid modes/IDs, overlaps and
reserved destinations. Each fixture replaces the operator's grants with its own
explicit grant set. Missing nested KVM fails the check; evaluation and runner
builds alone are not runtime validation.

### Herdr

The Herdr check exercises the production
guest composition inside a disposable KVM host. It drives JSON-RPC through real
SSH and `hc connect`, verifies guest execution and development tools, closes all
connections, observes work progressing with no logins, then reconnects to the
same live process. A VM restart separately checks persistent Core identity,
configuration, terminal records and SSH server identity, and confirms the old
process has ended. It uses disposable keys and no host shares or provider login.

### VPN and services

The VPN check exercises Tailscale and NetBird separately and together inside
the guests. The services check uses a local ACME test server to verify
registration, HTTPS routing and certificate renewal.
