import json
import shlex


namespace = "agent-test.envs.example.test"


def agent(command):
    return "su -s /bin/sh agent -c " + shlex.quote(command)


def trust_pebble():
    guest.wait_until_succeeds("curl -fsS https://acme.test:15000/roots/0 > /tmp/pebble-root.pem")
    guest.succeed(
        "cat /etc/ssl/certs/ca-certificates.crt /tmp/pebble-root.pem > /tmp/test-ca-bundle; "
        "rm /etc/ssl/certs/ca-certificates.crt; "
        "install -m 644 /tmp/test-ca-bundle /etc/ssl/certs/ca-certificates.crt"
    )


def curl(name="web", address="127.0.0.1"):
    address = f"[{address}]" if ":" in address else address
    return f"curl --noproxy '*' -fsS --max-time 5 --resolve {name}.{namespace}:443:{address} https://{name}.{namespace}/"


def serial():
    return guest.succeed(
        "jq -r '.letsencrypt.Certificates[0].certificate' /var/lib/traefik/acme.json "
        "| base64 -d | openssl x509 -noout -serial"
    )


def outage():
    # Preserve Pebble's in-memory accounts/CA while making its issuance API
    # unavailable. Restarting Pebble would create an unrelated, fresh CA.
    acme.succeed("nft add table inet fixture_outage")
    acme.succeed("nft 'add chain inet fixture_outage input { type filter hook input priority -50; policy accept; }'")
    acme.succeed("nft add rule inet fixture_outage input tcp dport 443 reject")


acme.start()
acme.wait_for_unit("pebble-challtestsrv")
acme.wait_for_unit("pebble")
acme.wait_for_open_port(443)
outage()
guest.start()
guest.wait_for_unit("agent-services")
guest.wait_for_unit("traefik")

with subtest("Register before issuance and reject fallback TLS"):
    assert guest.succeed(agent("agent-service register web --port 3000")).strip() == f"https://web.{namespace}"
    guest.fail(agent("agent-service status"))
    guest.fail(curl())
    # Even disabling validation must not turn a generated default cert into a
    # usable route while the wildcard is missing (strict SNI).
    try:
        guest.wait_until_succeeds("! " + curl().replace("-fsS", "-ksS"), timeout=15)
    except Exception:
        print(guest.succeed("cat /run/traefik/test-config.yaml /var/lib/agent-services/dynamic/routes.yaml; id traefik; journalctl -u traefik --no-pager"))
        raise
    acme.succeed("nft delete table inet fixture_outage")
    trust_pebble()
    guest.succeed("systemctl restart traefik")
    guest.wait_until_succeeds(agent("agent-service status"), timeout=120)
    guest.wait_until_succeeds(curl() + " | grep first-backend")

with subtest("Private files, socket authentication and request validation"):
    for path in [
        "/var/lib/agent-services/registrations.json",
        "/var/lib/agent-services/dynamic/routes.yaml",
        "/var/lib/traefik/acme.json",
        "/run/agent-services-fixture/exec-path",
        "/run/credentials/traefik.service/EXEC_PATH",
    ]:
        guest.fail(agent(f"cat {path}"))
    guest.fail("setpriv --reuid=65534 --regid=1000 --clear-groups /run/current-system/sw/bin/agent-service list")
    original = guest.succeed(agent("agent-service --json list"))
    for command in [
        "agent-service register ../web --port 3000",
        "agent-service register web.other-domain --port 3000",
        "agent-service register web --port 443",
        "agent-service register web --port 65536",
    ]:
        guest.fail(agent(command))
    assert guest.succeed(agent("agent-service --json list")) == original
    guest.fail("nc -z -w 1 127.0.0.1 8080")
    guest.fail("nc -z -w 1 127.0.0.1 80")

