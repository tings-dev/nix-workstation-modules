# Fast contracts complement, but never replace, the real nested-KVM test.
{ workstation, pkgs }:
let
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  fixture = mkGuest [
    workstation.nixosModules.dev
    {
      networking.hostName = "fixture";
      workstation.agentEnvironment.linkId = 1;
      home-manager.users.agent.imports = [ workstation.homeModules.dev ];
    }
  ];
  guest = fixture.config;
  operatorGuest = (fixture.extendModules {
    modules = [ { workstation.agentEnvironment.operatorAuthorizedKeys = guest.workstation.agentEnvironment.authorizedKeys; } ];
  }).config;
  hostFixture = workstation.lib.mkHost {
    imports = [ workstation.nixosModules.agent-environments workstation.nixosModules.netbird ];
    boot.isContainer = true;
    networking.useHostResolvConf = false;
    system.stateVersion = "26.05";
    networking.hostName = "laptop";
    workstation.agentEnvironments.fixture = fixture;
    workstation.agentNetwork.internetInterfaces = [ "eth0" ];
    workstation.agentSSH.unattendedIdentity = ".ssh/id_ed25519_unattended.pub";
    # ssh -G runs in the build sandbox, which rejects the systemd proxy include.
    programs.ssh.systemd-ssh-proxy.enable = false;
  };
  host = hostFixture.config;
  networkdHost =
    (hostFixture.extendModules {
      modules = [ { networking.useNetworkd = true; } ];
    }).config;
  noUplinkHost =
    (hostFixture.extendModules {
      modules = [ { workstation.agentNetwork.internetInterfaces = pkgs.lib.mkForce [ ]; } ];
    }).config;
  invalidUplink =
    iface:
    builtins.all (a: a.assertion) (
      (hostFixture.extendModules {
        modules = [ { workstation.agentNetwork.internetInterfaces = pkgs.lib.mkForce [ iface ]; } ];
      }).config.assertions
    );
  invalid =
    setting: value:
    builtins.tryEval (
      (fixture.extendModules {
        modules = [ { workstation.agentEnvironment.${setting} = pkgs.lib.mkForce value; } ];
      }).config.workstation.agentEnvironment.${setting}
    );
  share = {
    source = "/srv/agent-project";
    destination = "/workspace/project";
    access = "read-write";
    hostUid = 1234;
    hostGid = 2345;
  };
  withShares =
    shares:
    (fixture.extendModules {
      modules = [ { workstation.agentEnvironment.shares = shares; } ];
    }).config;
  validShares = shares: builtins.all (a: a.assertion) (withShares shares).assertions;
  invalidShareType =
    changes:
    !(builtins.tryEval (
      builtins.deepSeq (withShares { project = share // changes; }).workstation.agentEnvironment.shares
        true
    )).success;
  vpnGuest =
    tailscale: netbird:
    (fixture.extendModules {
      modules = [
        {
          workstation.agentEnvironment.vpn = {
            tailscale.enable = tailscale;
            netbird = {
              enable = netbird;
              managementURL = "https://management.example.test";
              ipv4Network = "100.90.0.0/16";
            };
          };
        }
      ];
    }).config;
  vpnAssertionsHold =
    changes:
    builtins.all (a: a.assertion) (
      (fixture.extendModules {
        modules = [
          {
            workstation.agentEnvironment.vpn = {
              tailscale.enable = false;
              netbird = {
                enable = true;
                managementURL = null;
                ipv4Network = null;
              }
              // changes;
            };
          }
        ];
      }).config.assertions
    );
  vpnNetworkType = fixture.options.workstation.agentEnvironment.vpn.netbird.ipv4Network.type;
in
assert builtins.all vpnNetworkType.check [
  "10.255.0.0/16"
  "172.16.0.0/16"
  "192.168.0.0/16"
  "100.90.0.0/16"
];
assert builtins.all (value: !(vpnNetworkType.check value)) [
  "10.256.0.0/16"
  "10.255.1.0/16"
  "10.255.0.0/8"
  "172.32.0.0/16"
  "100.128.0.0/16"
  "8.8.0.0/16"
];
assert !(vpnAssertionsHold { });
assert !(vpnAssertionsHold { managementURL = "https://management.example.test"; });
assert !(vpnAssertionsHold { ipv4Network = "100.90.0.0/16"; });
assert builtins.all
  (
    pair:
    let
      c = vpnGuest (builtins.elemAt pair 0) (builtins.elemAt pair 1);
    in
    builtins.all (a: a.assertion) c.assertions
    && c.services.tailscale.enable == builtins.elemAt pair 0
    && (c.services.netbird.clients ? netbird) == builtins.elemAt pair 1
    && c.users.users.agent.extraGroups == [ ]
    && c.services.tailscale.authKeyFile == null
    && !(builtins.hasAttr "agent-enroll-tailscale" c.systemd.services)
    && !(builtins.hasAttr "agent-enroll-netbird" c.systemd.services)
  )
  [
    [
      false
      false
    ]
    [
      true
      false
    ]
    [
      false
      true
    ]
    [
      true
      true
    ]
  ];
assert (vpnGuest true true).services.resolved.enable;
assert (vpnGuest true true).services.netbird.clients.netbird.hardened;
assert !(vpnGuest true true).services.netbird.clients.netbird.login.enable;
assert (vpnGuest true true).services.netbird.clients.netbird.dir.state == "/var/lib/netbird";
assert !(vpnGuest true true).networking.nftables.flushRuleset;
assert guest.users.users.agent.isNormalUser;
assert guest.users.users.agent.extraGroups == [ ];
assert builtins.attrNames (pkgs.lib.filterAttrs (_: user: user.isNormalUser) guest.users.users) == [ "agent" ];
assert !guest.security.sudo.enable;
assert !(guest.users.users ? operator);
assert fixture.options.workstation.agentEnvironment.operatorAuthorizedKeys.default == [ ];
assert operatorGuest.security.sudo.enable;
assert
  operatorGuest.users.users.operator.openssh.authorizedKeys.keys
  == operatorGuest.workstation.agentEnvironment.operatorAuthorizedKeys;
assert operatorGuest.services.openssh.settings.PermitRootLogin == "no";
assert
  operatorGuest.services.openssh.settings.AllowUsers == [
    "agent"
    "operator"
  ];
assert operatorGuest.users.users.operator.homeMode == "0700";
assert operatorGuest.users.users.agent.extraGroups == [ ];
assert operatorGuest.nix.settings.trusted-users == [ "root" ];
assert builtins.any (
  rule:
  rule.users == [ "operator" ]
  && builtins.any (
    command: command.command == "ALL" && builtins.elem "NOPASSWD" command.options
  ) rule.commands
) operatorGuest.security.sudo.extraRules;
assert guest.nix.settings.trusted-users == [ "root" ];
assert guest.nix.settings.auto-optimise-store;
assert guest.systemd.services.nix-daemon.enable;
assert guest.microvm.writableStoreOverlay == null;
assert guest.fileSystems."/nix/store".fsType == "none";
assert guest.users.users.agent.linger;
assert guest.users.users.agent.subUidRanges != [ ];
assert guest.users.users.agent.subGidRanges != [ ];
assert guest.programs.nix-ld.enable;
assert guest.virtualisation.podman.enable;
assert !guest.virtualisation.podman.dockerSocket.enable;
assert !guest.virtualisation.docker.enable;
assert !guest.systemd.sockets.podman.enable;
assert guest.home-manager.users.agent.programs.direnv.enable;
assert guest.home-manager.users.agent.programs.atuin.enable;
assert !guest.home-manager.users.agent.programs.atuin.settings.auto_sync;
assert guest.home-manager.users.agent.programs.atuin.package == pkgs.atuin;
assert !(guest.home-manager.users.agent.home.file ? ".ssh/config");
assert !(guest.home-manager.users.agent.home.file ? ".codex/auth.json");
assert !guest.services.syncthing.enable && !guest.services.tailscale.enable;
assert !guest.services.netbird.enable;
assert guest.microvm.hypervisor == "qemu";
assert fixture.options.workstation.agentEnvironment.shares.default == { };
assert guest.microvm.shares == [ ];
assert validShares { project = share; };
assert (builtins.head (withShares { project = share; }).microvm.shares).proto == "virtiofs";
assert
  !(validShares {
    project = share;
    duplicate = share;
  });
assert
  !(validShares {
    project = share;
    nested = share // {
      source = "${share.source}/nested";
      destination = "/workspace/other";
    };
  });
assert
  !(validShares {
    project = share;
    nested = share // {
      source = "/srv/other";
      destination = "${share.destination}/nested";
    };
  });
