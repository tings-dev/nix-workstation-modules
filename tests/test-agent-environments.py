import shlex

start_all()
host.wait_for_unit("multi-user.target")
# The host must reach network-online with every on-demand guest stopped.
# Networkd has no managed links yet; it must not block activation waiting for one.
host.succeed("timeout 10 systemctl start network-online.target")
# A missing or unusable nested KVM device is a failed runtime check, not a skip.
host.succeed("test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm")


def listing():
    rows = host.succeed("agent-env list").splitlines()
    assert rows[0].split() == ["NAME", "STATUS"]
    return dict(row.split() for row in rows[1:])


assert listing() == {"alpha": "stopped", "beta": "stopped"}
assert host.succeed("runuser -u nobody -- agent-env list") == host.succeed("agent-env list")
host.fail("agent-env list alpha")
host.fail("agent-env start unknown")
host.fail("agent-env status alpha")
host.succeed("systemctl mask --runtime microvm@alpha.service")
host.fail("agent-env start alpha")
host.succeed("systemctl unmask --runtime microvm@alpha.service")
host.succeed("install -d -m 700 /root/.ssh")
host.succeed("install -m 600 /etc/agent-test-key /root/.ssh/id_ed25519")
host.succeed("ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519_unattended.pub")
public_key_command = "agent-env public-ssh-key alpha 2>&1"
status, output = host.execute(public_key_command)
assert status != 0 and "agent-env trust-host-key alpha" in output, output
destinations.wait_for_unit("endpoint.service")
destinations.wait_for_unit("dnsmasq.service")
destinations.wait_for_unit("network.target")
destinations.wait_for_open_port(8080)
destinations.wait_for_unit("sshd.service")
target_host_key = destinations.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
host.succeed("ip address add 17.0.0.1/32 dev lo")


def http(address):
    return (
        "curl --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 2 "
        + shlex.quote(f"http://{address}:8080/")
    )


# Prove the targets really listen, through the same routes used by the guests.
for address in ["93.184.216.34", "192.168.50.2", "12.0.0.2", "14.0.0.2", "16.0.0.2", "[2001:db8:10::2]"]:
    assert "controlled-egress-ok" in host.succeed(http(address))

# Unrelated forwarded traffic must retain LAN/VPN access. This namespace is a
# controlled non-agent client; no personal networks or credentials are used.
host.succeed("ip netns add control")
host.succeed("ip link add control-host type veth peer name eth0 netns control")
host.succeed("ip addr add 172.31.10.1/30 dev control-host")
host.succeed("ip link set control-host up")
host.succeed("ip -n control addr add 172.31.10.2/30 dev eth0")
host.succeed("ip -n control link set eth0 up")
host.succeed("ip -n control route add default via 172.31.10.1")
host.succeed("ip -6 addr add fd83:999::1/64 dev control-host nodad")
host.succeed("ip -n control -6 addr add fd83:999::2/64 dev eth0 nodad")
host.succeed("ip -n control -6 route add default via fd83:999::1")


def unrelated_networking():
    for address in ["93.184.216.34", "192.168.50.2", "12.0.0.2", "14.0.0.2", "16.0.0.2", "[2001:db8:10::2]"]:
        assert "controlled-egress-ok" in host.succeed("ip netns exec control " + http(address))


unrelated_networking()
# Simulate another network manager's table, including a broad forwarding accept.
host.succeed("nft add table inet vpn_fixture")
host.succeed("nft 'add chain inet vpn_fixture forward { type filter hook forward priority 0; policy accept; }'")


def ssh(name, command):
    return "timeout 20 agent-env ssh " + name + " " + shlex.quote(command)


def root_ssh(name, command):
    link_id = {"alpha": 101, "beta": 102}[name]
    return (
        "timeout 20 ssh -F /dev/null -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/root/.ssh/agent-environments_known_hosts "
        f"-o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=agent-env-{name} "
        f"-o ForwardAgent=no -o ConnectTimeout=5 root@10.83.{link_id}.2 "
        + shlex.quote(command)
    )


