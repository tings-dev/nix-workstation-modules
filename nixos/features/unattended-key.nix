# System support for integrated homes that import home/features/unattended-key.nix.
# Home entrypoints own the selection and backend; this bridge adds no home imports.
{ config, lib, ... }:

let
  homes = lib.filterAttrs (_: home: (home.workstation or { }) ? unattendedKey) (
    config.home-manager.users or { }
  );
  usesTpm = home: home.workstation.unattendedKey.backend == "tpm";
in
{
  # The user instance must survive logout for an armed key to last until reboot.
  users.users = lib.mapAttrs (_: home: {
    linger = true;
    extraGroups = lib.optional (usesTpm home) "tss";
  }) homes;

  # Standalone Home Manager users arrange linger and TPM access on their OS.
  security.tpm2.enable = lib.mkIf (lib.any usesTpm (lib.attrValues homes)) true;
}
