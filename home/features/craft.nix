# Importable by standalone Home Manager; the host owns graphics and portals.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  craft = import ../../pkgs/craft-apps.nix { inherit inputs lib pkgs; };
in
{
  options.workstation.craft.apps = craft.appsOption;
  config.home.packages = craft.packagesFor config.workstation.craft.apps;
}
