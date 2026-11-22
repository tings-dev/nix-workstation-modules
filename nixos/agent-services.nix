{
  config,
  lib,
  pkgs,
  ...
}:
let
  parent = config.workstation.agentEnvironment;
  cfg = parent.services;
  namespace = "${config.networking.hostName}.${cfg.baseDomain}";
  label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";
  program = pkgs.writeShellScriptBin "agent-service" ''
    exec ${pkgs.python3}/bin/python3 ${./agent-services.py} "$@"
  '';
  settings = pkgs.writeText "agent-services.json" (
    builtins.toJSON {
      inherit namespace;
      agentUid = config.users.users.agent.uid;
      stateDirectory = "/var/lib/agent-services";
      caBundle = "/etc/ssl/certs/ca-certificates.crt";
    }
  );
  staticConfig = (pkgs.formats.yaml { }).generate "agent-traefik.yaml" {
    global = {
      checkNewVersion = false;
      sendAnonymousUsage = false;
    };
    # Some ACME client/renewal initialization failures are logged at INFO by
    # Traefik. Keep these visible to the operator while certificates remain valid.
    log.level = "INFO";
    entryPoints.https.address = ":443";
    providers = {
      providersThrottleDuration = "250ms";
      file = {
        directory = "/var/lib/agent-services/dynamic";
        watch = true;
      };
    };
    certificatesResolvers.letsencrypt.acme = {
      storage = "/var/lib/traefik/acme.json";
      caServer = cfg.acmeServer;
      dnsChallenge = {
        provider = cfg.dnsProvider;
      }
      // lib.optionalAttrs (cfg.dnsResolvers != [ ]) { resolvers = cfg.dnsResolvers; };
    }
    // lib.optionalAttrs (cfg.acmeEmail != null) { email = cfg.acmeEmail; };
  };
  secretPaths = builtins.attrValues cfg.dnsCredentialFiles;
  shares = builtins.attrValues (parent.shares or { });
  beneath = directory: path: path == directory || lib.hasPrefix "${directory}/" path;
  privateSecret =
    path:
    lib.hasPrefix "/" path
    && !(lib.hasInfix "/../" "${path}/" || lib.hasInfix "/./" "${path}/" || lib.hasInfix "//" path)
    && !(builtins.any (directory: beneath directory path) (
      [
        "/nix/store"
        "/home/agent"
        "/tmp"
        "/var/tmp"
      ]
      ++ map (share: share.destination) shares
    ));
