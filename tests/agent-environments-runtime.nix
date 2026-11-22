# Nested QEMU/KVM: a disposable physical host deploys the production guest.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  guest =
    name: id: memory:
    mkGuest [
      workstation.nixosModules.dev
      {
        networking.hostName = name;
        workstation.agentEnvironment = {
          linkId = id;
          cpus = if name == "alpha" then 1 else 2;
          memoryMiB = memory;
          storageMiB = if name == "alpha" then 8192 else 12288;
        };
        networking.nameservers = [ "93.184.216.34" ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.iproute2
          pkgs.nftables
        ];
        # Disposable root authentication is solely for hostile guest-root
        # probes. Production composition forbids root SSH and agent sudo.
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
  name = "agent-environments-lifecycle";
  meta.timeout = 1800;
  nodes.host = {
    imports = [ workstation.nixosModules.agent-environments ];
    workstation.agentEnvironments = {
      alpha = guest "alpha" 101 512;
      beta = guest "beta" 102 768;
    };
    workstation.agentSSH.unattendedIdentity = ".ssh/id_ed25519_unattended.pub";
    workstation.agentNetwork = {
      internetInterfaces = [ "eth1" ];
      extraProtectedIPv4Networks = [
        "11.0.0.0/24"
        "12.0.0.0/24"
      ];
    };
    virtualisation.vlans = [
      1
      2
      3
    ];
    networking.interfaces = {
      eth1 = {
        ipv4.addresses = [
          {
            address = "11.0.0.1";
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = "2001:db8:10::1";
            prefixLength = 64;
          }
        ];
      };
      # Separate routed links stand in for the host's two VPN interfaces.
      eth2.ipv4.addresses = [
        {
          address = "13.0.0.1";
          prefixLength = 24;
        }
      ];
      eth3.ipv4.addresses = [
        {
          address = "15.0.0.1";
          prefixLength = 24;
        }
      ];
    };
    networking.defaultGateway = {
      address = "11.0.0.2";
      interface = "eth1";
    };
    networking.interfaces.eth2.ipv4.routes = [
      {
        address = "14.0.0.0";
        prefixLength = 24;
        via = "13.0.0.2";
      }
    ];
    networking.interfaces.eth3.ipv4.routes = [
      {
        address = "16.0.0.0";
        prefixLength = 24;
        via = "15.0.0.2";
      }
    ];
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    # Exercise coexistence with the host's optional forwarding firewall too.
    networking.firewall = {
      filterForward = true;
      extraForwardRules = ''iifname "control-host" accept'';
    };
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    networking.useDHCP = false;
    services.openssh.enable = true;
    virtualisation = {
      cores = 4;
      memorySize = 4096;
      diskSize = 32768;
      qemu.options = [
        "-cpu"
        "host"
      ];
    };
    # Public test fixtures from nixpkgs, never personal credentials.
    environment.etc."agent-test-key".source = keys.snakeOilEd25519PrivateKey;
    environment.systemPackages = [
      pkgs.openssh
      pkgs.curl
      pkgs.iproute2
    ];
  };
  nodes.destinations = { pkgs, ... }: {
    virtualisation.vlans = [
      1
      2
      3
    ];
    networking.useDHCP = false;
    networking.interfaces = {
      eth1 = {
        ipv4.addresses = [
          {
            address = "11.0.0.2";
            prefixLength = 24;
          }
        ]
        ++
          map
            (address: {
              inherit address;
              prefixLength = 32;
            })
            [
              "93.184.216.34" # Controlled public-egress destination and DNS.
              "192.168.50.2" # Private LAN over the SAME uplink as public egress.
              "12.0.0.2" # Explicitly protected public LAN over that uplink.
              "14.0.0.2" # Public address routed through the first host VPN link.
              "16.0.0.2" # Public address routed through the second host VPN link.
            ];
        ipv6.addresses = [
          {
            address = "2001:db8:10::2";
            prefixLength = 64;
          }
        ];
      };
      eth2.ipv4.addresses = [
        {
          address = "13.0.0.2";
          prefixLength = 24;
        }
      ];
      eth3.ipv4.addresses = [
        {
          address = "15.0.0.2";
          prefixLength = 24;
        }
      ];
    };
    networking.defaultGateway = {
      address = "11.0.0.1";
      interface = "eth1";
    };
    networking.defaultGateway6 = {
      address = "2001:db8:10::1";
      interface = "eth1";
    };
    networking.firewall.allowedTCPPorts = [
      8080
      53
    ];
    networking.firewall.allowedUDPPorts = [ 53 ];
    # A disposable remote account, reached through the permitted public-egress
    # path. Authorization can be revoked at runtime without rebuilding a guest.
    users.users.target = {
      isNormalUser = true;
      hashedPassword = "!";
    };
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        AuthorizedKeysFile = "/var/lib/ssh-target/%u";
      };
    };
    systemd.tmpfiles.rules = [ "d /var/lib/ssh-target 0755 root root -" ];
    services.dnsmasq = {
      enable = true;
      settings = {
        no-resolv = true;
        address = [
          "/public.agent.test/93.184.216.34"
          "/private.agent.test/192.168.50.2"
          "/protected.agent.test/12.0.0.2"
        ];
      };
    };
    systemd.services.endpoint = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 8080 --bind :: --directory /etc/endpoint";
    };
    environment.etc."endpoint/index.html".text = "controlled-egress-ok\n";
  };
  testScript = builtins.readFile ./test-agent-environments.py;
}
