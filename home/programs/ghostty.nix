# Default terminal and terminal-launcher ordering; Kitty stays available.
{ lib, pkgs, ... }:

{
  # Keep both terminals available on every desktop. Ghostty is the default
  # for launchers and applications; Kitty remains an alternative.
  programs.ghostty = {
    enable = true;
    settings.command = lib.getExe pkgs.fish;
  };
  stylix.targets.ghostty.enable = true;
  home.sessionVariables.TERMINAL = lib.mkDefault "ghostty";
  xdg.terminal-exec = {
    enable = true;
    settings.default = [
      "com.mitchellh.ghostty.desktop"
      "kitty.desktop"
    ];
  };
}
