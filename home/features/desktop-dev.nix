# Graphical development applications, independent of the chosen desktop session.
modules@{ inputs, ... }:
{ pkgs, ... }:
let
  agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  imports = [
    (modules.load ./dev.nix)
    (modules.load ./desktop.nix)
    ../programs/zed.nix
    ../programs/pycharm.nix
    (modules.load ../programs/herdr.nix)
  ];

  home.packages = [
    agents.chatgpt
    agents.claude-desktop
    agents.herdr-app
  ];
}
