# System support for Sway. Home entrypoints select home/features/seat.nix.
modules:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homes = config.home-manager.users or { };
  kanataHomes = lib.filterAttrs (_: home: home.systemd.user.services ? kanata) homes;
in
{
  imports = [ (modules.load ./desktop.nix) ];

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
  };
  services.displayManager.defaultSession = lib.mkDefault "sway";
  hardware.graphics.enable = lib.mkDefault true;

  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # A graphical greeter can override these leaf defaults at normal mkDefault
  # priority. Host-specific greeters remain in the eventual host entrypoints.
  services.greetd = {
    enable = lib.mkDefault true;
    settings.default_session = {
      command = lib.mkOverride 1100 "${lib.getExe pkgs.tuigreet} --time --remember --cmd sway";
      user = lib.mkOverride 1100 "greeter";
    };
  };
  # Display managers launching a bare Exec=sway may not source /etc/profile.
  systemd.services.greetd.environment.PATH =
    lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin";
  assertions = [
    {
      assertion = (config.services.greetd.settings.default_session.command or "") != "";
      message = "The seat requires a greetd default-session command.";
    }
  ];

  # Coordinate ownership without enabling a home feature or naming a user.
  home-manager.sharedModules = [
    ({ config, lib, ... }: {
      wayland.windowManager.sway.package = lib.mkIf config.wayland.windowManager.sway.enable null;
    })
  ];
  hardware.uinput.enable = lib.mkIf (kanataHomes != { }) true;
  users.users = lib.mapAttrs (_: _: {
    extraGroups = [
      "input"
      "uinput"
    ];
  }) kanataHomes;
}
