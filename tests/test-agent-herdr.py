import json
import shlex

start_all()
host.wait_for_unit("multi-user.target")
host.succeed("test -r /dev/kvm && test -w /dev/kvm")
host.succeed("install -d -m 700 /root/.ssh")
host.succeed("install -m 600 /etc/agent-test-key /root/.ssh/id_ed25519")


def ssh(command):
    return "timeout 90 agent-env ssh herdr " + shlex.quote(command)


def run(command):
    return host.succeed(ssh(command), timeout=100)


# Keep stdin open until the reply arrives, then close and reap the SSH client.
# Every call uses the Desktop's documented `hc connect` protocol transport.
rpc_client = """
import json, subprocess, sys
p = subprocess.Popen(['agent-env', 'ssh', 'herdr', 'hc connect'],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    p.stdin.write(sys.argv[1] + '\\n')
    p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            raise RuntimeError('SSH/core closed before its reply')
        reply = json.loads(line)
        if reply.get('id') == 1:
            print(json.dumps(reply))
            break
finally:
    p.stdin.close()
    p.wait(timeout=15)
assert p.returncode == 0, p.returncode
"""


def rpc(method, **params):
    request = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params))
    reply = json.loads(
        host.succeed(
            "timeout 90 python3 -c "
            + shlex.quote(rpc_client)
            + " "
            + shlex.quote(request),
            timeout=100,
        )
    )
    assert "error" not in reply, reply
    return reply["result"]


def disconnected():
    # No ControlPersist, interactive login or protocol client remains on host.
    host.wait_until_succeeds(
        "test -z \"$(ss -Htn state established '( dst 10.83.106.2 and dport = :22 )')\""
    )


def read_until(address, text):
    for _ in range(20):
        screen = rpc("terminal.read", terminal=address, lines=100)["text"]
        if text in screen:
            return
        host.sleep(1)
    raise AssertionError(f"Missing {text!r} in terminal output: {screen}")


host.succeed("agent-env start herdr", timeout=720)
console = "journalctl -u microvm@herdr.service -o cat --no-pager"
host.wait_until_succeeds(console + " | grep 'AGENT_SSH_HOST_KEY herdr '")
host.succeed(
    console
    + r" | sed -n 's/.*AGENT_SSH_HOST_KEY herdr \(ssh-ed25519 [^ ]*\).*/agent-env-herdr \1/p'"
    + " | head -n 1 > /root/.ssh/agent-environments_known_hosts"
)
run("systemctl is-active home-manager-agent.service")
run(
    'test "$(id -un)" = agent && test "$(loginctl show-user agent -p Linger --value)" = yes'
)
host.fail(ssh("sudo -n true"))
run("test \"$(ls /home)\" = agent && test ! -e /run/host && test ! -e ~/.ssh/config")
run("mkdir -p ~/.config/herdr-core ~/bin ~/workspace")
core_config = 'shell = ["/run/current-system/sw/bin/bash", "--login"]\n'
run("printf %s " + shlex.quote(core_config) + " > ~/.config/herdr-core/config.toml")
run(
    "printf '#!/bin/sh\\necho private-tool-ok\\n' > ~/bin/private-tool && chmod +x ~/bin/private-tool"
)
boot_id = run("cat /proc/sys/kernel/random/boot_id").strip()
host_key = run("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
hello = rpc("hello")
assert hello["core"]["name"] == "herdr", hello

# The work itself records an interval with no logins, so our verification SSH
# cannot accidentally be the login keeping the user manager alive.
program = r"""
set -eu
test "$(id -un)" = agent
test "$HOME" = /home/agent
test "$(hostname)" = herdr
git --version
gcc --version
nix --version
podman --version
codex --version
~/bin/private-tool
echo agent-tools-ok
ticks=0
while true; do
    if loginctl list-sessions --json=short | jq -e 'all(.[]; .class == "manager")' > /dev/null; then
        ticks=$((ticks + 1))
        printf %s "$ticks" > ~/workspace/no-login-ticks
    fi
    if IFS= read -r -t 1 line; then
        printf 'reply:%s\n' "$line"
    fi
done
"""
terminal = rpc("terminal.run", name="continuity", argv=["bash", "-lc", program])
address, pid = terminal["address"], terminal["pid"]
assert pid and terminal["state"] == "live", terminal
disconnected()
host.sleep(15)
assert int(run("cat ~/workspace/no-login-ticks")) >= 3
same = rpc("terminal.get", terminal=address)
assert same["pid"] == pid and same["state"] == "live", same
read_until(address, "agent-tools-ok")
rpc("terminal.send", terminal=address, text="after-reconnect")
read_until(address, "reply:after-reconnect")
run("test -S /run/user/1000/herdr-core/default.sock")
run("test \"$(stat -c '%U:%a' /run/user/1000/herdr-core)\" = agent:700")
run("test \"$(stat -c '%U:%a' ~/.local/state/herdr-core/default)\" = agent:700")
disconnected()

# VM restart kills running programs. Core identity/configuration and terminal
# records persist; a non-kept task must not be silently executed a second time.
host.succeed("agent-env stop herdr", timeout=180)
host.succeed("agent-env start herdr", timeout=720)
run("systemctl is-active home-manager-agent.service")
assert run("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
assert run("cat /etc/ssh/ssh_host_ed25519_key.pub").strip() == host_key
assert run("cat ~/.config/herdr-core/config.toml") == core_config
assert rpc("hello")["core"]["id"] == hello["core"]["id"]
old = rpc("terminal.get", terminal=address)
assert old["state"] == "finished", old
assert old["created_ms"] == terminal["created_ms"], old
assert int(run("cat ~/workspace/no-login-ticks")) >= 3
shell = rpc("terminal.run", name="after-reboot")
rpc("terminal.send", terminal=shell["address"], text="~/bin/private-tool")
read_until(shell["address"], "private-tool-ok")
rpc("terminal.kill", terminal=shell["address"])
rpc("terminal.rm", terminal=shell["address"])
rpc("terminal.rm", terminal=address)
host.succeed("agent-env stop herdr", timeout=180)
host.succeed('test -z "$(lsof -t /var/lib/microvms/herdr/private.img)"')
