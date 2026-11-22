# Keep complete store paths and their database on the same private root disk.
# An overlay whose lower image changes loses old system dependencies on update.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # A complete store, rather than an overlay upper directory.
  privateStore = "/nix/.rw-store/store";
  imageMount = "sysroot-nix-.ro\\x2dstore.mount";
in
{
  microvm.writableStoreOverlay = null;
  fileSystems = {
    "/nix/.ro-store" = {
      device = "/dev/disk/by-label/nix-store";
      fsType = config.microvm.storeDiskType;
      options = [ "ro" ];
      neededForBoot = true;
      noCheck = true;
    };
    "/nix/store" = lib.mkForce {
      device = privateStore;
      fsType = "none";
      options = [ "bind" ];
      neededForBoot = true;
    };
  };
  boot.initrd.systemd = {
    storePaths = [ pkgs.coreutils ];
    services.agent-private-store = {
      description = "Seed the persistent private Nix store from this guest closure";
      requiredBy = [ "sysroot-nix-store.mount" ];
      before = [ "sysroot-nix-store.mount" ];
      requires = [
        "sysroot.mount"
        imageMount
      ];
      after = [
        "sysroot.mount"
        imageMount
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
      };
      script = ''
        set -eu
        export PATH=${pkgs.coreutils}/bin
        destination=/sysroot${privateStore}
        staging=/sysroot/nix/.seed-store
        marker=/sysroot/nix/.rw-store/full-store-v1
        if [ ! -e "$marker" ] && [ -e /sysroot/nix/var/nix/db/db.sqlite ]; then
          echo 'Legacy overlay database found. Preserve the old complete store through operator-reviewed offline migration before using this runner.' >&2
          exit 1
        fi
        mkdir -p "$destination"
        # An interrupted copy never becomes a visible store path. Only this
        # service uses staging, and it runs before the store or daemon exists.
        rm -rf "$staging"
        mkdir -p "$staging"
        for source in /sysroot/nix/.ro-store/*; do
          name=''${source##*/}
          # Store outputs can themselves be symlinks. Their absolute targets
          # need not resolve in the initrd before the private store is mounted.
          if [ ! -e "$destination/$name" ] && [ ! -L "$destination/$name" ]; then
            cp -a "$source" "$staging/$name"
            mv -T "$staging/$name" "$destination/$name"
          fi
        done
        rmdir "$staging"
        touch "$marker"
      '';
    };
  };
  # microvm normally enables these only when using its overlay option.
  systemd.services.nix-daemon.enable = true;
  systemd.sockets.nix-daemon.enable = true;
  # Upstream registerClosure merges this boot's registration into the persistent
  # /nix/var/nix database. Never replace the database or remove previous roots.
  microvm.registerClosure = true;
}
