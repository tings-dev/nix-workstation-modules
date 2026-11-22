# Opt-in expiration events in an existing personal-data calendar replica.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.personalData.codexResetCalendar;
  python = pkgs.python3.withPackages (packages: [ packages.icalendar ]);
  refresh = pkgs.writeShellApplication {
    name = "sync-codex-resets-calendar";
    runtimeInputs = [
      python
      pkgs.vdirsyncer
    ];
    text = ''
      export PATH=${lib.escapeShellArg "${config.home.homeDirectory}/.local/scripts"}:"$PATH"
      exec ${python}/bin/python3 ${../scripts/sync-codex-resets-calendar.py} --uid-domain ${lib.escapeShellArg cfg.uidDomain} "$@"
    '';
  };
in
{
  options.workstation.personalData.codexResetCalendar = {
    enable = lib.mkEnableOption "Codex reset-credit expiration events in a personal calendar";
    uidDomain = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9.-]+";
      default = "localhost";
      description = "Stable UID domain for generated calendar events.";
    };
    calendar = lib.mkOption {
      type = lib.types.str;
      description = "Discovered calendar display name or collection ID to receive reset events";
    };
    account = lib.mkOption {
      type = lib.types.str;
      default = "fastmail";
      description = "Enabled personal-data calendar account owning the collection";
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd calendar expression for refreshing reset expiration events";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          builtins.hasAttr cfg.account config.workstation.personalData.accounts
          && config.workstation.personalData.accounts.${cfg.account}.calendar.enable;
        message = "Codex reset calendar requires an enabled personal-data calendar account";
      }
    ];
    home.file.".local/scripts/sync-codex-resets-calendar".source =
      "${refresh}/bin/sync-codex-resets-calendar";

    systemd.user.services.codex-reset-calendar = {
      Unit = {
        Description = "Update Codex reset-credit expiration events";
        Wants = [ "network-online.target" ];
        After = [
          "network-online.target"
          "personal-data-pim.service"
        ];
        ConditionPathExists = "%h/.codex/auth.json";
      };
      Service = {
        Type = "oneshot";
        UMask = "0077";
        TimeoutStartSec = "6m";
        ExecStart = lib.escapeShellArgs [
          "${refresh}/bin/sync-codex-resets-calendar"
          "--calendar"
          cfg.calendar
          "--account"
          cfg.account
          "--calendar-root"
          "${config.xdg.dataHome}/calendars"
        ];
      };
    };
    systemd.user.timers.codex-reset-calendar = {
      Unit.Description = "Refresh Codex reset-credit expiration events";
      Timer = {
        OnCalendar = cfg.onCalendar;
        OnStartupSec = "5m";
        Persistent = true;
        RandomizedDelaySec = "5m";
        Unit = "codex-reset-calendar.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