assert validShares {
  project = share;
  sibling = share // {
    source = "${share.source}-other";
    destination = "${share.destination}-other";
  };
};
assert !(validShares { "bad/name" = share; });
assert builtins.all
  (
    destination:
    !(validShares {
      project = share // {
        inherit destination;
      };
    })
  )
  [
    "/etc/project"
    "/nix/store"
    "/var"
    "/home"
    "/home/agent"
    "/home/agent/.ssh"
  ];
assert builtins.all
  (
    source:
    !(validShares {
      project = share // {
        inherit source;
      };
    })
  )
  [
    "/run/service"
    "/nix/var/nix"
    "/var/lib/microvms/other"
  ];
assert builtins.all (source: invalidShareType { inherit source; }) [
  "/"
  "relative"
  "/srv/../etc"
  "/srv/./data"
  "/srv//data"
  "/srv/data/"
  "/srv/data\nsecret"
];
assert invalidShareType { destination = "/workspace/../etc"; };
assert invalidShareType { hostUid = 0; };
assert invalidShareType { hostGid = 0; };
assert invalidShareType { access = "write"; };
assert guest.microvm.vcpu == 2 && guest.microvm.mem == 1536;
assert (builtins.head guest.microvm.volumes).size == 16384;
assert guest.home-manager.users.agent.home.homeDirectory == "/home/agent";
assert !guest.services.openssh.settings.PasswordAuthentication;
assert !guest.services.openssh.settings.AllowAgentForwarding;
assert guest.systemd.services.agent-ssh-client-key.serviceConfig.User == "agent";
assert builtins.elem "sshd.service" guest.systemd.services.agent-ssh-client-key.before;
assert !(builtins.elem "agent-ssh-client-key.service" guest.systemd.services.sshd.requires);
assert guest.systemd.services.agent-age-key.serviceConfig.User == "agent";
assert guest.systemd.services.agent-age-key.serviceConfig.Group == "agent";
assert guest.systemd.services.agent-age-key.serviceConfig.WorkingDirectory == "/home/agent";
assert guest.systemd.services.agent-age-key.serviceConfig.UMask == "0077";
assert builtins.elem "multi-user.target" guest.systemd.services.agent-age-key.wantedBy;
assert builtins.elem "sshd.service" guest.systemd.services.agent-age-key.before;
assert !(builtins.elem "agent-age-key.service" guest.systemd.services.sshd.requires);
assert builtins.elem pkgs.age guest.environment.systemPackages;
assert guest.services.openssh.settings.PermitRootLogin == "no";
assert guest.networking.defaultGateway.address == "10.83.1.1";
assert guest.networking.defaultGateway.interface == "eth0";
assert
  guest.networking.nameservers == [
    "9.9.9.9"
    "149.112.112.112"
  ];
