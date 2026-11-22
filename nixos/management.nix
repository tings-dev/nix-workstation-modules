# The matching NixOS rebuild command belongs to the system, not a home profile.
{ config, ... }:
let
  switchCommand = [
    "/run/wrappers/bin/sudo"
    "${config.system.build.nixos-rebuild}/bin/nixos-rebuild"
    "switch"
    "--flake"
    ".#${config.networking.hostName}"
  ];
in
{
  home-manager.sharedModules = [
    ({ lib, options, ... }: {
      config = lib.optionalAttrs (options ? workstation.management) {
        workstation.management.switchCommand = switchCommand;
      };
    })
  ];
}
