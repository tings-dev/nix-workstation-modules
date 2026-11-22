# Install the wrapped IDE and retain its XDG autostart entry.
{ lib, pkgs, ... }:
let
  pycharm = import ../../pkgs/pycharm.nix { inherit lib pkgs; };
in
{
  home.packages = [ pycharm ];
  # Preserve the previous Sway-session behavior at the profile that now owns
  # PyCharm, while using the desktop-independent XDG autostart seam.
  xdg.configFile."autostart/pycharm.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=PyCharm
    Exec=${lib.getExe pycharm}
    Terminal=false
  '';
}
