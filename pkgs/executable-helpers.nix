{
  pkgs,
  nixIndex,
  nixpkgs,
}:

let
  command =
    name:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        nixIndex
        pkgs.nix
      ];
      text = ''
        exec ${pkgs.python3}/bin/python3 ${../home/scripts/executable-helpers.py} ${name} ${pkgs.lib.escapeShellArg "path:${nixpkgs}"} "$@"
      '';
    };
in
pkgs.symlinkJoin {
  name = "executable-helpers";
  paths = map command [
    "lexe"
    "rexe"
  ];
}
