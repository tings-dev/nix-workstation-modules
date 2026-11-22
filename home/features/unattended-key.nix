# The home half of the unattended key: the agent, target-specific SSH identity
# routing, and the arm/disarm helpers. ../programs/ssh.nix owns the shared SSH settings;
# local overrides go in ~/.ssh/config.d/, which the managed file reads first.
#
# The agent is deliberately hand-rolled rather than Home Manager's
# services.ssh-agent / services.ssh-tpm-agent: both of those export
# SSH_AUTH_SOCK into every shell, which would offer this key to every host and
# violate the rule in home/programs/fish.nix that SSH_AUTH_SOCK is never set by a
# profile. Only the IdentityAgent lines below ever reach the socket (see docs/implementation/06-identity.md).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.unattendedKey;

  # %t and ''${XDG_RUNTIME_DIR} name the same directory; systemd units use the
  # specifier, ssh_config the environment variable.
  socketName = "unattended-key.sock";
  socketPath = "\${XDG_RUNTIME_DIR}/${socketName}";

  # Paths relative to $HOME, shared between the ssh config, the helpers and
  # the policy file used by manual setup.
  softwareKey = ".ssh/id_ed25519_unattended";
  # UNPROVEN until a host first uses backend = "tpm": ssh-tpm-keygen's default
  # output names, the agent's key discovery and the askpass path have passed
  # evaluation only. Prove them at first use and update this comment.
  tpmKey = ".ssh/id_ecdsa";

  keyFile = if cfg.backend == "software" then softwareKey else tpmKey;
  identityFile = if cfg.backend == "software" then "~/${softwareKey}" else "~/${tpmKey}.pub";

  # ssh-tpm-agent prompts agent-side and has no terminal, so a PIN'd TPM key
  # needs a graphical askpass. Zenity keeps it to one plain dialog.
  tpmAskpass = pkgs.writeShellScript "unattended-key-askpass" ''
    exec ${pkgs.zenity}/bin/zenity --password --title="$*"
  '';

  arm = pkgs.writeShellApplication {
    name = "frkl-arm";
    runtimeInputs = [ pkgs.openssh ];
    text =
      if cfg.backend == "software" then
        ''
          SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR}/${socketName}" \
            ssh-add "$HOME/${softwareKey}"
        ''
      else
        ''
          echo "tpm backend: the agent prompts for its PIN on first use; there is no separate arm step." >&2
          exit 1
        '';
  };

  # Restarting the agent drops every cached credential on either backend —
  # the software key from agent memory, the TPM PIN from the session keyring.
  disarm = pkgs.writeShellApplication {
    name = "frkl-disarm";
    text = ''
      systemctl --user restart unattended-key-agent.service
      echo "unattended key disarmed"
    '';
  };

  # On the tpm backend ssh-add -l lists the sealed keys whether or not the PIN
  # is cached, so "armed" there means only that the agent is serving.
  status = pkgs.writeShellApplication {
    name = "frkl-key-status";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      sock="''${XDG_RUNTIME_DIR}/${socketName}"
      if [ ! -S "$sock" ]; then
        echo "unattended-key agent is not running (no socket at $sock)" >&2
        exit 2
      fi
      if SSH_AUTH_SOCK="$sock" ssh-add -l; then
        echo "armed"
      else
        echo "disarmed — arm with frkl-arm, or let the first interactive use prompt"
        exit 1
      fi
    '';
  };
in
{
  imports = [ ../programs/ssh.nix ];

  options.workstation.unattendedKey.targets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Explicit SSH host patterns routed to the unattended identity.";
  };

  options.workstation.unattendedKey.backend = lib.mkOption {
    type = lib.types.enum [
      "software"
      "tpm"
    ];
    default = "software";
    description = "What holds the unattended private key";
  };

  config = {
    home.packages = [
      pkgs.openssh
      arm
      disarm
      status
    ]
    ++ lib.optional (cfg.backend == "tpm") pkgs.ssh-tpm-agent;

    systemd.user.services.unattended-key-agent = {
      Unit.Description = "Agent holding the armed unattended SSH key";
      Service =
        if cfg.backend == "software" then
          {
            # -D keeps it in the foreground for systemd; -a pins the socket the
            # IdentityAgent lines point at. The rm clears a stale socket after
            # an unclean stop, which ssh-agent refuses to bind over.
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/${socketName}";
            ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a %t/${socketName}";
          }
        else
          {
            ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/${socketName}";
            ExecStart = "${pkgs.ssh-tpm-agent}/bin/ssh-tpm-agent -l %t/${socketName}";
            Environment = [ "SSH_ASKPASS=${tpmAskpass}" ];
          };
      # default.target rather than graphical-session.target: with linger on,
      # the agent is up from boot and survives logout — the session the key is
      # armed for is the user instance, not the seat.
      Install.WantedBy = [ "default.target" ];
    };

    # Home Manager publishes only the non-secret policy; the key and its
    # passphrase or PIN are created at runtime following docs/init-tasks.md.
    xdg.configFile."frkl/unattended-key.conf".text = ''
      backend=${cfg.backend}
      key=${keyFile}
    '';

    # These explicit targets use the unattended identity; other connections
    # retain their default identity. Do not add this agent to a wildcard block.
    programs.ssh.settings = lib.genAttrs cfg.targets (
      _:
      {
        IdentitiesOnly = true;
        IdentityFile = identityFile;
        IdentityAgent = socketPath;
      }
      // lib.optionalAttrs (cfg.backend == "software") {
        AddKeysToAgent = "yes";
      }
    );

  };
}
