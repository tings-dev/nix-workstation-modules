# Firefox, declaratively: Nix owns configuration (prefs, extensions, search),
# Firefox Sync owns living state (history, tabs, bookmarks), Bitwarden owns
# logins. The prefs below draw those borders — the built-in password manager
# is off and Sync is told not to carry passwords, add-ons or prefs, so the
# three systems never claim the same data.
#
# Extension state (Bitwarden server/session, uBlock filters) lives in the
# stateful profile directory and survives every rebuild. Extensions AMO hosts
# but nixpkgs does not package are installed through the ExtensionSettings
# policy below.
#
# The manual steps for a fresh machine or profile wipe live in
# docs/init-tasks.md; everything else reassembles from this file and
# the sync channels.
#
# Known to stay per-machine by their developers' choice (storage.local):
# Hister and Tree Style Tab settings.
{ inputs, ... }:
{ config, pkgs, ... }:

let
  addons = inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  programs.firefox = {
    enable = true;

    # Extensions AMO hosts but nixpkgs does not package: the policy channel
    # installs them from AMO on first launch and AMO keeps them auto-updated,
    # trading nix pinning for zero-maintenance updates — the same trust a
    # manual install would extend. normal_installed (not force_installed)
    # keeps them removable from about:addons.
    policies.ExtensionSettings =
      let
        amo = slug: "https://addons.mozilla.org/firefox/downloads/latest/${slug}/latest.xpi";
        normal = slug: {
          installation_mode = "normal_installed";
          install_url = amo slug;
        };
      in
      {
        "{f0bda7ce-0cda-42dc-9ea8-126b20fed280}" = normal "hister";
        "addon@karakeep.app" = normal "karakeep";
        "{5b22cb75-8e43-4f2a-bb9b-1da0655ae564}" = normal "archive-page";
        "knockoff@knockoff.shopping" = normal "knockoff-amazon-brand-filter";
        "dont-track-me-google@robwu.nl" = normal "dont-track-me-google1";
      };

    profiles.${config.home.username} = {
      id = 0;
      isDefault = true;

      settings = {
        # Bitwarden owns logins.
        "signon.rememberSignons" = false;
        # Sync carries history, tabs and bookmarks; not passwords (Bitwarden),
        # not add-ons or prefs (Nix), so a home-manager switch never fights
        # the sync server.
        "services.sync.engine.passwords" = false;
        "services.sync.engine.addons" = false;
        "services.sync.engine.prefs" = false;
        # Extension *settings* still sync (for extensions using storage.sync)
        # even though extension *installation* is Nix's job: this decouples
        # the extension-storage engine from the disabled addons engine.
        "services.sync.engine.extension-storage" = true;
        "services.sync.engine.extension-storage.force" = true;

        # Nix installs extensions by placing them in the profile, which
        # Firefox treats as sideloading and disables until manually approved;
        # scope 0 marks no scope for auto-disabling so they arrive enabled.
        "extensions.autoDisableScopes" = 0;
        # ...and grant their declared host permissions by default, as a store
        # install would; without this they run but "can't read and change
        # data" on any site.
        "extensions.originControls.grantByDefault" = true;

        # Quality of life.
        "browser.aboutConfig.showWarning" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "extensions.pocket.enabled" = false;
      };

      # Firefox Sync deliberately never carries search settings (hijacking
      # target), so the default engine is pinned here. force is required:
      # Firefox rewrites its search store on every run, and home-manager
      # must be allowed to overwrite it back.
      search = {
        force = true;
        default = "Kagi";
        engines = {
          "Kagi" = {
            urls = [ { template = "https://kagi.com/search?q={searchTerms}"; } ];
            definedAliases = [ "@k" ];
          };
        };
      };

      extensions.packages = with addons; [
        bitwarden
        ublock-origin
        tree-style-tab
        multi-account-containers
        single-file
        refined-github
        libredirect
        browserpass
        web-archives
        plasma-integration
        kagi-search
      ];
    };
  };

  # Stylix themes only profiles it is told about by name.
  stylix.targets.firefox.profileNames = [ config.home.username ];
}
