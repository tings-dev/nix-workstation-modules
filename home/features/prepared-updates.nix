# Build updates in the user session; only explicit Apply requests root activation.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.preparedUpdates;
  helper = pkgs.writeShellApplication {
    name = "frkl-system-update";
    runtimeInputs = with pkgs; [
      coreutils
      git
      gnutar
      nix
      systemd
      libnotify
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../../scripts/prepared-system-update.py} \
        --repository ${lib.escapeShellArg config.workstation.repositoryPath} \
        --state-dir ${lib.escapeShellArg "${config.xdg.stateHome}/frkl/system-updates/${cfg.hostName}"} \
        --host ${lib.escapeShellArg cfg.hostName} \
        --rebuild-command ${lib.escapeShellArg cfg.rebuildCommand} \
        --max-jobs ${toString cfg.maxJobs} --cores ${toString cfg.cores} "$@"
    '';
  };
in
{
  imports = [ ../repository.nix ];

  options.workstation.preparedUpdates = {
    hostName = lib.mkOption { type = lib.types.str; };
    rebuildCommand = lib.mkOption { type = lib.types.str; };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 10:00:00";
    };
    onlyOnAC = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
    };
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = helper;
    };
  };

  config = {
    home.packages = [ helper ];
    systemd.user.services.frkl-update-prepare = {
      Unit = {
        Description = "Prepare the next NixOS update without activating it";
        ConditionPathIsDirectory = config.workstation.repositoryPath;
      }
      // lib.optionalAttrs cfg.onlyOnAC { ConditionACPower = true; };
      Service = {
        Type = "oneshot";
        ExecStart = "${helper}/bin/frkl-system-update prepare";
        TimeoutStartSec = "12h";
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.user.timers.frkl-update-prepare = {
      Unit.Description = "Prepare NixOS updates daily";
      Timer = {
        OnCalendar = cfg.onCalendar;
        RandomizedDelaySec = "30m";
        Persistent = true;
        Unit = "frkl-update-prepare.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
