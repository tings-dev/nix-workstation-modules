{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  guests = config.workstation.agentEnvironments;
  names = builtins.attrNames guests;
  linkId = name: guests.${name}.config.workstation.agentEnvironment.linkId;
  taps = map (name: "ae-${name}") names;
  tapSet = lib.concatMapStringsSep ", " (tap: ''"${tap}"'') taps;
  network = config.workstation.agentNetwork;
  guestAddress = name: "10.83.${toString (linkId name)}.2";
  sshPolicy = {
    targets = lib.genAttrs names (name: {
      HostName = guestAddress name;
      HostKeyAlias = "agent-env-${name}";
    });
    user = "agent";
    knownHostsFile = ".ssh/agent-environments_known_hosts";
    identityFile = config.workstation.agentSSH.unattendedIdentity;
    identitySocket = "unattended-key.sock";
    options = {
      Port = 22;
      GlobalKnownHostsFile = "/dev/null";
      StrictHostKeyChecking = true;
      ForwardAgent = false;
      ClearAllForwardings = true;
    } // lib.optionalAttrs (sshPolicy.identityFile != null) {
      IdentitiesOnly = true;
      BatchMode = true;
    };
  };
  uplinkSet = lib.concatMapStringsSep ", " (iface: ''"${iface}"'') network.internetInterfaces;
  protectedNetworks = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ]
  ++ network.extraProtectedIPv4Networks;
  stateManifest = pkgs.writeText "agent-environment-state.json" (
    builtins.toJSON {
      inherit names;
      inherit (config.microvm) stateDir;
      runtimeDir = "/run";
      lockDir = "/run/lock";
      gcRootsDir = "/nix/var/nix/gcroots/microvm";
      systemctl = lib.getExe' pkgs.systemd "systemctl";
      tmpfiles = lib.getExe' pkgs.systemd "systemd-tmpfiles";
      lsof = lib.getExe pkgs.lsof;
    }
  );
  stateProgram = pkgs.writers.writePython3 "agent-environment-state" { } (
    builtins.readFile ../agent-environment-state.py
  );
  hostKeyProgram = pkgs.writers.writePython3 "agent-environment-host-key" { } (
    builtins.readFile ../agent-host-key.py
  );
  stateHelper = pkgs.writeShellScript "agent-environment-state" ''
    exec ${stateProgram} ${stateManifest} "$@"
  '';
  helper = pkgs.callPackage ../../pkgs/agent-env.nix {
    inherit guests sshPolicy stateHelper hostKeyProgram;
    inherit (config.networking) hostName;
    vmStateDir = config.microvm.stateDir;
  };
