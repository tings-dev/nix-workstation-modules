{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.agentEnvironment;
  shares = builtins.attrValues cfg.shares;
  # Strings deliberately remain host runtime paths, never Nix path literals
  # (which could copy the shared data into the public Nix store).
  canonical =
    path:
    lib.hasPrefix "/" path
    && builtins.all (part: part != "" && part != "." && part != "..") (
      lib.tail (lib.splitString "/" path)
    )
    && builtins.match ".*[[:cntrl:]].*" path == null;
  pathType = (lib.types.addCheck lib.types.str canonical) // {
    description = "canonical absolute path without dot/empty components, trailing slash or control characters";
  };
  within = parent: path: parent == path || lib.hasPrefix "${parent}/" path;
  overlap = a: b: within a b || within b a;
  distinct =
    field:
    lib.imap0 (
      i: a: builtins.all (b: !(overlap a.${field} b.${field})) (lib.drop (i + 1) shares)
    ) shares;
  reservedDestinations = [
    "/bin"
    "/boot"
    "/dev"
    "/etc"
    "/lib"
    "/lib64"
    "/nix"
    "/proc"
    "/run"
    "/sbin"
    "/sys"
    "/usr"
    "/var"
    "/home/agent/.ssh"
  ];
  manifest = pkgs.writeText "agent-shares.json" (builtins.toJSON shares);
  validate = pkgs.writers.writePython3 "agent-share-export" { } (
    builtins.readFile ./agent-share-export.py
  );
  exportRoot = "/run/agent-shares-${config.networking.hostName}";
  backend = pkgs.writeShellScriptBin "virtiofsd" ''
    exec ${validate} ${manifest} ${exportRoot} ${lib.getExe pkgs.virtiofsd} "$@"
  '';
in
{
  options.workstation.agentEnvironment.shares = lib.mkOption {
    default = { };
    description = "Explicit live host directory grants; no folders are shared by default.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = pathType;
            description = "Existing absolute host directory without symlink components; nested mounts are excluded.";
          };
          destination = lib.mkOption {
            type = pathType;
            description = "Absolute guest mount point, outside system and baseline SSH paths.";
          };
          access = lib.mkOption {
            type = lib.types.enum [
              "read-only"
              "read-write"
            ];
            description = "Access enforced by the host virtiofsd export.";
          };
          hostUid = lib.mkOption {
            type = lib.types.ints.between 1 4294967294;
            description = "Host owner UID; all guest identities write as this unprivileged UID.";
          };
          hostGid = lib.mkOption {
            type = lib.types.ints.between 1 4294967294;
            description = "Host owner GID; all guest identities write as this GID.";
          };
        };
      }
    );
  };
  config = {
    assertions = [
      {
        assertion = builtins.all (name: builtins.match "[a-z][a-z0-9-]{0,23}" name != null) (
          builtins.attrNames cfg.shares
        );
        message = "Agent share names must be 1–24 lowercase letters, digits or hyphens, starting with a letter.";
      }
      {
        assertion = builtins.all (valid: valid) (distinct "source" ++ distinct "destination");
        message = "Agent shares must not have duplicate or nested sources or destinations; overlapping exports can bypass read-only grants.";
      }
      {
        assertion = builtins.all (
          share:
          !(builtins.any (path: overlap path share.destination) reservedDestinations)
          && !(builtins.elem share.destination [
            "/home"
            "/home/agent"
          ])
          && !(builtins.any (path: overlap path share.source) [
            "/dev"
            "/proc"
            "/sys"
            "/run"
            "/nix"
            "/var/lib/microvms"
          ])
        ) shares;
        message = "Agent shares must not expose host runtime/control/private VM state or shadow guest system and SSH paths.";
      }
    ];
    microvm = {
      shares = lib.mapAttrsToList (name: share: {
        proto = "virtiofs";
        tag = "share-${name}";
        socket = "share-${name}.sock";
        source = share.source;
        mountPoint = share.destination;
        readOnly = share.access == "read-only";
        # Live host edits must be observable without a guest remount.
        cache = "never";
        posixAcl = false;
        extraArgs = [
          "--sandbox=namespace"
          "--inode-file-handles=never"
          "--translate-uid=squash-guest:0:${toString share.hostUid}:4294967295"
          "--translate-gid=squash-guest:0:${toString share.hostGid}:4294967295"
          "--translate-uid=host:${toString share.hostUid}:1000:1"
          "--translate-gid=host:${toString share.hostGid}:1000:1"
          "--modcaps=-mknod:-setfcap"
        ];
      }) cfg.shares;
      # Pin each export through an opened directory before the backend starts.
      # A concurrent rename/symlink swap must not redirect a declared grant.
      virtiofsd.package = lib.mkIf (shares != [ ]) backend;
    };
  };
}
