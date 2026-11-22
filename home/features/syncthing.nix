# User-owned Syncthing; devices, folders and identity remain mutable state.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  prepare = pkgs.writeShellApplication {
    name = "prepare-syncthing";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../scripts/prepare-syncthing.py} \
        ${lib.getExe config.services.syncthing.package}
    '';
  };
in
{
  options.workstation.features.syncthing.enable =
    lib.mkEnableOption "user Syncthing with incoming sync restricted to Tailscale";

  config = lib.mkIf config.workstation.features.syncthing.enable {
    services.syncthing = {
      enable = true;
      guiAddress = "127.0.0.1:8384";
      overrideDevices = false;
      overrideFolders = false;
      tray.enable = false;
    };

    # HM's REST updater runs after the daemon. Patch only the network policy
    # offline instead, including on the first start, before any network activity.
    systemd.user.services.syncthing.Service.ExecStartPre = [
      "${prepare}/bin/prepare-syncthing"
    ];
  };
}
