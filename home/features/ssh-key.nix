{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.sshKey;
in
{
  options.workstation.sshKey.passphrase = lib.mkOption {
    type = lib.types.enum [
      "required"
      "none"
    ];
    default = "required";
    description = ''
      Whether manual setup must use a passphrase when creating
      the local ED25519 key. The passphrase itself is runtime state.
    '';
  };

  config = {
    home.packages = [ pkgs.openssh ];

    # Home Manager publishes policy only. Key material and a possible
    # passphrase are created locally by the user following docs/init-tasks.md.
    xdg.configFile."frkl/ssh-key.conf".text = ''
      passphrase=${cfg.passphrase}
    '';
  };
}
