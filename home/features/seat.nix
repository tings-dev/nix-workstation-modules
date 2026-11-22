# A complete Sway home session. Select the NixOS seat separately on NixOS.
modules:
{ lib, pkgs, ... }:
{
  imports = [
    (modules.load ./desktop.nix)
    ../programs/sway.nix
    (modules.load ../programs/dux.nix)
    ../programs/kanata.nix
    (modules.load ../programs/firefox.nix)
  ];

  # Kanata emits F13-F21; Sway reads this keymap to produce German characters.
  xdg.configFile."xkb/keymap.xkb".source = ../configs/xkb/keymap.xkb;
  services.cliphist.enable = true;

  # Wait until Sway has published its Wayland environment to the user manager.
  systemd.user.services.dms = {
    Unit = {
      After = lib.mkForce [ "sway-session.target" ];
      PartOf = lib.mkForce [ "sway-session.target" ];
    };
    Install.WantedBy = lib.mkForce [ "sway-session.target" ];
  };

  home.packages = with pkgs; [
    playerctl
    chromium
    signal-desktop
    slack
    thunderbird
  ];
}
