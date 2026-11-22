---
name: agent-vm-packages
description: Install or update tools, agent CLIs and project dependencies, or troubleshoot downloaded binaries inside this repository's NixOS agent VMs.
---

# Packages inside an agent VM

Run package operations as `agent` using the guest's private Nix daemon and store.
User installs and updates need neither sudo, baseline edits nor a VM restart.

## Choose the environment

Prefer an existing project flake or language lockfile. For a flake project,
`nix develop` enters its development shell and `nix build` builds its output.
For a one-off tool:

```sh
nix shell nixpkgs#hello --command hello
```

For persistent user tools:

```sh
nix profile install nixpkgs#hello
nix profile list
```

Use the name from `nix profile list` with `nix profile upgrade` or
`nix profile remove`. Bare `nixpkgs` and GitHub flake references resolve
independently of the baseline's pins; use a project lockfile or explicit input
revision when reproducibility matters.

Baseline user tools are exposed through `/etc/profiles/per-user/agent/bin`,
system tools through `/run/current-system/sw/bin`, and user installs through
`~/.nix-profile/bin`. Check `type -a TOOL` and the selected tool's version after
installation. If a launcher uses an absolute baseline path, select the user
executable explicitly or adjust the launcher configuration within the task.

## Agent CLI updates

The operator's baseline uses the `llm-agents` flake input. To try the upstream
Codex package without changing that baseline:

```sh
nix shell github:numtide/llm-agents.nix#codex --command codex
```

To keep it in your user profile:

```sh
nix profile install github:numtide/llm-agents.nix#codex
~/.nix-profile/bin/codex --version
```

For subsequent updates, use `nix profile list` and upgrade that entry by name.
Start a new agent process to use the new executable. An npm or other package
manager update only affects that manager's installation, not the Nix baseline.
Changing the baseline pin is a separate operator-reviewed deployment.

## Language dependencies and downloaded binaries

Use the project's existing workflow, such as `uv sync`, Pixi or npm. Install a
missing package manager through Nix. For an ad hoc Python environment:

```sh
uv venv .venv
uv pip install --python .venv/bin/python requests
```

NixOS has no apt-based system package workflow. The baseline enables nix-ld and
common libraries for downloaded Linux interpreters and wheels; this does not
supply every application's runtime dependencies. For missing libraries, use a
project Nix shell or rootless container. If system capabilities are required,
propose a baseline patch for the operator rather than requesting agent sudo.

Leave `/nix/store` management to Nix. Keep needed builds rooted through a user
profile or project output link; unrooted store paths can be garbage-collected.
User packages, project dependencies and caches persist across VM restarts.
