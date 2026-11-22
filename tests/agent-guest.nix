{ workstation, pkgs }:
modules:
let
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
in
workstation.lib.mkHost {
  imports = [ workstation.nixosModules.agent-environment ] ++ modules;
  workstation.agentEnvironment.authorizedKeys = [ keys.snakeOilEd25519PublicKey ];
}
