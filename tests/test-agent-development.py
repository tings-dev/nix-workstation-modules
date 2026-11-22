import shlex

start_all()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm")
host.succeed("install -d -m 700 /root/.ssh")
host.succeed("install -m 600 /etc/agent-test-key /root/.ssh/id_ed25519")


def ssh(command):
    return "timeout 180 agent-env ssh development " + shlex.quote(command)


def run(command):
    return host.succeed(ssh(command), timeout=190)


def ready():
    run("systemctl is-active home-manager-agent.service")
    run('test "$(id -un)" = agent && test "$(id -Gn)" = agent')
    run('test "$(nix config show trusted-users)" = root')
    run("test \"$(ls /home)\" = agent && test ! -e /run/host && test ! -e /run/docker.sock")
    run("test ! -e ~/.codex/auth.json && test ! -e ~/.local/share/atuin/session")
    run("test ! -e ~/.ssh/config && test -L ~/.bashrc")
    host.fail(ssh("sudo -n true"))


host.succeed("agent-env start development", timeout=720)
console = "journalctl -u microvm@development.service -o cat --no-pager"
host.wait_until_succeeds(console + " | grep 'AGENT_SSH_HOST_KEY development '")
host.succeed(
    console
    + r" | sed -n 's/.*AGENT_SSH_HOST_KEY development \(ssh-ed25519 [^ ]*\).*/agent-env-development \1/p'"
    + " | head -n 1 > /root/.ssh/agent-environments_known_hosts"
)
ready()
assert "initial" in run("cat /etc/development-generation")
assert "initial-baseline" in run("cat ~/.config/operator-baseline")
server_key = run("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
client_key = host.succeed("agent-env public-ssh-key development").strip()
run("test -d /nix/.ro-store/*-previous-tool")
run("mkdir -p ~/workspace/project ~/.config/systemd/user ~/.local/share/development")
run("cp /etc/development-fixtures/flake.nix ~/workspace/project/flake.nix")
run("echo initial > ~/workspace/project/revision")
# Explicit project source root permits further offline evaluations after GC.
run("nix-store --add-root ~/workspace/nixpkgs --indirect -r $(cat /etc/development-fixtures/nixpkgs-path)")
run(
    "nix-store --add-root ~/workspace/build-dependencies --indirect "
    "-r $(readlink -f /etc/development-fixtures/build-dependencies)"
)
run("cp /etc/development-fixtures/container.tar ~/workspace/container.tar")
run("cp -r /etc/development-fixtures/wheels ~/workspace/wheels")
run("cp /etc/development-fixtures/generic-linux ~/workspace/generic-linux")
run("printf 'custom-user-setting\\n' > ~/.config/agent-customization")
run("printf 'guest-local-runtime-state\\n' > ~/.local/share/development/provider-state")

# Representative tools actually execute under the unprivileged SSH account.
for command in [
    "rg --version",
    "fd --version",
    "bat --version",
    "git --version",
    "gcc --version",
    "make --version",
    "uv --version",
    "pixi --version",
    "ruff --version",
    "shellcheck --version",
    "direnv version",
    "atuin --version",
    "codex --version",
    "claude --version",
    "herdr --help",
    "herdr-core --help",
]:
    run(command)
assert "generic-linux-ok" in run("~/workspace/generic-linux")
run("printf '#include <stdio.h>\\nint main(){puts(\"compiler-ok\");}\\n' > ~/workspace/main.c")
assert "compiler-ok" in run("gcc ~/workspace/main.c -o ~/workspace/compiled && ~/workspace/compiled")


build_number = 0


def develop_and_build():
    global build_number
    build_number += 1
    run(f"echo build-{build_number} > ~/workspace/project/revision")
    assert "project-shell-ok" in run(
        "cd ~/workspace/project && nix develop --offline --no-write-lock-file "
        "-c bash -c 'echo $AGENT_PROJECT_SHELL; hello'"
    )
    assert "previous-closure-ok" in run(
        "cd ~/workspace/project && nix build --offline --no-write-lock-file && ./result/bin/agent-package"
    )


develop_and_build()
run("cd ~/workspace/project && nix profile install --offline --no-write-lock-file .")
assert "previous-closure-ok" in run("~/.nix-profile/bin/agent-package")
assert "-previous-tool" in run("nix path-info --recursive ~/.nix-profile")
run("uv venv --offline --python $(command -v python3) ~/workspace/venv")
run(
    "uv pip install --offline --python ~/workspace/venv/bin/python --no-index --find-links ~/workspace/wheels agent-dependency"
)
assert "language-dependency-ok" in run(
    "~/workspace/venv/bin/python -c 'import agent_dependency; print(agent_dependency.message())'"
)

service = """[Unit]
Description=Agent-owned persistent development service
[Service]
ExecStart=/run/current-system/sw/bin/sleep infinity
ExecStartPost=/bin/sh -c 'echo user-service-ok > %h/.local/share/development/service-marker'
[Install]
WantedBy=default.target
"""
run("printf %s " + shlex.quote(service) + " > ~/.config/systemd/user/development.service")
run("systemctl --user daemon-reload && systemctl --user enable --now development.service")

assert "true" in run("podman info --format '{{.Host.Security.Rootless}}'")
run("podman load -i ~/workspace/container.tar")
run("podman volume create development-data")
assert "container-data-ok" in run(
    "podman run --rm -v development-data:/data agent-development-fixture:test "
    "sh -c 'echo container-data-ok > /data/marker; cat /data/marker'"
)


def persisted():
    ready()
    assert run("cat /etc/ssh/ssh_host_ed25519_key.pub").strip() == server_key
    assert host.succeed("agent-env public-ssh-key development").strip() == client_key
    assert "previous-closure-ok" in run("~/.nix-profile/bin/agent-package")
    assert "-previous-tool" in run("nix path-info --recursive ~/.nix-profile")
    assert "language-dependency-ok" in run(
        "~/workspace/venv/bin/python -c 'import agent_dependency; print(agent_dependency.message())'"
    )
    assert "custom-user-setting" in run("cat ~/.config/agent-customization")
    assert "guest-local-runtime-state" in run("cat ~/.local/share/development/provider-state")
    assert "user-service-ok" in run("cat ~/.local/share/development/service-marker")
    run("systemctl --user is-active development.service")
    assert "container-data-ok" in run(
        "podman run --rm -v development-data:/data agent-development-fixture:test cat /data/marker"
    )
    # Query and verify the profile's registered transitive closure explicitly;
    # files executing by themselves would not prove database persistence.
    run("nix store verify --recursive --no-trust ~/.nix-profile")
    develop_and_build()


host.succeed("agent-env stop development", timeout=180)
host.succeed("agent-env start development", timeout=720)
persisted()

# Deployment selects the next runner without interrupting the running guest.
# Only the operator's explicit stop/start applies the system and home baseline.
invocation = host.succeed("systemctl show microvm@development -p InvocationID --value").strip()
host.succeed("/run/current-system/specialisation/updated/bin/switch-to-configuration switch", timeout=180)
assert host.succeed("systemctl show microvm@development -p InvocationID --value").strip() == invocation
assert "initial" in run("cat /etc/development-generation")
assert "initial-baseline" in run("cat ~/.config/operator-baseline")
host.succeed("agent-env stop development", timeout=180)
host.succeed("agent-env start development", timeout=720)
assert "updated" in run("cat /etc/development-generation")
assert "reviewed-baseline-update" in run("cat ~/.config/operator-baseline")
run("test -L ~/.config/operator-baseline")
run("test ! -e /etc/development-fixtures")
run("test ! -d /nix/.ro-store/*-previous-tool")
persisted()
# Collect an unrooted build as well as preserving the installed live package.
run("rm ~/workspace/project/result")
run("cd ~/workspace/project && nix build --offline --no-link --print-out-paths .#garbage > ~/workspace/garbage-path")
run("nix store gc")
run('test ! -e "$(cat ~/workspace/garbage-path)"')
run("nix store verify --all --no-trust")
persisted()
host.succeed("agent-env stop development", timeout=180)
host.succeed("agent-env start development", timeout=720)
assert "updated" in run("cat /etc/development-generation")
persisted()
host.succeed("agent-env stop development", timeout=180)
