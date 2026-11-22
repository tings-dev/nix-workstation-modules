# Common shell and application defaults for a selected home.
# Add an application's shared settings under programs/ and import them here.
# Optional feature bundles are selected separately by each host.
modules:
{ pkgs, ... }:

{
  imports = [
    (modules.load ./features/commands.nix)
    ./programs/git.nix
    ./programs/bash.nix
    ./programs/emacs.nix
    ./programs/fish.nix
    ./programs/shell-aliases.nix
    ./programs/ssh.nix
  ];

  home.packages = with pkgs; [
    dust
    secretspec
  ];

  # Identity, homeDirectory and stateVersion belong to the consuming entrypoint.
}
