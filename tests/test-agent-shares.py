import shlex

start_all()
host.wait_for_unit("multi-user.target")
host.fail("agent-env delete unknown")
host.fail("agent-env delete alpha extra-argument")
host.succeed("test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm")
host.succeed("install -d -m 700 /root/.ssh")
host.succeed("install -m 600 /etc/agent-test-key /root/.ssh/id_ed25519")
project = "/tmp/agent-share-test/work alpha"
reference = "/srv/agent-share-test/reference"
beta = "/srv/agent-share-test/beta"
ungranted = "/srv/agent-share-test/ungranted"
for directory, uid, gid in [(project, 1234, 2345), (reference, 1234, 2345), (beta, 1235, 2346)]:
    host.succeed(f"install -d -o {uid} -g {gid} -m 700 {shlex.quote(directory)}")
host.succeed(f"mkdir -p {ungranted}")
host.succeed(f"echo host-secret > {ungranted}/secret")
host.succeed("mkdir -p /home/operator/.ssh /home/operator/.config/agent")
host.succeed("echo personal-key > /home/operator/.ssh/id_ed25519")
host.succeed("echo personal-token > /home/operator/.config/agent/auth.json")
for directory in [project, reference, beta]:
    host.succeed(f"echo host-original > {shlex.quote(directory + '/host-file')}")
    host.succeed(f"chown --reference={shlex.quote(directory)} {shlex.quote(directory + '/host-file')}")
for target, link in [
    ("host-file", "internal"),
    (f"{ungranted}/secret", "absolute-escape"),
    ("../ungranted/secret", "relative-escape"),
    ("/home/operator/.ssh/id_ed25519", "personal-key"),
    ("/home/operator/.config/agent/auth.json", "personal-token"),
    ("/nix/var/nix/daemon-socket/socket", "nix-socket"),
    ("/run/docker.sock", "container-socket"),
]:
    host.succeed(f"ln -s {shlex.quote(target)} {shlex.quote(project + '/' + link)}")
# A host submount must not silently add another directory to the grant.
host.succeed(f"mkdir {shlex.quote(project + '/nested')}")
host.succeed(f"mount --bind {ungranted} {shlex.quote(project + '/nested')}")
# A socket inode in a share must not provide a connection to a host service.
listener = (
    "import socket,time; s=socket.socket(socket.AF_UNIX); "
    f"s.bind({project + '/host-control.sock'!r}); s.listen(); time.sleep(1800)"
)
host.succeed("systemd-run --unit=share-test-listener python3 -c " + shlex.quote(listener))
host.wait_until_succeeds("test -S " + shlex.quote(project + "/host-control.sock"))
host.succeed(f"chmod 777 {shlex.quote(project + '/host-control.sock')}")


def ssh(name, command, root=False):
    if not root:
        return f"timeout 30 agent-env ssh {name} " + shlex.quote(command)
    link_id = {"alpha": 104, "beta": 105}[name]
    return (
        "timeout 30 ssh -F /dev/null -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/root/.ssh/agent-environments_known_hosts "
        f"-o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=agent-env-{name} "
        f"-o ForwardAgent=no -o ConnectTimeout=5 root@10.83.{link_id}.2 "
        + shlex.quote(command)
    )


def run(name, command, root=False):
    return host.succeed(ssh(name, command, root))


def start(name):
    host.succeed(f"agent-env start {name}", timeout=720)
    invocation = host.succeed(f"systemctl show microvm@{name} -p InvocationID --value").strip()
    console = f"journalctl _SYSTEMD_INVOCATION_ID={invocation} -o cat --no-pager"
    host.wait_until_succeeds(console + f" | grep 'AGENT_SSH_HOST_KEY {name} '")
    host.succeed(
        console
        + " | sed -n 's/.*AGENT_SSH_HOST_KEY " + name
        + r" \(ssh-ed25519 [^ ]*\).*/agent-env-" + name
        + r" \1/p' | head -n 1 >> /root/.ssh/agent-environments_known_hosts"
    )
    run(name, "systemctl is-active home-manager-agent.service")


