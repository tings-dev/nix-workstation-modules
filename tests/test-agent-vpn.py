import shlex

start_all()
host.wait_for_unit("multi-user.target")
host.succeed("test -r /dev/kvm && test -w /dev/kvm")
host.succeed("install -d -m 700 /root/.ssh")
host.succeed("install -m 600 /etc/agent-test-key /root/.ssh/id_ed25519")


def start(name):
    host.succeed(f"agent-env start {name}", timeout=720)
    console = f"journalctl -u microvm@{name}.service -o cat --no-pager"
    host.wait_until_succeeds(console + f" | grep 'AGENT_SSH_HOST_KEY {name} '")
    host.succeed(
        console
        + rf" | sed -n 's/.*AGENT_SSH_HOST_KEY {name} \(ssh-ed25519 [^ ]*\).*/agent-env-{name} \1/p'"
        + " | head -n 1 >> /root/.ssh/agent-environments_known_hosts"
    )


def ssh(command, name="vpn", root=False):
    if not root:
        return f"timeout 30 agent-env ssh {name} " + shlex.quote(command)
    link = 107 if name == "vpn" else 108
    return (
        "timeout 30 ssh -F /dev/null -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/root/.ssh/agent-environments_known_hosts "
        f"-o GlobalKnownHostsFile=/dev/null -o HostKeyAlias=agent-env-{name} "
        f"-o ForwardAgent=no root@10.83.{link}.2 " + shlex.quote(command)
    )


def run(command, name="vpn", root=False):
    return host.succeed(ssh(command, name, root))


def root(command):
    return run(command, root=True)


def services(tailscale=True, netbird=True):
    for unit, enabled in [("tailscaled", tailscale), ("netbird", netbird)]:
        probe = ssh(f"systemctl is-active {unit}")
        if enabled:
            host.wait_until_succeeds(probe)
        else:
            host.fail(probe)
    run("systemctl is-active sshd home-manager-agent")
    host.fail(ssh("sudo -n true"))


start("vpn")
services()
run("systemctl is-active systemd-resolved")
for command in [
    "tailscale set --operator=agent",
    "netbird down",
    "cat /var/lib/netbird/config.json",
    "cat /var/lib/tailscale/tailscaled.state",
    "resolvectl dns eth0 127.0.0.1",
]:
    host.fail(ssh(command))
root("test $(stat -c %a /var/lib/tailscale) = 700")
root("test $(stat -c %a /var/lib/netbird) = 700")
root("test $(stat -c %a /run/netbird) = 750")
# NetBird generates its private identity even before enrollment. Compare only a
# digest; private keys never leave the disposable guest or enter test logs.
identity = (
    "jq -er '.PrivateKey | select(length > 0)' /var/lib/netbird/config.json | sha256sum"
)
host.wait_until_succeeds(
    ssh(
        "jq -e '.PrivateKey | length > 0' /var/lib/netbird/config.json > /dev/null",
        root=True,
    )
)
netbird_identity = root(identity)
start("fresh")
host.wait_until_succeeds(
    ssh(
        "jq -e '.PrivateKey | length > 0' /var/lib/netbird/config.json > /dev/null",
        name="fresh",
        root=True,
    )
)
assert run(identity, name="fresh", root=True) != netbird_identity


def private_root(command):
    return run(command, name="fresh", root=True)


# Exercise the operator's private NetBird range as well as the CGNAT fixture.
# Only the declared range on wt0 may reach SSH, even with valid return routes.
private_root("systemctl stop tailscaled netbird")
private_root("ip link del wt0 2>/dev/null || true")
private_root("ip netns add nb; ip link add wt0 type veth peer name peer0 netns nb")
private_root("ip addr add 10.255.0.1/16 dev wt0; ip link set wt0 up")
private_root("ip -n nb addr add 10.255.0.2/16 dev peer0; ip -n nb link set peer0 up")
private_root("ip netns exec nb nc -z -w 2 10.255.0.1 22")
private_root("ip -n nb addr add 10.254.0.2/32 dev peer0; ip route add 10.254.0.2/32 dev wt0")
host.fail(ssh("ip netns exec nb nc -z -s 10.254.0.2 -w 2 10.255.0.1 22", name="fresh", root=True))
private_root("ip netns add rogue; ip link add rogue0 type veth peer name peer0 netns rogue")
private_root("ip addr add 192.0.2.1/24 dev rogue0; ip link set rogue0 up")
private_root("ip -n rogue addr add 192.0.2.2/24 dev peer0; ip -n rogue link set peer0 up")
private_root("ip netns exec rogue nc -z -w 2 192.0.2.1 22")
private_root("ip -n rogue addr add 10.255.1.2/32 dev peer0; ip route add 10.255.1.2/32 dev rogue0")
host.fail(ssh("ip netns exec rogue nc -z -s 10.255.1.2 -w 2 192.0.2.1 22", name="fresh", root=True))
host.succeed("agent-env stop fresh", timeout=180)
root("touch /var/lib/tailscale/persistence-marker /var/lib/netbird/persistence-marker")


