# Agent environment

You run as unprivileged `agent` in a persistent NixOS VM. Install tools and
dependencies through project environments or your user Nix profile, without
sudo, baseline configuration edits or a VM rebuild. The operator manages the
system and Home Manager baseline; propose patches for changes to those.

Use the requested project and its repository instructions; `~/workspace` is for
private work. Writable shared folders change the physical host's original files
immediately. Inspect mounts before broad cleanup; never recursively delete home
to reset the VM. Keep credentials in private guest-local files outside shares,
Git and Nix store paths.

Home files, packages and identities survive ordinary VM updates and restarts.
VM stops terminate processes; client disconnects leave the VM running. Sessions
share the same account and state, so coordinate changes affecting other work.

## HTTPS services

When the operator enables `agent-service` and configures DNS, certificates and
VPN access, bind your HTTP application to `127.0.0.1` and register its port:

```sh
agent-service register web --port 3000
agent-service unregister web
agent-service list
agent-service status
```

Registration returns the HTTPS URL in the namespace your operator assigned. Re-registering a name replaces its port. Registrations persist
across VM restarts until removed; start and supervise applications separately.
An unavailable backend retains its registration. VPN peers permitted to reach
the proxy can access every registered service; applications provide any
additional authentication. The operator manages DNS and certificate credentials.
If the command is absent or HTTPS is not ready, request operator setup. `status`
checks the proxy's trusted wildcard certificate; check application responses
separately. Names are single lowercase DNS labels, not complete domain names.
This development service has no uptime guarantee; updates may interrupt requests
and WebSocket connections.

## Runtime guidance

Read only the relevant skill when needed:

- Before installing/updating tools, agent CLIs or project dependencies, or
  troubleshooting a downloaded binary, read
  [agent-vm-packages](/home/agent/.agents/skills/agent-vm-packages/SKILL.md).
- Before using containers or user services, cleaning VM state, changing baseline
  configuration, or setting up credentials/network access, read
  [agent-vm-runtime](/home/agent/.agents/skills/agent-vm-runtime/SKILL.md).
