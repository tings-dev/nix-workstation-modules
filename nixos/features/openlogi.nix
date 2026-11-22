# Optional Logitech HID++ support, selected separately from the desktop baseline.
{ config, lib, pkgs, ... }:

{
  programs.openlogi.enable = lib.mkDefault true;

  # Nixpkgs ships these units under share/, while systemd.packages reads lib/.
  systemd.packages = lib.optional config.programs.openlogi.enable (
    pkgs.runCommand "openlogi-systemd-units" { } ''
      mkdir -p $out/lib/systemd
      ln -s ${config.programs.openlogi.package}/share/systemd/user $out/lib/systemd/user
    ''
  );
  systemd.user.services.openlogi-agent = lib.mkIf config.programs.openlogi.enable {
    wantedBy = [ "graphical-session.target" ];
  };
}
