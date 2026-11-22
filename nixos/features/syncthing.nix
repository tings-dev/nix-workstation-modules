# System support for homes selecting home/features/syncthing.nix.
{ config, lib, ... }:
let
  homes = lib.filterAttrs (_: home: home.workstation.features.syncthing.enable or false) (
    config.home-manager.users or { }
  );
in
{
  config = lib.mkIf (homes != { }) {
    assertions = [
      {
        assertion = config.networking.firewall.enable;
        message = "User Syncthing requires the host firewall to restrict incoming sync to Tailscale.";
      }
    ];

    services.tailscale.enable = true;
    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
      22000
    ];
    # Syncthing owns its lifecycle even on hosts without the unattended key.
    users.users = lib.mapAttrs (_: _: { linger = true; }) homes;
  };
}
