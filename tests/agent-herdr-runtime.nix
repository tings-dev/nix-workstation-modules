# Production guest composition, real SSH transport, no host Herdr or credentials.
{ workstation, pkgs }:
let
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  guest = mkGuest [
    workstation.nixosModules.dev
    {
      home-manager.users.agent.imports = [ workstation.homeModules.dev ];
      networking.hostName = "herdr";
      workstation.agentEnvironment = {
        linkId = 106;
        memoryMiB = 1536;
        storageMiB = 24576;
      };
    }
  ];
in
pkgs.testers.runNixOSTest {
  name = "agent-herdr-session-persistence";
  meta.timeout = 1800;
  nodes.host = {
    imports = [ workstation.nixosModules.agent-environments ];
    workstation.agentEnvironments.herdr = guest;
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    networking.useDHCP = false;
    virtualisation = {
      cores = 4;
      memorySize = 4096;
      diskSize = 40960;
      qemu.options = [
        "-cpu"
        "host"
      ];
    };
    environment.etc."agent-test-key".source = keys.snakeOilEd25519PrivateKey;
    environment.systemPackages = [
      pkgs.openssh
      pkgs.python3
      pkgs.lsof
    ];
  };
  testScript = builtins.readFile ./test-agent-herdr.py;
}