def network_boundary(name):
    link_id = {"alpha": 101, "beta": 102}[name]
    other_id = 102 if name == "alpha" else 101
    # DNS is a real query to the controlled public resolver, not /etc/hosts.
    host.succeed(ssh(name, "getent ahostsv4 private.agent.test | grep -F 192.168.50.2"))
    host.succeed(ssh(name, "getent ahostsv4 protected.agent.test | grep -F 12.0.0.2"))
    for run in [ssh, root_ssh]:
        assert "controlled-egress-ok" in host.succeed(run(name, http("public.agent.test")))
        for address in ["private.agent.test", "protected.agent.test", "14.0.0.2", "16.0.0.2"]:
            host.fail(run(name, http(address)))
        # All these host addresses have a reachable SSH listener. Alternate
        # public, LAN and VPN addresses must not open a path back to the host.
        for address in [f"10.83.{link_id}.1", "11.0.0.1", "13.0.0.1", "15.0.0.1", "17.0.0.1"]:
            host.fail(run(name, f"timeout 2 bash -c 'echo > /dev/tcp/{address}/22'"))
        if listing()["beta" if name == "alpha" else "alpha"] == "running":
            host.fail(run(name, f"timeout 2 bash -c 'echo > /dev/tcp/10.83.{other_id}.2/22'"))
    # Remove the guest firewall and give root working IPv6 routes and a static
    # neighbor: failure must come from the host, not absent guest configuration.
    host.succeed(root_ssh(name, "nft flush ruleset"))
    host.succeed(f"ip -6 addr replace fd83:{link_id}::1/64 dev ae-{name}")
    host_mac = host.succeed(f"cat /sys/class/net/ae-{name}/address").strip()
    host.succeed(root_ssh(name, f"ip -6 addr replace fd83:{link_id}::2/64 dev eth0"))
    host.succeed(root_ssh(name, f"ip -6 neigh replace fd83:{link_id}::1 lladdr {host_mac} nud permanent dev eth0"))
    host.succeed(root_ssh(name, f"ip -6 route replace default via fd83:{link_id}::1"))
    host.succeed(root_ssh(name, "ip -6 route get 2001:db8:10::2"))
    for run in [ssh, root_ssh]:
        # Repeat IPv4 after removing guest filtering, and check IPv6 fail-closed.
        assert "controlled-egress-ok" in host.succeed(run(name, http("public.agent.test")))
        for address in ["192.168.50.2", "12.0.0.2", "14.0.0.2", "16.0.0.2", "[2001:db8:10::2]"]:
            host.fail(run(name, http(address)))
        host.fail(run(name, f"timeout 2 bash -c 'echo > /dev/tcp/fd83:{link_id}::1/22'"))
        host.fail(run(name, "timeout 2 bash -c 'echo > /dev/tcp/2001:db8:10::1/22'"))
        host.fail(run(name, "timeout 2 bash -c 'echo > /dev/tcp/17.0.0.1/22'"))
        if listing()["beta" if name == "alpha" else "alpha"] == "running":
            host.fail(run(name, f"timeout 2 bash -c 'echo > /dev/tcp/10.83.{other_id}.2/22'"))
    # A compromised guest cannot borrow another guest's source identity.
    host.succeed(root_ssh(name, f"ip addr replace 10.83.{other_id}.2/32 dev eth0"))
    host.fail(root_ssh(name, http("93.184.216.34").replace("curl ", f"curl --interface 10.83.{other_id}.2 ", 1)))
    host.succeed(root_ssh(name, f"ip addr del 10.83.{other_id}.2/32 dev eth0"))
    host.succeed(ssh(name, "true"))  # host-initiated SSH still works


def pin_key(name):
    console = f"journalctl -u microvm@{name}.service -o cat --no-pager"
    host.wait_until_succeeds(console + f" | grep 'AGENT_SSH_HOST_KEY {name} '")
    host.succeed(
        console
        + " | sed -n 's/.*AGENT_SSH_HOST_KEY "
        + name
        + r" \(ssh-ed25519 [^ ]*\).*/agent-env-"
        + name
        + r" \1/p' | head -n 1 >> /root/.ssh/agent-environments_known_hosts"
    )


outgoing_keys = {}
private_hashes = {}
age_recipients = {}


def client_identity(name):
    public_key = host.succeed(f"agent-env public-ssh-key {name}").strip()
    assert public_key.startswith("ssh-ed25519 "), public_key
    host.succeed(ssh(name, 'test "$(stat -c %U:%G:%a ~/.ssh)" = agent:agent:700'))
    host.succeed(
        ssh(name, 'test "$(stat -c %U:%G:%a ~/.ssh/id_ed25519)" = agent:agent:600')
    )
    host.succeed(
        ssh(name, 'test "$(stat -c %U:%G:%a ~/.ssh/id_ed25519.pub)" = agent:agent:644')
    )
    # Hashes prove private-file persistence without exporting its contents.
    digest = host.succeed(ssh(name, "sha256sum ~/.ssh/id_ed25519")).split()[0]
    assert (
        public_key.split()[:2]
        != host.succeed(ssh(name, "cat /etc/ssh/ssh_host_ed25519_key.pub")).split()[:2]
    )
    host.fail(ssh(name, 'test -n "${SSH_AUTH_SOCK:-}"'))
    host.fail(
        ssh(
            name,
            "ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null agent@127.0.0.1 true",
        )
    )
    return public_key, digest


