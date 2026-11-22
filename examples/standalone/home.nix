{ workstation, ... }:
{
  imports = with workstation.homeModules; [
    git
    bash
  ];
  home = {
    username = "demo";
    homeDirectory = "/home/demo";
    stateVersion = "26.05";
  };
  targets.genericLinux.enable = true;
  programs.git.settings.user = {
    name = "Demo User";
    email = "demo@example.org";
  };
}
