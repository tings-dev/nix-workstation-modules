# The checkout setting and activation command travel together with each home.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./repository.nix ];
  options.workstation.management.switchCommand = lib.mkOption {
    type = lib.types.nonEmptyListOf lib.types.str;
    description = "Activation argv: supplied by NixOS, or explicitly by a standalone home entrypoint.";
  };
  config.home.packages = [
    (import ../pkgs/njust.nix {
      inherit pkgs;
      repository = config.workstation.repositoryPath;
      inherit (config.workstation) updateCommand;
      switchCommand = config.workstation.management.switchCommand;
    })
  ];
}
