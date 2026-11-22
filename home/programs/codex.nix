# Shared preferences in Codex's otherwise mutable, machine-local config.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  configure = pkgs.writeScript "configure-codex" ''
    #!${python}/bin/python3
    import os
    from pathlib import Path
    import stat
    import sys
    import tempfile

    import tomlkit

    path = Path(sys.argv[1]).expanduser().resolve()
    original = path.read_text() if path.exists() else ""
    document = tomlkit.parse(original)
    if "tui" not in document:
        document["tui"] = tomlkit.table()
    document["tui"]["status_line"] = [
        "model-with-reasoning",
        "current-dir",
        "git-branch",
        "context-used",
        "weekly-limit"
    ]
    document["tui"]["status_line_use_colors"] = True
    updated = tomlkit.dumps(document)

    if updated != original:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        # Replace atomically so an interrupted activation cannot truncate it.
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
  # A store-backed config would prevent Codex from saving its own preferences.
  # Reapply only these shared keys; local UI edits to them last until next switch.
  # `run` also ensures Home Manager dry runs do not modify the file.
  home.activation.codexPreferences = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configure} ${lib.escapeShellArg "${config.home.homeDirectory}/.codex/config.toml"}
  '';
}
