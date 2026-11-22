# A synthetic container configuration, never a deployment target.
# Container mode avoids inventing a disk layout or boot loader for a real host.
# Exercise the shared baseline alongside the fictional Home Manager user.
{ workstation, ... }:
{
  imports = [
    workstation.nixosModules.common
    workstation.nixosModules.hardware
    workstation.nixosModules.gitea-runner
    workstation.nixosModules.dev
    workstation.nixosModules.craft
    workstation.nixosModules.seat
    workstation.nixosModules.management
  ];

  boot.isContainer = true;
  networking.hostName = "fixture";
  networking.useDHCP = false;
  # Exercise the shared DNS manager instead of inheriting the container host's
  # resolv.conf, which systemd-resolved cannot manage.
  networking.useHostResolvConf = false;
  system.stateVersion = "26.05";

  users.users.fixture = {
    isNormalUser = true;
    home = "/home/fixture";
  };
  workstation.giteaRunner = {
    url = "https://git.example.invalid";
    tokenFile = "/run/secrets/fixture-runner-token";
  };
  home-manager.users.fixture.imports = [ ./home.nix workstation.homeModules.prepared-updates ];
}