def boundary():
    for root in [False, True]:
        for link in ["absolute-escape", "relative-escape", "personal-key", "personal-token", "nix-socket", "container-socket"]:
            host.fail(ssh("alpha", f"cat /workspace/project/{link}", root))
        host.fail(ssh("alpha", "cat /workspace/project/nested/secret", root))
        for path in [ungranted + "/secret", beta + "/host-file", "/home/operator/.ssh/id_ed25519"]:
            host.fail(ssh("alpha", "cat " + shlex.quote(path), root))
        host.fail(ssh("beta", "cat /workspace/project/host-file", root))
        host.fail(ssh("beta", "cat /workspace/reference/host-file", root))
        host.fail(ssh("beta", "cat /tmp/agent-share-test/'work alpha'/host-file", root))
        connect = "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/workspace/project/host-control.sock')"
        host.fail(ssh("alpha", "python3 -c " + shlex.quote(connect), root))
        for command in [
            "touch /workspace/reference/new",
            "echo changed > /workspace/reference/host-file",
            "truncate -s 0 /workspace/reference/host-file",
            "chmod 777 /workspace/reference/host-file",
            "chown 2000 /workspace/reference/host-file",
            "mv /workspace/reference/host-file /workspace/reference/moved",
            "rm /workspace/reference/host-file",
            "ln /workspace/reference/host-file /workspace/reference/hardlink",
            "ln -s host-file /workspace/reference/symlink",
            "mkdir /workspace/reference/subdirectory",
        ]:
            host.fail(ssh("alpha", command, root))
    assert host.succeed(f"cat {reference}/host-file").strip() == "host-original"
    host.succeed(f"test ! -e {reference}/new && test ! -e {reference}/moved")


start("alpha")
start("beta")
assert run("alpha", "cat /workspace/project/internal").strip() == "host-original"
assert run("alpha", "cat /workspace/reference/host-file").strip() == "host-original"
assert run("alpha", "stat -c %u:%g /workspace/project").strip() == "1000:1000"
assert run("beta", "stat -c %u:%g ~/project").strip() == "1000:1000"
run("alpha", "echo guest-write > /workspace/project/host-file; echo guest-created > /workspace/project/new")
assert host.succeed("cat " + shlex.quote(project + "/host-file")).strip() == "guest-write"
assert host.succeed("cat " + shlex.quote(project + "/new")).strip() == "guest-created"
assert host.succeed("stat -c %u:%g " + shlex.quote(project + "/new")).strip() == "1234:2345"
host.succeed("echo host-edited > " + shlex.quote(project + "/new"))
assert run("alpha", "cat /workspace/project/new").strip() == "host-edited"
run("alpha", "mkdir /workspace/project/guest-dir; ln -s new /workspace/project/guest-link")
assert host.succeed("readlink " + shlex.quote(project + "/guest-link")).strip() == "new"
assert host.succeed("stat -c %u:%g " + shlex.quote(project + "/guest-dir")).strip() == "1234:2345"
run("alpha", "echo root-write > /workspace/project/root-created; chown 0:0 /workspace/project/root-created", True)
assert host.succeed("stat -c %u:%g " + shlex.quote(project + "/root-created")).strip() == "1234:2345"
run("beta", "echo beta-only > ~/project/new; echo private-beta > ~/private-marker")
run("alpha", "echo private-alpha > ~/private-marker")
assert host.succeed(f"stat -c %u:%g {beta}/new").strip() == "1235:2346"
# Guest root can explicitly request rw on a second mount; the export remains RO.
run("alpha", "mkdir -p /mnt/hostile; mount -t virtiofs -o rw share-reference /mnt/hostile", True)
host.fail(ssh("alpha", "echo root-bypass > /mnt/hostile/host-file", True))
run("alpha", "umount /mnt/hostile", True)
host.fail(ssh("beta", "mkdir -p /mnt/hostile; mount -t virtiofs share-reference /mnt/hostile", True))
boundary()