in
{
  options.workstation.agentEnvironment.services = {
    enable = lib.mkEnableOption "private agent-registered HTTPS services";
    baseDomain = lib.mkOption {
      type = lib.types.strMatching "${label}([.]${label})+";
      description = "Operator-controlled base domain; the VM name is prepended.";
    };
    acmeEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Operator's ACME account contact email; required when enabled so Traefik reuses the persisted account on restart.";
    };
    acmeServer = lib.mkOption {
      type = lib.types.strMatching "https://[^[:space:]]+";
      default = "https://acme-v02.api.letsencrypt.org/directory";
      description = "ACME directory; override for staging or controlled test CAs.";
    };
    dnsProvider = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9_-]*";
      default = "cloudflare";
      description = "Traefik/lego DNS-01 provider.";
    };
    dnsCredentialFiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.strMatching "/[^[:cntrl:]]+");
      default = { };
      example = {
        CF_DNS_API_TOKEN = "/var/lib/agent-service-secrets/cloudflare-token";
      };
      description = "Unsuffixed lego environment variables mapped to protected runtime file names. Loaded through systemd credentials and exposed as *_FILE paths, never token values in Nix.";
    };
    dnsResolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Optional DNS-01 propagation resolvers, as address:port.";
    };
    vpnInterfaces = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "tailscale0"
          "wt0"
        ]
      );
      default =
        lib.optional (parent.vpn.tailscale.enable or false) "tailscale0"
        ++ lib.optional (parent.vpn.netbird.enable or false) "wt0";
      description = "Private ingress interfaces; defaults to the enabled guest VPNs.";
    };
    allowDirectHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Also allow the physical host's dedicated link address to reach HTTPS. Name resolution remains operator-managed.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.acmeEmail != null;
        message = "Agent HTTPS requires an acmeEmail contact to preserve Traefik's ACME account across restarts.";
      }
      {
        assertion =
          builtins.match label config.networking.hostName != null && builtins.stringLength namespace <= 189;
        message = "Agent HTTPS requires a lowercase DNS-label VM name and a namespace of at most 189 characters, leaving room for a 63-character service label.";
      }
      {
        assertion = secretPaths != [ ] && builtins.all privateSecret secretPaths;
        message = "Agent HTTPS requires DNS credential runtime paths outside the Nix store, agent home, temporary directories and shared folders.";
      }
      {
        assertion = builtins.all (
          key: builtins.match "[A-Z][A-Z0-9_]*" key != null && !(lib.hasSuffix "_FILE" key)
        ) (builtins.attrNames cfg.dnsCredentialFiles);
        message = "DNS credential keys must be uppercase lego variable names without the _FILE suffix.";
      }
      {
        assertion = !cfg.allowDirectHost || (parent ? linkId);
        message = "Direct host HTTPS requires the agent environment's dedicated linkId.";
      }
    ];
    environment.systemPackages = [ program ];
    users.groups.agent-services = { };
    users.users.agent-services = {
      isSystemUser = true;
      group = "agent-services";
    };
    # Traefik can read generated routes, but the agent cannot alter them or read
    # the ACME state. The broker never receives Traefik's DNS credential files.
    users.users.traefik.extraGroups = [ "agent-services" ];
    services.traefik = {
      enable = true;
      staticConfigFile = staticConfig;
    };
    systemd.services.traefik = {
      # Wait for initial route generation, but keep serving the last routes
      # when the registration service restarts or temporarily fails.
      wants = [ "agent-services.service" ];
      after = [ "agent-services.service" ];
      environment = lib.mapAttrs' (
        key: _: lib.nameValuePair "${key}_FILE" "%d/${key}"
      ) cfg.dnsCredentialFiles;
      serviceConfig = {
        LoadCredential = lib.mapAttrsToList (key: path: "${key}:${path}") cfg.dnsCredentialFiles;
        RestartSec = "10s";
      };
    };
    systemd.sockets.agent-services = {
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/agent-services/control.sock";
        SocketUser = "agent-services";
        SocketGroup = "agent";
        SocketMode = "0660";
        DirectoryMode = "0755";
        RemoveOnStop = true;
      };
    };
    systemd.services.agent-services = {
      requires = [ "agent-services.socket" ];
      after = [ "agent-services.socket" ];
      serviceConfig = {
        Type = "notify";
        ExecStart = "${program}/bin/agent-service serve --config ${settings}";
        User = "agent-services";
        Group = "agent-services";
        StateDirectory = "agent-services";
        StateDirectoryMode = "0750";
        UMask = "0027";
        Restart = "on-failure";
        RestartSec = "1s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        CapabilityBoundingSet = "";
        MemoryMax = "128M";
        TasksMax = 16;
      };
    };
    # Enforce the private ingress boundary before provider-installed accept
    # rules or the ordinary firewall can accept a connection.
    networking.nftables = {
      enable = true;
      flushRuleset = false;
      tables.agent-services = {
        family = "inet";
        content = ''
          chain ingress {
            type filter hook input priority -10; policy accept;
            tcp dport 443 iifname "lo" return
            ${lib.concatMapStringsSep "\n" (
              iface: ''tcp dport 443 iifname "${iface}" return''
            ) cfg.vpnInterfaces}
            ${lib.optionalString cfg.allowDirectHost ''
              tcp dport 443 iifname "eth0" ip saddr 10.83.${toString parent.linkId}.1 return
            ''}
            tcp dport 443 drop
          }
        '';
      };
    };
    networking.firewall.interfaces =
      lib.genAttrs (cfg.vpnInterfaces ++ lib.optional cfg.allowDirectHost "eth0")
        (_: {
          allowedTCPPorts = [ 443 ];
        });
  };
}