for name in ["alpha", "beta"]:
    host.succeed(f"agent-env start {name}", timeout=720)
    host.succeed(f"agent-env status {name}")
    if name == "alpha":
        assert listing() == {"alpha": "running", "beta": "stopped"}
    else:
        assert listing() == {"alpha": "running", "beta": "running"}
    pin_key(name)
    if name == "alpha":
        # With a trusted guest, a missing or empty unattended agent must fail
        # even though the default private key is present.
        status, output = host.execute(public_key_command)
        assert status != 0 and "unavailable or disarmed" in output, output
        host.succeed("install -d -m 700 /run/user/0")
        host.succeed("ssh-agent -a /run/user/0/unattended-key.sock > /tmp/test-agent.env")
        status, output = host.execute(public_key_command)
        assert status != 0 and "unavailable or disarmed" in output, output
        host.succeed("SSH_AUTH_SOCK=/run/user/0/unattended-key.sock ssh-add /root/.ssh/id_ed25519")
    host.succeed(ssh(name, 'test "$(id -u)" = 1000 && test "$(id -un)" = agent'))
    if name == "alpha":
        host.succeed("SSH_AUTH_SOCK=/nonexistent " + ssh(name, "true"))
        host.succeed("SSH_AUTH_SOCK=/run/user/0/unattended-key.sock ssh-add -D")
        status, output = host.execute(ssh(name, "true") + " 2>&1")
        assert status != 0 and "unavailable or disarmed" in output, output
        host.succeed("SSH_AUTH_SOCK=/run/user/0/unattended-key.sock ssh-add /root/.ssh/id_ed25519")
        host.succeed(ssh(name, "true"))
    host.succeed(ssh(name, 'test "$(id -Gn)" = agent'))
    host.succeed(ssh(name, 'systemctl is-active home-manager-agent.service'))
    host.succeed(ssh(name, 'test -L ~/.bashrc'))
    host.succeed(ssh(name, 'test "$(ls /home)" = agent && test ! -e /run/docker.sock'))
    host.succeed(ssh(name, 'test ! -e /run/host && test ! -e /run/libvirt'))
    host.fail(ssh(name, "touch /etc/agent-must-not-write"))
    host.fail(ssh(name, "sudo -n true"))
    host.succeed(ssh(name, f"echo {name} > ~/private-marker"))
    host.succeed(ssh(name, f'test "$(cat ~/private-marker)" = {name}'))
    # Another connection proves the lifecycle outlives client disconnection.
    host.succeed(f"agent-env status {name}")
    host.succeed(ssh(name, "cat /etc/ssh/ssh_host_ed25519_key.pub") + f" > /tmp/{name}-host-key")
    outgoing_keys[name], private_hashes[name] = client_identity(name)
    age_recipients[name] = host.succeed(f"agent-env public-age-key {name}").strip()
    assert age_recipients[name].startswith("age1"), age_recipients[name]
    assert age_recipients[name] == host.succeed(
        ssh(name, "age-keygen -y ~/.config/sops/age/keys.txt")
    ).strip()
    # Repeated setup and missing-public-file recovery preserve private material.
    host.succeed(ssh(name, "chmod 644 ~/.ssh/id_ed25519 && rm ~/.ssh/id_ed25519.pub"))
    host.succeed(root_ssh(name, "systemctl restart agent-ssh-client-key.service"))
    assert client_identity(name) == (outgoing_keys[name], private_hashes[name])
    network_boundary(name)

assert outgoing_keys["alpha"] != outgoing_keys["beta"]
assert private_hashes["alpha"] != private_hashes["beta"]
assert age_recipients["alpha"] != age_recipients["beta"]
for action in ("public-ssh-key", "public-age-key"):
    host.fail(f"agent-env {action} alpha extra-argument")
    host.fail(f"agent-env {action} unknown")

# Trust the target from its authenticated test console, never ssh-keyscan.
host.succeed(
    ssh(
        "alpha",
        "printf '%s\\n' "
        + shlex.quote("93.184.216.34 " + target_host_key)
        + " > ~/.ssh/known_hosts",
    )
)
remote = (
    "ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes "
    "-o GlobalKnownHostsFile=/dev/null -o IdentityAgent=none -o IdentitiesOnly=yes "
    "-o ConnectTimeout=5 target@93.184.216.34 'id -un'"
)


def authorize_target(key):
    destinations.succeed(
        "printf '%s\\n' " + shlex.quote(key) + " > /var/lib/ssh-target/target"
    )


def denied_target():
    status, output = host.execute(ssh("alpha", remote) + " 2>&1")
    assert status == 255 and "Permission denied (publickey)" in output, (status, output)


denied_target()
authorize_target(outgoing_keys["beta"])
denied_target()  # Another environment's grant cannot authorize alpha.
authorize_target(outgoing_keys["alpha"])
assert host.succeed(ssh("alpha", remote)).strip() == "target"
destinations.succeed("rm /var/lib/ssh-target/target")
denied_target()
authorize_target(outgoing_keys["alpha"])
assert host.succeed(ssh("alpha", remote)).strip() == "target"

