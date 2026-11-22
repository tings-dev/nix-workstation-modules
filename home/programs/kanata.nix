# Kanata user service; home/features/seat.nix selects it with the XKB keymap.
# nixos/features/seat.nix grants device access for integrated users.
{ lib, pkgs, ... }:

{
  xdg.configFile = {
    "kanata/config.kbd".source = ../configs/kanata/config.kbd;
    "kanata/README.md".source = ../configs/kanata/README.md;
  };

  # Keep Kanata in the user manager, as it needs the logged-in seat's access
  # to input devices. The host system continues to own the uinput/udev policy.
  systemd.user.services.kanata = {
    Unit = {
      Description = "Kanata keyboard remapper";
      Documentation = "https://github.com/jtroo/kanata";
    };

    Service = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.kanata} --cfg %h/.config/kanata/config.kbd --no-wait";
      Restart = "no";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
