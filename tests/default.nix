# Exercise the same public entry points used by consumers.
{ workstation }:
let
  system = "x86_64-linux";
  pkgs = workstation.inputs.nixpkgs.legacyPackages.${system};
  standalone = workstation.lib.mkHome {
    imports = [ ./home.nix ];
    workstation.management.switchCommand = [
      "${workstation.inputs.home-manager.packages.${system}.default}/bin/home-manager"
      "switch"
      "--flake"
      ".#fixture"
    ];
  };
  integrated = workstation.lib.mkHost ./nixos.nix;
in
{
  agent-environment-contracts = import ./agent-environments.nix { inherit workstation pkgs; };
  agent-environment-commands = import ./agent-environment-commands.nix { inherit workstation pkgs; };
  agent-environment-state = import ./agent-environment-state.nix { inherit pkgs; };
  agent-services = import ./agent-services.nix { inherit workstation pkgs; };
  agent-services-runtime = import ./agent-services-runtime.nix { inherit workstation pkgs; };
  agent-environment-runtime = import ./agent-environments-runtime.nix { inherit workstation pkgs; };
  agent-development-runtime = import ./agent-development-runtime.nix { inherit workstation pkgs; };
  agent-herdr-runtime = import ./agent-herdr-runtime.nix { inherit workstation pkgs; };
  agent-vpn-runtime = import ./agent-vpn-runtime.nix { inherit workstation pkgs; };
  agent-shares-runtime = import ./agent-shares-runtime.nix { inherit workstation pkgs; };
  executable-helpers = import ./executable-helpers.nix { inherit pkgs; };
  njust = import ./njust.nix { inherit pkgs; };
  prepared-updates = import ./prepared-updates.nix { inherit pkgs; };
  personal-data-runtime = import ./personal-data.nix { inherit workstation pkgs; };
  codex-reset-calendar = import ./codex-reset-calendar.nix { inherit pkgs; };
  identity-routing = import ./identity.nix { inherit workstation pkgs; };
  syncthing-runtime = import ./syncthing.nix { inherit workstation pkgs; };
  atuin-runtime = import ./atuin.nix { inherit workstation pkgs; };
  standalone-home = (workstation.lib.mkHome ../examples/standalone/home.nix).activationPackage;
  standalone-workstation-home = standalone.activationPackage;
  integrated-system = integrated.config.system.build.toplevel;
}