# With both guests up, repeat alpha's cross-environment checks too.
network_boundary("alpha")
host.succeed("systemctl reload nftables.service")
host.succeed("nft list table inet vpn_fixture")
unrelated_networking()
network_boundary("beta")

host.succeed(ssh("alpha", 'test "$(getconf _NPROCESSORS_ONLN)" = 1'))
host.succeed(ssh("beta", 'test "$(getconf _NPROCESSORS_ONLN)" = 2'))
host.succeed(ssh("alpha", "awk '/MemTotal/ { exit !($2 > 400000 && $2 < 525000) }' /proc/meminfo"))
host.succeed(ssh("beta", "awk '/MemTotal/ { exit !($2 > 650000 && $2 < 790000) }' /proc/meminfo"))
host.succeed(ssh("alpha", 'test "$(cat /sys/class/block/vdb/size)" = 16777216'))
host.succeed(ssh("beta", 'test "$(cat /sys/class/block/vdb/size)" = 25165824'))
host.fail("cmp /tmp/alpha-host-key /tmp/beta-host-key")

# Reachable listening services on the physical host and another guest remain
# denied from inside the guest, while host-initiated SSH already succeeded.
host.succeed(ssh("alpha", "! timeout 3 bash -c 'echo > /dev/tcp/10.83.101.1/22'"))
host.succeed(ssh("alpha", "! timeout 3 bash -c 'echo > /dev/tcp/10.83.102.2/22'"))

# Incoming authorization must reject a disposable, unauthorized client key.
host.succeed("ssh-keygen -q -t ed25519 -N '' -f /tmp/unauthorized-key")
host.succeed("SSH_AUTH_SOCK=/run/user/0/unattended-key.sock ssh-add /tmp/unauthorized-key")
host.succeed("cp /tmp/unauthorized-key.pub /root/.ssh/id_ed25519_unattended.pub")
host.fail(ssh("alpha", "true"))
host.succeed("ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519_unattended.pub")
host.succeed("SSH_AUTH_SOCK=/run/user/0/unattended-key.sock ssh-add -d /tmp/unauthorized-key")
host.succeed("rm /tmp/unauthorized-key /tmp/unauthorized-key.pub")

# A wrong pin must fail; availability probing must never enroll a key.
host.succeed("cp /root/.ssh/agent-environments_known_hosts /tmp/good-pins")
host.succeed("sed 's/agent-env-beta/agent-env-alpha/' /tmp/good-pins | tail -n 1 > /root/.ssh/agent-environments_known_hosts")
host.fail(ssh("alpha", "true"))
host.succeed("cp /tmp/good-pins /root/.ssh/agent-environments_known_hosts")

for name in ["alpha", "beta"]:
    host.succeed(f"agent-env stop {name}", timeout=180)
    host.fail(f"agent-env status {name}")
    assert listing()[name] == "stopped"
    host.fail(ssh(name, "true"))
    host.succeed(f"agent-env start {name}", timeout=720)
    # Reuse the original pin; no re-enrollment after restart.
    host.succeed(ssh(name, f'test "$(cat ~/private-marker)" = {name}'))
    host.succeed(ssh(name, "cat /etc/ssh/ssh_host_ed25519_key.pub") + f" | cmp /tmp/{name}-host-key -")
    host.succeed(ssh(name, 'systemctl is-active home-manager-agent.service && test -L ~/.bashrc'))
    assert client_identity(name) == (outgoing_keys[name], private_hashes[name])
    assert host.succeed(f"agent-env public-age-key {name}").strip() == age_recipients[name]
    if name == "alpha":
        assert host.succeed(ssh(name, remote)).strip() == "target"
    network_boundary(name)
    host.succeed(f"agent-env stop {name}", timeout=180)

assert listing() == {"alpha": "stopped", "beta": "stopped"}

# Enforcement must be installed before startup and outlive every running guest.
host.succeed("agent-env start alpha", timeout=720)
host.succeed("agent-env start beta", timeout=720)
host.succeed("systemctl stop nftables.service", timeout=180)
assert listing() == {"alpha": "stopped", "beta": "stopped"}
host.succeed("agent-env start alpha", timeout=720)
host.succeed("systemctl is-active nftables.service")
network_boundary("alpha")
host.succeed("agent-env stop alpha", timeout=180)
unrelated_networking()

# Resource edits cannot silently reuse a disk with a different capacity.
host.succeed("truncate -s 1600M /var/lib/microvms/beta/private.img")
host.fail("agent-env start beta", timeout=180)
host.succeed("agent-env stop beta", timeout=180)