in
{
  imports = [ inputs.microvm.nixosModules.host ];
  options.workstation.agentEnvironments = lib.mkOption {
    type = lib.types.attrsOf lib.types.unspecified;
    default = { };
    description = "Explicit, already evaluated guest hosts deployed here.";
  };
  options.workstation.agentSSH.unattendedIdentity = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Home-relative incoming public identity selected through the physical host's scoped unattended-key.sock agent. Null retains ordinary OpenSSH identity selection.";
  };
  options.workstation.agentNetwork = {
    internetInterfaces = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_.:-]{1,15}");
      default = [ ];
      description = "Explicit physical internet uplinks; never include bridges, guest links or VPN interfaces. An empty list denies all egress.";
    };
    extraProtectedIPv4Networks = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "([0-9]{1,3}[.]){3}[0-9]{1,3}/[0-9]{1,2}");
      default = [ ];
      description = "Additional protected IPv4 CIDRs, including any publicly addressed LANs or routed internal resources. Private and special-use ranges are always denied.";
    };
  };
  config = lib.mkIf (guests != { }) {
    assertions = [
      {
        assertion = builtins.all (
          iface:
          !(builtins.elem iface taps)
          && iface != "lo"
          && iface != config.services.tailscale.interfaceName
          && !(builtins.any (client: iface == client.interface) (
            builtins.attrValues config.services.netbird.clients
          ))
        ) network.internetInterfaces;
        message = "Agent internet interfaces must exclude guest links, loopback and host VPN interfaces.";
      }
      {
        assertion = builtins.length (lib.unique (map linkId names)) == builtins.length names;
        message = "Agent environments on a host need distinct linkId values.";
      }
      {
        assertion = builtins.all (
          name:
          builtins.match "[a-z][a-z0-9-]{0,11}" name != null
          && guests.${name}.config.networking.hostName == name
        ) names;
        message = "Agent environment names must match the guest hostname and fit a 15-character TAP name (ae- plus up to 12 characters).";
      }
    ];
    microvm.vms = lib.mapAttrs (_: guest: {
      evaluatedConfig = guest;
      autostart = false;
      restartIfChanged = false;
    }) guests;
    programs.ssh.hosts = lib.mapAttrs (
      name: target:
      target // sshPolicy.options // {
        order = lib.mkDefault (1000 + linkId name);
        User = sshPolicy.user;
        UserKnownHostsFile = "~/${sshPolicy.knownHostsFile}";
      }
      // lib.optionalAttrs (sshPolicy.identityFile != null) {
        IdentityFile = "~/${sshPolicy.identityFile}";
        IdentityAgent = "/run/user/%i/${sshPolicy.identitySocket}";
      }
    ) sshPolicy.targets;
    systemd.services =
      lib.genAttrs (map (name: "microvm@${name}") names) (_: {
        # Stop guests before removing enforcement, and refuse startup without it.
        bindsTo = [ "nftables.service" ];
        after = [ "nftables.service" ];
        serviceConfig.UMask = "0077";
      })
      // lib.listToAttrs (
        lib.concatMap (
          name:
          lib.optional (guests.${name}.config.workstation.agentEnvironment.shares != { }) {
            name = "microvm-virtiofsd@${name}";
            value.serviceConfig = {
              # Sources may be anywhere, including /tmp. Each export creates its
              # own mount namespace and pins only its declared directory there.
              PrivateTmp = lib.mkForce false;
              RuntimeDirectory = "agent-shares-${name}";
              RuntimeDirectoryMode = "0700";
              UMask = "0077";
            };
          }
        ) names
      );
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    environment.systemPackages = [ helper ];
    networking.networkmanager.unmanaged = map (tap: "interface-name:${tap}") taps;
    systemd.network.enable = true;
    # On-demand TAPs may all be absent. When another backend manages the host
    # network, its readiness must not depend on a networkd-managed link existing.
    systemd.network.wait-online.enable = lib.mkIf (!config.networking.useNetworkd) (
      lib.mkDefault false
    );
    systemd.network.networks = lib.listToAttrs (
      map (name: {
        name = "30-agent-${name}";
        value = {
          matchConfig.Name = "ae-${name}";
          address = [ "10.83.${toString (linkId name)}.1/30" ];
          networkConfig = {
            DHCP = "no";
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
          };
          linkConfig.RequiredForOnline = "no";
        };
      }) names
    );
    # Other host forwarding policies can still narrow permitted egress.
    networking.firewall.extraForwardRules = lib.mkIf config.networking.firewall.filterForward (
      lib.optionalString (network.internetInterfaces != [ ]) ''
        iifname { ${tapSet} } oifname { ${uplinkSet} } meta nfproto ipv4 accept
      ''
    );
    # Drop decisions precede host/VPN accept rules. Reloads are atomic and only
    # replace our own table; no global ruleset flush may erase VPN policy.
    networking.nftables = {
      enable = true;
      flushRuleset = false;
      tables.agent-environments = {
        family = "inet";
        content = ''
          set protected_ipv4 {
            type ipv4_addr; flags interval; auto-merge;
            elements = { ${lib.concatStringsSep ", " protectedNetworks} }
          }
          chain prerouting {
            type filter hook prerouting priority raw; policy accept;
            iifname { ${tapSet} } meta nfproto ipv6 drop
            ${lib.concatMapStringsSep "\n" (name: ''
              iifname "ae-${name}" ip saddr != ${guestAddress name} drop
            '') names}
          }
          chain input {
            type filter hook input priority -10; policy accept;
            iifname { ${tapSet} } ct direction reply ct state established,related accept
            iifname { ${tapSet} } drop
          }
          chain forward {
            type filter hook forward priority -10; policy accept;
            iifname { ${tapSet} } jump from_guest
            oifname { ${tapSet} } meta nfproto ipv4 ct direction reply ct state established,related accept
            oifname { ${tapSet} } drop
          }
          chain from_guest {
            ct state invalid drop
            ip daddr @protected_ipv4 drop
            ${lib.optionalString (network.internetInterfaces != [ ]) ''
              oifname { ${uplinkSet} } meta nfproto ipv4 accept
            ''}
            drop
          }
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ${lib.optionalString (network.internetInterfaces != [ ]) ''
              iifname { ${tapSet} } oifname { ${uplinkSet} } meta nfproto ipv4 masquerade
            ''}
          }
        '';
      };
    };
  };
}