with subtest("Replacement, WebSockets, errors and removal"):
    guest.succeed(agent("agent-service register web --port 3001"))
    guest.wait_until_succeeds(curl() + " | grep replacement-backend")
    guest.succeed(agent("agent-service register socket --port 3002"))
    guest.wait_until_succeeds(
        "python3 - <<'PY'\n"
        "import socket, ssl\nfrom websockets.sync.client import connect\n"
        f"with connect('wss://socket.{namespace}/', ssl=ssl.create_default_context(), sock=socket.create_connection(('127.0.0.1', 443)), proxy=None) as ws:\n"
        "    ws.send('echo-through-proxy')\n    assert ws.recv() == 'echo-through-proxy'\nPY",
        timeout=30,
    )
    guest.succeed("systemctl stop fixture-replacement")
    guest.wait_until_succeeds(curl().replace("-fsS", "-sS -o /dev/null -w '%{http_code}'") + " | grep '^502$'")
    assert len(json.loads(guest.succeed(agent("agent-service --json list")))) == 2
    guest.succeed(agent("agent-service unregister web"))
    guest.succeed(agent("agent-service unregister web"))
    guest.wait_until_succeeds(curl().replace("-fsS", "-sS -o /dev/null -w '%{http_code}'") + " | grep '^404$'")
    guest.succeed(agent("agent-service register web --port 3000"))

with subtest("Only declared VPN interfaces accept incoming HTTPS"):
    for ns, iface, subnet in [("ts", "tailscale0", "100.80.0"), ("nb", "wt0", "10.255.0"), ("rogue", "rogue0", "192.0.2")]:
        guest.succeed(f"ip netns add {ns}; ip link add {iface} type veth peer name peer0 netns {ns}")
        guest.succeed(f"ip addr add {subnet}.1/24 dev {iface}; ip link set {iface} up")
        guest.succeed(f"ip -n {ns} addr add {subnet}.2/24 dev peer0; ip -n {ns} link set peer0 up; ip -n {ns} link set lo up")
        command = f"ip netns exec {ns} " + curl(address=f"{subnet}.1")
        if ns == "rogue":
            guest.fail(command)
        else:
            guest.wait_until_succeeds(command + " | grep first-backend")
    # The ordinary external test-network interface must remain closed too.
    acme.fail(f"curl -kfsS --max-time 3 --resolve web.{namespace}:443:{guest_ip} https://web.{namespace}/")
    for ns, iface, prefix in [("ts", "tailscale0", "fd7a:115c:a1e0:1"), ("rogue", "rogue0", "fd83:2")]:
        guest.succeed(f"ip -6 addr add {prefix}::1/64 dev {iface} nodad; ip -n {ns} -6 addr add {prefix}::2/64 dev peer0 nodad")
        command = f"ip netns exec {ns} " + curl(address=f"{prefix}::1")
        if ns == "rogue":
            guest.fail(command)
        else:
            guest.wait_until_succeeds(command + " | grep first-backend", timeout=30)

with subtest("Automatic renewal and renewal failure preserve a valid cert"):
    old_serial = serial()
    outage()
    guest.succeed("systemctl restart traefik")
    guest.wait_until_succeeds("journalctl -u traefik --since '-30 seconds' | grep -i 'renew.*error\|error.*renew\|unable to renew'", timeout=30)
    guest.succeed(agent("agent-service status"))
    guest.succeed(curl() + " | grep first-backend")
    assert serial() == old_serial
    acme.succeed("nft delete table inet fixture_outage")
    guest.succeed("systemctl restart traefik")
    guest.wait_until_succeeds(
        "test \"$(jq -r '.letsencrypt.Certificates[0].certificate' /var/lib/traefik/acme.json "
        "| base64 -d | openssl x509 -noout -serial)\" != " + shlex.quote(old_serial.strip()),
        timeout=120,
    )
    guest.wait_until_succeeds(agent("agent-service status"))

with subtest("Broker and VM restarts preserve registrations and ACME state"):
    expected = guest.succeed(agent("agent-service --json list"))
    account = guest.succeed("jq -r '.letsencrypt.Account.PrivateKey' /var/lib/traefik/acme.json | sha256sum")
    guest.succeed("systemctl restart agent-services")
    assert guest.succeed(agent("agent-service --json list")) == expected
    guest.wait_for_unit("traefik")
    guest.wait_until_succeeds(agent("agent-service status"), timeout=30)
    guest.shutdown()
    guest.start()
    guest.wait_for_unit("traefik")
    trust_pebble()
    guest.wait_until_succeeds(agent("agent-service status"), timeout=120)
    assert guest.succeed(agent("agent-service --json list")) == expected
    assert guest.succeed("jq -r '.letsencrypt.Account.PrivateKey' /var/lib/traefik/acme.json | sha256sum") == account
    guest.wait_until_succeeds(curl() + " | grep first-backend")
