# Lightweight terminal tooling suitable for every Home Manager host.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    bat
    eza
    fd
    ripgrep
    tmux
    yazi
    zile
  ];
}
