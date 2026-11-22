{ workstation, pkgs }:
let
  lib = pkgs.lib;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  fixture = mkGuest [
    {
      networking.hostName = "fixture";
      workstation.agentEnvironment = {
        linkId = 1;
        shares.project = {
          source = "/srv/test-project";
          destination = "/workspace/project";
          access = "read-write";
          hostUid = 1000;
          hostGid = 100;
        };
      };
    }
  ];
  disabled = fixture.config;
  enabled =
    changes:
    (fixture.extendModules {
      modules = [
        {
          workstation.agentEnvironment.services = {
            enable = true;
            baseDomain = "envs.example.test";
            acmeEmail = "operator@example.test";
            vpnInterfaces = [
              "tailscale0"
              "wt0"
            ];
            allowDirectHost = false;
            dnsCredentialFiles.CF_DNS_API_TOKEN = "/var/lib/agent-service-secrets/cloudflare-token";
          } // changes;
        }
      ];
    }).config;
  c = enabled { };
  valid = changes: builtins.all (a: a.assertion) (enabled changes).assertions;
in
assert !fixture.options.workstation.agentEnvironment.services.enable.default;
assert !disabled.services.traefik.enable;
assert !(disabled.systemd.sockets ? agent-services);
assert valid { };
assert !(valid { acmeEmail = null; });
assert c.users.users.agent.extraGroups == [ ];
assert c.systemd.services.agent-services.serviceConfig.User == "agent-services";
assert c.systemd.sockets.agent-services.socketConfig.SocketGroup == "agent";
assert c.systemd.sockets.agent-services.socketConfig.SocketMode == "0660";
assert
  c.systemd.services.traefik.serviceConfig.LoadCredential
  == [ "CF_DNS_API_TOKEN:/var/lib/agent-service-secrets/cloudflare-token" ];
assert c.systemd.services.traefik.environment.CF_DNS_API_TOKEN_FILE == "%d/CF_DNS_API_TOKEN";
assert !(builtins.elem 443 c.networking.firewall.allowedTCPPorts);
assert c.networking.firewall.interfaces.tailscale0.allowedTCPPorts == [ 443 ];
assert c.networking.firewall.interfaces.wt0.allowedTCPPorts == [ 443 ];
assert !(c.networking.firewall.interfaces ? eth0);
assert
  (enabled { allowDirectHost = true; }).networking.firewall.interfaces.eth0.allowedTCPPorts
  == [ 443 ];
assert lib.hasInfix ''iifname "eth0" ip saddr 10.83.1.1 return''
  (enabled { allowDirectHost = true; }).networking.nftables.tables.agent-services.content;
assert builtins.all
  (
    path:
    !(valid {
      dnsCredentialFiles = {
        CF_DNS_API_TOKEN = path;
      };
    })
  )
  [
    "/nix/store/token"
    "/home/agent/token"
    "/tmp/token"
    "/var/tmp/token"
    "/var/lib/../token"
    "/var/lib/./token"
    "/var//lib/token"
    "/workspace/project/token"
  ];
assert
  !(valid {
    dnsCredentialFiles = {
      CF_DNS_API_TOKEN_FILE = "/run/keys/token";
    };
  });
assert !(valid { dnsCredentialFiles = { }; });
pkgs.runCommand "agent-services-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${../.}/tests/test-agent-services.py
  touch "$out"
''
