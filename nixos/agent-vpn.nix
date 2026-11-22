# Independent guest VPN clients; login is performed manually by the operator.
{ config, lib, ... }:
let
  cfg = config.workstation.agentEnvironment.vpn;
  enabled = cfg.tailscale.enable || cfg.netbird.enable;
  ipv4Octet = "(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])";
in
{
  options.workstation.agentEnvironment.vpn = {
    tailscale.enable = lib.mkEnableOption "the guest's independent Tailscale client";
    netbird = {
      enable = lib.mkEnableOption "the guest's independent NetBird client";
      managementURL = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "https://[^/?#@[:space:]]+/?");
        default = null;
        description = "Operator-verified NetBird management endpoint; no inherited host default.";
      };
      ipv4Network = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.strMatching "(10[.]${ipv4Octet}|172[.](1[6-9]|2[0-9]|3[01])|192[.]168|100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))[.]0[.]0/16"
        );
        default = null;
        description = "Actual NetBird account /16 within private or CGNAT space. Needed for scoped source filtering.";
      };
    };
  };
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion =
            !cfg.netbird.enable || (cfg.netbird.managementURL != null && cfg.netbird.ipv4Network != null);
          message = "Agent NetBird requires an operator-verified managementURL and actual ipv4Network.";
        }
      ];
    }
    (lib.mkIf enabled {
      services.resolved.enable = true;
      # Both clients use resolved's per-link DNS instead of competing to replace
      # resolv.conf. Provider policies must use distinct suffixes, no catch-all.
      networking.nftables = {
        enable = true;
        flushRuleset = false;
        tables.agent-vpn = {
          family = "inet";
          content = ''
            chain ingress {
              type filter hook prerouting priority raw; policy accept;
              ${lib.optionalString (cfg.netbird.enable && cfg.netbird.ipv4Network != null) ''
                iifname "wt0" ip saddr ${cfg.netbird.ipv4Network} return
                iifname "wt0" drop
                ip saddr ${cfg.netbird.ipv4Network} drop
              ''}
              ${lib.optionalString cfg.tailscale.enable ''
                iifname "tailscale0" return
              ''}
              ip saddr 100.64.0.0/10 drop
              ip6 saddr fd7a:115c:a1e0::/48 drop
            }
          '';
        };
      };
      # Policy routing can be asymmetric. Keep RPF, plus interface/range checks
      # above; never disable source validation globally to make VPNs coexist.
      networking.firewall.checkReversePath = "loose";
    })
    (lib.mkIf cfg.tailscale.enable {
      services.tailscale = {
        enable = true;
        openFirewall = true;
        extraSetFlags = [
          "--accept-routes=false"
          "--ssh=false"
          "--operator="
          "--netfilter-mode=on"
        ];
      };
    })
    (lib.mkIf cfg.netbird.enable {
      services.netbird = {
        ui.enable = false;
        clients.netbird = {
          port = 51820;
          interface = "wt0";
          hardened = true;
          openInternalFirewall = false;
          environment.NB_MANAGEMENT_URL = lib.mkIf (
            cfg.netbird.managementURL != null
          ) cfg.netbird.managementURL;
          config = {
            DisableClientRoutes = true;
            DisableServerRoutes = true;
            DisableIPv6 = true;
            ServerSSHAllowed = false;
            RemoteJobsAllowed = false;
          };
        };
      };
    })
  ];
}