def overlays():
    # No provider accounts are available in this offline test. Stop unregistered
    # daemons before substituting controlled links at their network boundary.
    # These packets exercise the production source checks and resolver policy,
    # not a simulation of provider authentication/ACLs.
    root("systemctl stop tailscaled netbird")
    for iface in ["tailscale0", "wt0"]:
        root(f"ip link del {iface} 2>/dev/null || true")
    for ns, iface, subnet, zone in [
        ("ts", "tailscale0", "100.80.0", "ts.agent.test"),
        ("nb", "wt0", "100.90.0", "nb.agent.test"),
    ]:
        root(f"ip netns add {ns}")
        root(f"ip link add {iface} type veth peer name peer0 netns {ns}")
        root(f"ip addr add {subnet}.1/24 dev {iface}; ip link set {iface} up")
        root(
            f"ip -n {ns} addr add {subnet}.2/24 dev peer0; ip -n {ns} link set peer0 up; ip -n {ns} link set lo up"
        )
        root(
            f"systemd-run --unit=fixture-dns-{ns} ip netns exec {ns} /run/current-system/sw/bin/dnsmasq "
            f"--keep-in-foreground --no-resolv --no-hosts --bind-interfaces --interface=peer0 "
            f"--address=/{zone}/{subnet}.2 --address=/#/192.0.2.66"
        )
        root(
            f"systemd-run --unit=fixture-http-{ns} ip netns exec {ns} "
            "/run/current-system/sw/bin/python3 -m http.server 8080 --directory /tmp"
        )
        root(
            f"resolvectl dns {iface} {subnet}.2; resolvectl domain {iface} '~{zone}'; resolvectl default-route {iface} no"
        )
        try:
            host.wait_until_succeeds(
                ssh(f"curl --noproxy '*' -fsS --max-time 3 http://peer.{zone}:8080/"),
                timeout=30,
            )
        except Exception:
            root(f"journalctl -u fixture-dns-{ns} -u fixture-http-{ns} --no-pager")
            root("resolvectl status; ip -4 route; nft list ruleset")
            raise
    # Resolver queries must go to the matching link, even though both fixture
    # resolvers deliberately return a wrong address for the other suffix.
    for zone, address in [
        ("ts.agent.test", "100.80.0.2"),
        ("nb.agent.test", "100.90.0.2"),
    ]:
        assert address in run(f"getent ahostsv4 peer.{zone}")
    root("ip netns exec nb nc -z -w 2 100.90.0.1 22")
    root("ip netns exec ts nc -z -w 2 100.80.0.1 22")
    # Wrong CGNAT range on the legitimate NetBird interface must still fail.
    root(
        "ip -n nb addr add 100.91.0.2/32 dev peer0; ip route add 100.91.0.2/32 dev wt0"
    )
    host.fail(ssh("ip netns exec nb nc -z -s 100.91.0.2 -w 2 100.90.0.1 22", root=True))
    # Borrowing an allowed provider address on another interface must fail even
    # with a working return route. Ordinary non-CGNAT traffic proves the path.
    root("ip netns add rogue; ip link add rogue0 type veth peer name peer0 netns rogue")
    root("ip addr add 192.0.2.1/24 dev rogue0; ip link set rogue0 up")
    root("ip -n rogue addr add 192.0.2.2/24 dev peer0; ip -n rogue link set peer0 up")
    root("ip netns exec rogue nc -z -w 2 192.0.2.1 22")
    root(
        "ip -n rogue addr add 100.90.1.2/32 dev peer0; ip route add 100.90.1.2/32 dev rogue0"
    )
    host.fail(
        ssh("ip netns exec rogue nc -z -s 100.90.1.2 -w 2 192.0.2.1 22", root=True)
    )
    root("ip -6 addr add fd7a:115c:a1e0::1/64 dev rogue0 nodad")
    root("ip -n rogue -6 addr add fd7a:115c:a1e0::2/64 dev peer0 nodad")
    root(
        "ip -6 addr add fd83::1/64 dev rogue0 nodad; ip -n rogue -6 addr add fd83::2/64 dev peer0 nodad"
    )
    root("ip netns exec rogue nc -6 -z -s fd83::2 -w 2 fd83::1 22")
    host.fail(ssh("ip netns exec rogue nc -6 -z -w 2 fd7a:115c:a1e0::1 22", root=True))


overlays()
host.succeed("agent-env stop vpn", timeout=180)
start("vpn")
services()
assert root(identity) == netbird_identity
root(
    "test -f /var/lib/tailscale/persistence-marker && test -f /var/lib/netbird/persistence-marker"
)
overlays()

# Apply real operator-side deployments against the same private disk. Disabling
# either client leaves ordinary SSH and the other daemon operational.
for mode in ["tailscale", "netbird", "neither"]:
    host.succeed("agent-env stop vpn", timeout=180)
    host.succeed(
        f"/run/booted-system/specialisation/{mode}/bin/switch-to-configuration switch",
        timeout=180,
    )
    start("vpn")
    services(mode == "tailscale", mode == "netbird")
    root(
        "test -f /var/lib/tailscale/persistence-marker && test -f /var/lib/netbird/persistence-marker"
    )
    if mode == "netbird":
        assert root(identity) == netbird_identity
host.succeed("agent-env stop vpn", timeout=180)
host.succeed(
    'test -z "$(lsof -t /var/lib/microvms/vpn/private.img /var/lib/microvms/fresh/private.img)"'
)