assert host.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
assert !host.networking.nftables.flushRuleset;
assert builtins.elem "nftables.service" host.systemd.services."microvm@fixture".bindsTo;
assert builtins.all (a: a.assertion) noUplinkHost.assertions;
assert !(invalidUplink "ae-fixture");
assert !(invalidUplink "lo");
assert !(invalidUplink "tailscale0");
assert !(invalidUplink "wt0");
assert guest.users.users.agent.openssh.authorizedKeys.keys != [ ];
assert !host.microvm.vms.fixture.autostart;
assert !host.systemd.network.wait-online.enable;
assert networkdHost.systemd.network.wait-online.enable;
assert !(invalid "memoryMiB" 0).success;
assert !(invalid "cpus" 0).success;
assert !(invalid "storageMiB" (-1)).success;
assert !(invalid "linkId" 0).success;
assert !(invalid "authorizedKeys" [ ]).success;
pkgs.runCommand "agent-environment-contracts" { nativeBuildInputs = [ pkgs.openssh pkgs.age ]; } ''
  age_setup=${pkgs.writeShellScript "agent-age-key-setup" guest.systemd.services.agent-age-key.script}
  umask 077
  mkdir age-alpha age-beta
  (
    cd age-alpha
    "$age_setup"
    key=.config/sops/age/keys.txt
    test "$(stat -c %a .config/sops/age)" = 700
    test "$(stat -c %a "$key")" = 600
    cp "$key" original-key
    age-keygen -y "$key" > recipient
    printf 'guest secret\n' > plaintext
    age -r "$(cat recipient)" -o ciphertext plaintext
    age -d -i "$key" ciphertext | cmp plaintext -
    chmod 644 "$key"
    chmod 755 .config/sops/age
    "$age_setup"
    cmp original-key "$key"
    test "$(stat -c %a .config/sops/age)" = 700
    test "$(stat -c %a "$key")" = 600
    printf 'invalid identity\n' > "$key"
    if "$age_setup"; then
      echo 'Invalid age identity was silently accepted or replaced' >&2
      exit 1
    fi
    test "$(cat "$key")" = 'invalid identity'
    rm "$key"
    ln -s missing-key "$key"
    if "$age_setup"; then
      echo 'Dangling age identity symlink was silently replaced' >&2
      exit 1
    fi
    test -L "$key"
    test ! -e .config/sops/age/missing-key
  )
  (
    cd age-beta
    "$age_setup"
    age-keygen -y .config/sops/age/keys.txt > recipient
  )
  if cmp -s age-alpha/recipient age-beta/recipient; then
    echo 'Independent guests must have different age identities' >&2
    exit 1
  fi
  cfg=${
    pkgs.writeText "agent-environment-ssh-config" host.environment.etc."ssh/ssh_config".text
  }
  ssh -G -F "$cfg" fixture > effective
  grep -Fx 'hostname 10.83.1.2' effective
  grep -Fx 'user agent' effective
  grep -Fx 'hostkeyalias agent-env-fixture' effective
  grep -Fx 'stricthostkeychecking true' effective
  grep -F 'userknownhostsfile ' effective | grep -F '/.ssh/agent-environments_known_hosts'
  grep -Fx 'globalknownhostsfile /dev/null' effective
  grep -Fx 'forwardagent no' effective
  grep -Fx 'clearallforwardings yes' effective
  grep -Fx 'identitiesonly yes' effective
  grep -F 'identityagent ' effective | grep -F '/unattended-key.sock'
  grep -F 'identityfile ' effective | grep -F '/.ssh/id_ed25519_unattended.pub'
  ssh -G -F "$cfg" -l operator fixture > operator
  grep -Fx 'hostname 10.83.1.2' operator
  grep -Fx 'user operator' operator
  ssh -G -F "$cfg" unrelated.invalid > unrelated
  if grep -E 'agent-env-fixture|agent-environments_known_hosts|unattended-key' unrelated; then
    exit 1
  fi
  touch "$out"
''
