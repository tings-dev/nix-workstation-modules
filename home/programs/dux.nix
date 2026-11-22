# Dux Shell: bar, launcher, notifications, lock screen and idle policy.
# Upstream retains the dank-material-shell module name and dms CLI.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.dsearch.homeModules.default
  ];

  # Hosts address their backlight differently, so the device the brightness
  # keys drive is a per-host fact, set where the host enables its seat. Null
  # omits the argument and lets dms pick its default backlight.
  options.workstation.dux.backlightDevice = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "backlight:amdgpu_bl1";
    description = "Backlight device passed to the dms brightness calls.";
  };

  config = {
    programs.dank-material-shell = {
      enable = true;
      systemd.enable = true;

      # Upstream's module deliberately builds its flake package by default.
      # nixpkgs carries the same release and Hydra publishes that output, so
      # use the package from this host's pin instead of rebuilding DMS here.
      package = pkgs.dux-shell;

      settings = {
        # Stylix owns the system light/dark preference.
        syncModeWithPortal = false;

        # Workspace options belong to the widget entry in Dux 2.x.
        barConfigs = [
          {
            id = "default";
            name = "Main Bar";
            enabled = true;
            position = 0;
            screenPreferences = [ "all" ];
            showOnLastDisplay = true;
            leftWidgets = [
              "launcherButton"
              {
                id = "workspaceSwitcher";
                enabled = true;
                showWorkspaceIndex = true;
              }
              "focusedWindow"
            ];
            centerWidgets = [
              "music"
              "clock"
              "weather"
            ];
            rightWidgets = [
              "systemTray"
              "clipboard"
              "cpuUsage"
              "memUsage"
              "notificationButton"
              "battery"
              "controlCenterButton"
            ];
          }
        ];
        batteryNotifyLow = true;
        loginctlLockIntegration = true;
        lockBeforeSuspend = true;

        # Not really about powering monitors off on lock — it is on for the
        # side effect, which is the only wake path that survives a locked
        # session. IdleService.qml arms `lockWakeMonitor` (timeout 1,
        # respectInhibitors false) only when this is true, and that monitor is
        # what turns the panel back on when a key is pressed against a locked,
        # already-dark screen.
        #
        # Without it the ordinary idle monitor is the only thing that can undo
        # `monitorsOff`, and its handler returns early whenever
        # `_applyMonitorEnableds` has disabled it — which a screensaver inhibit
        # from any application does. The panel then stays dark through every
        # keypress and only an out-of-band `swaymsg output <name> power on`
        # recovers it.
        lockScreenPowerOffMonitorsOnLock = true;

        # Idle policy, in seconds, 0 meaning never. DMS runs three independent
        # idle timers per power source — blank the monitors, lock, suspend —
        # and picks the AC or battery set from whether a battery is present and
        # discharging. On battery everything comes sooner and suspend is armed
        # at all; on AC the seat blanks and locks but stays up.
        #
        # There is no brightness-dimming step in DMS. What the monitor timeout
        # does is fade to black over fadeToDpmsGracePeriod (5s) and then DPMS
        # off.
        acMonitorTimeout = 600;
        acLockTimeout = 1200;
        acSuspendTimeout = 0;
        batteryMonitorTimeout = 300;
        batteryLockTimeout = 600;
        # Every value here has to be one the settings UI also offers. Its
        # dropdown maps an unknown number to index 0 and displays it as
        # "Never", which is a lie about a timer that is in fact running. 1800
        # is on that list; the 1500 originally wanted is not.
        batterySuspendTimeout = 1800;
      };
    };

    # Dux can miss Home Manager replacing the settings symlink. Include the
    # settings in the unit so activation restarts the panel when they change.
    systemd.user.services.dms.Unit.X-Restart-Triggers = [
      "${config.xdg.configFile."dms/settings.json".source}"
    ];

    # Disabled because it continuously used ~115% of one core while its index
    # stayed at 139 documents, even after a clean restart.
    #
    # The configuration below is kept rather than deleted, so re-enabling after
    # an upstream fix is one word. It stays worth having if it ever works: the
    # index is deliberately in the cache directory, not Home Manager's
    # immutable state, and its HTTP API is loopback-only because it indexes
    # this user's home directory, so a LAN or tailnet listener would disclose
    # file names and extracted text to anyone who could reach the port.
    programs.dsearch = {
      enable = false;
      config = {
        index_path = "${config.xdg.cacheHome}/danksearch/index";
        listen_addr = "127.0.0.1:43654";
        max_file_bytes = 2097152;
        worker_count = 12;
        text_extensions = [
          ".txt"
          ".md"
          ".go"
          ".py"
          ".js"
          ".ts"
          ".jsx"
          ".tsx"
          ".json"
          ".yaml"
          ".yml"
          ".toml"
          ".html"
          ".css"
          ".rs"
          ".c"
          ".cpp"
          ".h"
          ".java"
          ".rb"
          ".php"
          ".sh"
        ];
        index_all_files = true;
        max_depth = 0;
        index_paths = [
          {
            path = config.home.homeDirectory;
            max_depth = 6;
            exclude_hidden = true;
            exclude_dirs = [
              "node_modules"
              "bower_components"
              ".npm"
              ".yarn"
              "site-packages"
              "__pycache__"
              ".venv"
              "venv"
              ".tox"
              ".pytest_cache"
              ".eggs"
              "dist"
              "build"
              "out"
              "bin"
              "obj"
              "target"
              "vendor"
              ".gradle"
              ".m2"
              "bundle"
              ".cache"
              ".parcel-cache"
              ".next"
              ".nuxt"
              ".serverless"
              "Library"
              ".Trash-1000"
              ".postgresql"
              ".postgres"
              ".mysql"
              ".mongodb"
              ".redis"
              "pgdata"
              "pg_data"
              "go"
              ".cargo"
              ".pyenv"
              ".rbenv"
              ".nvm"
              ".rustup"
              ".composer"
              ".gem"
              ".idea"
              ".vscode"
            ];
            extract_exif = true;
          }
        ];
      };
    };

  };
}
