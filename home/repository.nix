# One runtime checkout location for home tools; a string, not a Nix store path.
{ config, lib, ... }:

{
  options.workstation.repositoryPath = lib.mkOption {
    type = lib.types.strMatching "/.+";
    description = "Absolute path to the live workstation configuration checkout.";
  };

  options.workstation.updateCommand = lib.mkOption {
    type = lib.types.nonEmptyListOf lib.types.str;
    default = [ "nix" "flake" "update" ];
    description = "Arguments of the lockfile update command, run from the configuration checkout or a prepared snapshot.";
  };

  config.assertions = [
    {
      assertion = !lib.hasPrefix builtins.storeDir config.workstation.repositoryPath;
      message = "workstation.repositoryPath must point to a live checkout outside the Nix store.";
    }
  ];
}
