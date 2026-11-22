{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.securityKey;
in
{
  options.workstation.securityKey = {
    mode = lib.mkOption {
      type = lib.types.enum [
        "non-resident"
        "resident"
      ];
      default = "non-resident";
      description = "OpenSSH FIDO credential enrollment mode";
    };

    verification = lib.mkOption {
      type = lib.types.enum [
        "required"
        "touch-only"
      ];
      default = "required";
      description = "OpenSSH FIDO user-verification policy";
    };
  };

  config = {
    # OpenSSH talks to FIDO2 authenticators directly; no ssh-agent, gpg-agent,
    # scdaemon or pcscd participates. libfido2 contributes fido2-token for
    # inspecting the authenticator and setting its PIN during enrollment.
    home.packages = with pkgs; [
      libfido2
      openssh
    ];

    # Enrollment is interactive runtime state. Home Manager publishes only the
    # non-secret policy that manual setup must follow (docs/init-tasks.md).
    xdg.configFile."frkl/security-key.conf".text = ''
      mode=${cfg.mode}
      verification=${cfg.verification}
    '';
  };
}
