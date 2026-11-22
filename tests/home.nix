# A fictional user, shared by the standalone and integrated checks.
# Shared defaults and optional selections remain visible at the entrypoint.
{ workstation, ... }:
{
  imports = [
    ./personal-data-home.nix
    workstation.homeModules.common
    workstation.homeModules.desktop-dev
    workstation.homeModules.craft
    workstation.homeModules.seat
    workstation.homeModules.ssh-key
    workstation.homeModules.security-key
    workstation.homeModules.unattended-key
    workstation.homeModules.management
  ];

  workstation.features.syncthing.enable = true;
  workstation.repositoryPath = "/home/fixture/workstations";

  home = {
    username = "fixture";
    homeDirectory = "/home/fixture";
    stateVersion = "26.05";
  };
}
