# Supply NixOS identity only to homes explicitly importing prepared-updates.
{ config, ... }:
let
  hostName = config.networking.hostName;
  rebuildCommand = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild";
in
{
  home-manager.sharedModules = [
    ({ lib, options, ... }: {
      config = lib.optionalAttrs (options ? workstation.preparedUpdates) {
        workstation.preparedUpdates = { inherit hostName rebuildCommand; };
      };
    })
  ];
}
