# Shared NetBird client. Importing this module makes the daemon and CLI available;
# enrollment remains runtime state, separate from Tailscale enrollment.
{ config, lib, ... }:

let
  cfg = config.services.netbird.clients.netbird or null;
in
{
  services.netbird = {
    ui.enable = lib.mkDefault false;
    # Routing resources and exit-node roles need an explicit host choice.
    useRoutingFeatures = lib.mkDefault "none";
    # A named client creates the service; services.netbird.enable is the legacy
    # shorthand and would create an additional client with different defaults.
    clients.netbird = {
      port = lib.mkDefault 51820;
      interface = lib.mkDefault "wt0";
      hardened = lib.mkDefault true;
      login = {
        enable = lib.mkDefault (cfg.login.setupKeyFile != null);
        setupKeyFile = lib.mkDefault null;
      };
    };
  };

  assertions = [
    {
      assertion = cfg == null || !(cfg.environment ? NB_MANAGEMENT_URL) || builtins.match "https?://[^/?#@[:space:]]+/?" cfg.environment.NB_MANAGEMENT_URL != null;
      message = "NetBird needs an HTTP(S) management URL with no credentials, path or query.";
    }
    {
      assertion = cfg == null || cfg.login.setupKeyFile == null || (
        lib.hasPrefix "/" cfg.login.setupKeyFile
        && !lib.hasPrefix builtins.storeDir cfg.login.setupKeyFile
      );
      message = "NetBird setupKeyFile must be an absolute runtime path outside the Nix store.";
    }
    {
      assertion = cfg == null || !cfg.login.enable || cfg.login.setupKeyFile != null;
      message = "NetBird automated login requires a runtime setupKeyFile.";
    }
  ];
}
