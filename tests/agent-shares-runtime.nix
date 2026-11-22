{ workstation, pkgs }:
let
  lib = pkgs.lib;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  share = source: destination: access: hostUid: hostGid: {
    inherit
      source
      destination
      access
      hostUid
      hostGid
      ;
  };
  guest =
    name: id: shares:
    mkGuest [
      {
        networking.hostName = name;
        workstation.agentEnvironment = {
          linkId = id;
          memoryMiB = 768;
          storageMiB = 8192;
          inherit shares;
        };
        environment.systemPackages = [ pkgs.python3 ];
        # Only the disposable test permits hostile guest-root probes over SSH.
        services.openssh.settings = {
          PermitRootLogin = lib.mkForce "prohibit-password";
          AllowUsers = lib.mkForce [
            "agent"
            "root"
          ];
        };
        users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      }
    ];
in
pkgs.testers.runNixOSTest {
  name = "agent-shared-folders";
  meta.timeout = 1800;
  nodes.host = {
    imports = [ workstation.nixosModules.agent-environments ];
    # Exercise reactivation after deleting a guest's private disk.
    system.switch.enable = true;
    workstation.agentEnvironments = {
      alpha = guest "alpha" 104 {
        project = share "/tmp/agent-share-test/work alpha" "/workspace/project" "read-write" 1234 2345;
        reference = share "/srv/agent-share-test/reference" "/workspace/reference" "read-only" 1234 2345;
      };
      beta = guest "beta" 105 {
        project = share "/srv/agent-share-test/beta" "/home/agent/project" "read-write" 1235 2346;
      };
    };
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    networking.useDHCP = false;
    virtualisation = {
      cores = 4;
      memorySize = 4096;
      diskSize = 32768;
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
  testScript = builtins.readFile ./test-agent-shares.py;
}
