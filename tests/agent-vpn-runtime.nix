# Real lifecycle/SSH and client daemons, with controlled overlay/DNS transports.
# Provider enrollment and account ACLs remain ticket 09's live acceptance.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  guest =
    name: id: tailscale: netbird: network:
    mkGuest [
      workstation.nixosModules.dev
      {
        networking.hostName = name;
        workstation.agentEnvironment = {
          linkId = id;
          memoryMiB = 768;
          storageMiB = 8192;
          vpn = {
            tailscale.enable = tailscale;
            netbird = {
              enable = netbird;
              managementURL = "https://management.example.test";
              ipv4Network = network;
            };
          };
        };
        environment.systemPackages = with pkgs; [
          curl
          iproute2
          jq
          python3
          dnsmasq
          netcat-openbsd
        ];
        # Privileged probes solely set up controlled test transports. No real
        # account enrollment, host data or production administrative login.
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
  name = "agent-vpn-coexistence";
  meta.timeout = 1800;
  nodes.host = {
    imports = [ workstation.nixosModules.agent-environments ];
    workstation.agentEnvironments = {
      vpn = guest "vpn" 107 true true "100.90.0.0/16";
      fresh = guest "fresh" 108 true true "10.255.0.0/16";
    };
    specialisation = lib.genAttrs [ "tailscale" "netbird" "neither" ] (mode: {
      configuration.workstation.agentEnvironments.vpn = lib.mkForce (
        guest "vpn" 107 (mode == "tailscale") (mode == "netbird") "100.90.0.0/16"
      );
    });
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
      pkgs.lsof
    ];
  };
  testScript = builtins.readFile ./test-agent-vpn.py;
}
