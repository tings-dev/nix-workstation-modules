# Shared Nix settings, package sources and package licensing policy.
{ lib, ... }:

{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;

    # Retain the source cache policy; development tools consume it in stage 5.
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Allow evaluation of these packages; their features decide installation.
  # Keep one predicate so optional features do not define conflicting functions.
  nixpkgs.config.allowUnfreePredicate = import ../pkgs/allow-unfree.nix { inherit lib; };
}