# Replacing a host path while running does not redirect the pinned export.
host.succeed("mv " + shlex.quote(project) + " " + shlex.quote(project + ".saved"))
host.succeed("ln -s " + shlex.quote(ungranted) + " " + shlex.quote(project))
assert run("alpha", "cat /workspace/project/new").strip() == "host-edited"
host.fail(ssh("alpha", "cat /workspace/project/secret", True))
host.succeed("rm " + shlex.quote(project))
host.succeed("mv " + shlex.quote(project + ".saved") + " " + shlex.quote(project))

for name in ["alpha", "beta"]:
    host.succeed(f"agent-env stop {name}", timeout=180)
    host.wait_until_succeeds(f"test ! -e /run/agent-shares-{name}", timeout=30)
    host.succeed(f"agent-env start {name}", timeout=720)
    assert run(name, "cat ~/private-marker").strip() == f"private-{name}"
assert run("alpha", "cat /workspace/project/new").strip() == "host-edited"
assert run("beta", "cat ~/project/new").strip() == "beta-only"
boundary()
for name in ["alpha", "beta"]:
    host.succeed(f"agent-env stop {name}", timeout=180)

# Delete both complete local state directories through the production helper
# while the other guest stays running. Shared folders must survive recreation.
start("alpha")
start("beta")
for name, other in [("beta", "alpha"), ("alpha", "beta")]:
    old_server = run(name, "cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    old_client = host.succeed(f"agent-env public-ssh-key {name}").strip()
    other_server = run(other, "cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    other_client = host.succeed(f"agent-env public-ssh-key {other}").strip()
    other_invocation = host.succeed(f"systemctl show microvm@{other} -p InvocationID --value").strip()
    run(other, "echo unrelated-private-state > ~/unrelated-marker")
    # Disposable markers only: no real provider login or VPN enrollment.
    run(name, "mkdir -p ~/.config/provider; echo fixture-token > ~/.config/provider/auth.json")
    run(name, "mkdir -p /var/lib/tailscale /var/lib/netbird; "
        "echo fixture-tailscale > /var/lib/tailscale/reset-fixture; "
        "echo fixture-netbird > /var/lib/netbird/reset-fixture", True)
    host.succeed(f"agent-env delete {name}", timeout=180)
    host.succeed(f"test \"$(systemctl show microvm@{name} -p ActiveState --value)\" = inactive")
    host.succeed(f"test ! -e /var/lib/microvms/{name} && test ! -e /run/agent-shares-{name}")
    host.succeed(f"agent-env delete {name}")  # absent state is harmless
    if name == "beta":
        # Reapplying the declaration reinstalls the runner, not the private disk.
        host.succeed("/run/current-system/bin/switch-to-configuration test", timeout=180)
        host.succeed(f"test -L /var/lib/microvms/{name}/current")
        host.succeed(f"test ! -e /var/lib/microvms/{name}/private.img")
        host.fail(f"systemctl is-active microvm@{name}.service")
    # Old trust must reject the fresh guest before replacing only its pin.
    host.succeed(f"agent-env start {name}", timeout=720)
    host.fail(ssh(name, "true"))
    host.succeed(f"ssh-keygen -R agent-env-{name} -f /root/.ssh/agent-environments_known_hosts")
    start(name)
    assert run(name, "cat /etc/ssh/ssh_host_ed25519_key.pub").strip() != old_server
    assert host.succeed(f"agent-env public-ssh-key {name}").strip() != old_client
    run(name, "test ! -e ~/private-marker && test ! -e ~/unrelated-marker && test ! -e ~/.config/provider/auth.json")
    run(name, "test ! -e /var/lib/tailscale/reset-fixture && test ! -e /var/lib/netbird/reset-fixture", True)
    assert host.succeed(f"systemctl show microvm@{other} -p InvocationID --value").strip() == other_invocation
    assert run(other, "cat ~/unrelated-marker").strip() == "unrelated-private-state"
    assert run(other, "cat /etc/ssh/ssh_host_ed25519_key.pub").strip() == other_server
    assert host.succeed(f"agent-env public-ssh-key {other}").strip() == other_client
    assert run("alpha", "cat /workspace/project/new").strip() == "host-edited"
    assert run("alpha", "cat /workspace/reference/host-file").strip() == "host-original"
    assert run("beta", "cat ~/project/new").strip() == "beta-only"
    assert host.succeed("cat /home/operator/.ssh/id_ed25519").strip() == "personal-key"
    assert host.succeed("cat /home/operator/.config/agent/auth.json").strip() == "personal-token"
    assert host.succeed(f"cat {ungranted}/secret").strip() == "host-secret"
boundary()
for name in ["alpha", "beta"]:
    host.succeed(f"agent-env stop {name}", timeout=180)

# Runtime-invalid sources fail through the ordinary lifecycle interface.
# Use a shorter systemd startup timeout only in this disposable failure fixture.
host.succeed("mkdir -p /run/systemd/system/microvm-virtiofsd@alpha.service.d")
host.succeed("printf '[Service]\\nTimeoutStartSec=15s\\nRestart=no\\n' > /run/systemd/system/microvm-virtiofsd@alpha.service.d/test.conf")
host.succeed("systemctl daemon-reload")


def refused():
    host.fail("agent-env start alpha", timeout=60)
    host.fail("agent-env status alpha")
    host.succeed("journalctl -u microvm-virtiofsd@alpha -o cat --no-pager | grep 'Invalid agent share'")
    host.succeed("agent-env stop alpha", timeout=60)
    host.succeed("systemctl reset-failed")


host.succeed("mv " + shlex.quote(project) + " " + shlex.quote(project + ".saved"))
refused()  # missing directory
host.succeed("touch " + shlex.quote(project))
refused()  # ordinary file
host.succeed("rm " + shlex.quote(project))
host.succeed("ln -s " + shlex.quote(project + ".saved") + " " + shlex.quote(project))
refused()  # final component symlink
host.succeed("rm " + shlex.quote(project))
host.succeed("mv " + shlex.quote(project + ".saved") + " " + shlex.quote(project))
host.succeed("mv /tmp/agent-share-test /tmp/agent-share-test.saved; ln -s /tmp/agent-share-test.saved /tmp/agent-share-test")
refused()  # parent component symlink
host.succeed("rm /tmp/agent-share-test; mv /tmp/agent-share-test.saved /tmp/agent-share-test")
host.succeed("chown 1235:2346 " + shlex.quote(project))
refused()  # wrong owner
host.succeed("chown 1234:2345 " + shlex.quote(project))
host.succeed(f"mount --bind {shlex.quote(project)} {reference}")
refused()  # two paths aliasing the same directory
host.succeed(f"umount {reference}")
host.succeed(f"mount --bind {shlex.quote(project + '/guest-dir')} {reference}")
refused()  # a nested source hidden behind a bind-mounted alias
host.succeed(f"umount {reference}")
host.succeed("agent-env start alpha", timeout=720)
assert run("alpha", "cat /workspace/project/new").strip() == "host-edited"
host.succeed("agent-env stop alpha", timeout=180)
host.succeed("systemctl stop share-test-listener.service")
host.succeed("umount " + shlex.quote(project + "/nested"))
# No private-state cleanup or ordinary stop is allowed to delete shared data.
host.succeed("test -f " + shlex.quote(project + "/new"))
host.succeed(f"test -f {reference}/host-file && test -f {beta}/new && test -f {ungranted}/secret")
host.succeed("! lsof /var/lib/microvms/alpha/private.img /var/lib/microvms/beta/private.img")
