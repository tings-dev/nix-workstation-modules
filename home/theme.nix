# Standalone Home Manager needs to import and configure Stylix itself. NixOS
# hosts use Stylix's NixOS module, which imports the home module after moving
# its overlays to the shared system package set.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

let
  # Import decisions cannot depend on _module.args. NixOS supplies osConfig
  # in specialArgs; standalone Home Manager leaves it absent.
  standalone = (specialArgs.osConfig or null) == null;
in
{
  imports = lib.optional standalone inputs.stylix.homeModules.stylix;

  stylix = lib.mkMerge [
    (lib.mkIf standalone (import ../theme.nix { inherit pkgs; }))
    {
      # Avoid configuring an unused launcher, including Stylix's deprecated
      # programs.rofi.font assignment, until Rofi is actually enabled.
      targets.rofi.enable = lib.mkDefault config.programs.rofi.enable;
    }
  ];
}
