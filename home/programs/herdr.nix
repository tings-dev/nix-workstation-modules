# Atuin's threads popup for the graphical Herdr app, selected by desktop-dev.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Herdr treats keys.json as a complete keymap. Seed new installations with
  # upstream defaults; existing installations retain their own keys verbatim
  # except for the added shortcut. Review this seed when updating Herdr.
  defaultKeys = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/herdrdev/herdr-app/v0.1.14/defaults/keys.json";
    hash = "sha256-0YMf4ummhav1/ZXBVvRCX8vBf4GRkWOVWjaIoWbqJp8=";
  };
  configure = pkgs.writeScript "configure-herdr-threads" ''
    #!${pkgs.python3}/bin/python3
    import json
    import os
    from pathlib import Path
    import stat
    import sys
    import tempfile

    path = Path(sys.argv[1]).expanduser().resolve()
    original = path.read_text() if path.exists() else None
    document = json.loads(original if original is not None else Path("${defaultKeys}").read_text())
    bindings = document.setdefault("global", {})
    shortcut = "ctrl-alt-t"
    action = "mod.open:atuin-threads"
    if shortcut in bindings:
        if bindings[shortcut] != action:
            print(f"Herdr: keeping existing {shortcut} binding; open Threads with the command palette.", file=sys.stderr)
        sys.exit(0)
    bindings[shortcut] = action
    updated = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        try:
            f.write(updated)
            f.flush()
            os.fchmod(f.fileno(), mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
  '';
in
{
  xdg.configFile = {
    "herdr-app/mods/atuin-threads" = {
      source = "${inputs.herdr-atuin-threads}/mods/atuin-threads";
      recursive = true;
    };
    # Use exactly the CLI that Home Manager uses for the Atuin daemon, including
    # when the app was launched without an interactive shell's PATH.
    "herdr-app/mods/atuin-threads/local.json".text = builtins.toJSON {
      atuin = lib.getExe config.programs.atuin.package;
    };
  };

  # Keep keys mutable, like Codex preferences, and respect activation dry runs.
  home.activation.herdrThreadsKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configure} ${lib.escapeShellArg "${config.xdg.configHome}/herdr-app/keys.json"}
  '';
}
