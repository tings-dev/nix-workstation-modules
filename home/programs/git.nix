# Shared Git behavior. The home supplies its author identity.
{ lib, ... }:
{
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = lib.mkDefault "main";
      pull.rebase = lib.mkDefault true;
    };
  };
}
