# System support for Craft; select home/features/craft.nix separately per user.
{ lib, pkgs, ... }:
{
  # Supply graphics and file dialogs without choosing a compositor or greeter.
  hardware.graphics.enable = lib.mkDefault true;
  xdg.portal = {
    enable = lib.mkDefault true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = lib.mkDefault [ "gtk" ];
  };
}
