# Android USB tools; systemd supplies the device uaccess rules.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.android-tools ];
}
