# Shared graphical system services; compositor and session selection are separate.
{ inputs, ... }:
{ lib, pkgs, ... }:

{
  imports = [ inputs.stylix.nixosModules.stylix ];
  stylix = import ../../theme.nix { inherit pkgs; };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  # File-manager mounts/trash and the GTK settings backend belong to the OS.
  services.gvfs.enable = true;
  programs.dconf.enable = true;

  fonts.packages = with pkgs; [
    dejavu_fonts
    noto-fonts
    noto-fonts-color-emoji
  ];

  services.printing.enable = lib.mkDefault false;
}
