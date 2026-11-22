# A persistent runner for trusted repositories on intermittently online hosts.
# Registration and state belong to the upstream NixOS module; jobs use Podman.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.workstation.giteaRunner;
in
{
  options.workstation.giteaRunner = {
    url = lib.mkOption {
      type = lib.types.strMatching "https?://.+";
      example = "https://git.example.org";
      description = "Gitea instance URL, reachable from both the host and job containers.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.strMatching "/.+";
      example = "/run/secrets/gitea-runner-token";
      description = ''
        Absolute runtime path to a root-readable file containing the raw
        registration token. Provision it before starting the service. Use a
        quoted string, never a Nix path literal or a file in the Nix store.
        See docs/init-tasks.md for the boot-time secret boundary.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Runner name displayed in Gitea.";
    };

    labels = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[^:,[:space:]]+:docker://[^,[:space:]]+");
      default = [ "dev-linux:docker://docker.gitea.com/runner-images:ubuntu-24.04" ];
      description = ''
        Job labels mapped to container images. Workflows use the part before
        :docker:// in runs-on. The Docker label scheme also applies to Podman.
        Host execution labels are deliberately excluded from this profile.
        Pin an image digest here when immutable job environments are required.
      '';
    };

    capacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Maximum number of concurrent jobs accepted by this runner.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir cfg.tokenFile;
        message = "gitea-runner.tokenFile must refer to a runtime secret outside the Nix store.";
      }
      {
        assertion = cfg.labels != [ ];
        message = "gitea-runner needs at least one container label.";
      }
    ];

    virtualisation.podman.enable = lib.mkDefault true;

    services.gitea-actions-runner.instances.dev = {
      enable = lib.mkDefault true;
      name = lib.mkDefault cfg.name;
      url = lib.mkDefault cfg.url;
      tokenFile = lib.mkDefault cfg.tokenFile;
      labels = lib.mkDefault cfg.labels;
      settings = {
        runner = {
          capacity = lib.mkDefault cfg.capacity;
          shutdown_timeout = lib.mkDefault "30s";
        };
        # An embedded cache needs an explicitly reachable address and firewall
        # policy. Podman's image cache remains persistent without this server.
        cache.enabled = lib.mkDefault false;
        container = {
          # The runner still connects using DOCKER_HOST, supplied by NixOS.
          # '-' prevents mounting that root-equivalent socket into jobs.
          docker_host = lib.mkDefault "-";
          privileged = lib.mkDefault false;
          valid_volumes = lib.mkDefault [ ];
          # Limit the job containers, not just the lightweight runner daemon.
          options = lib.mkDefault "--cpus=2 --memory=4g";
        };
      };
    };

    systemd.services.gitea-runner-dev = {
      requires = [ "podman.socket" ];
      serviceConfig = {
        # Concurrent first jobs can race Podman's implicit creation of act's
        # shared tool cache. Create it once before the runner accepts work.
        # Use the same system socket as the runner, not a rootless local store.
        ExecStartPre = lib.mkBefore [
          "${pkgs.podman}/bin/podman --remote --url=unix:///run/podman/podman.sock volume create --ignore act-toolcache"
        ];
        # Give the runner's graceful stop a little time to report its result.
        TimeoutStopSec = lib.mkDefault "45s";
      };
    };
  };
}
