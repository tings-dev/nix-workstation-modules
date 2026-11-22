# Graphical applications shared by desktop sessions; no compositor selection.
modules:
{ pkgs, ... }:

{
  imports = [
    (modules.load ../theme.nix)
    ../mime-apps.nix
    ../programs/kitty.nix
    ../programs/ghostty.nix
    ../programs/satty.nix
  ];

  # Correct XDG base directories are the one thing every graphical app assumes
  # and few set up properly on their own.
  xdg.enable = true;

  # Allow middle-click to paste selected text in GTK apps, including Ghostty.
  dconf.settings."org/gnome/desktop/interface".gtk-enable-primary-paste = true;

  # The shared home layer defaults to emacs-nox. A graphical seat gets the
  # native GTK build instead.
  programs.emacs.package = pkgs.emacs-pgtk;

  home.packages = with pkgs; [
    # Two image viewers, because they answer different questions. Loupe is the
    # one another application hands a file to: GTK4, so Stylix themes it and
    # the portal file chooser already matches, and it zooms and pans with a
    # touchpad without being taught how. Swayimg is the one you reach for from
    # a shell — Wayland-native, keyboard-driven, opens a directory as a
    # gallery, and starts fast enough to use as a preview. It reads
    # ~/.config/swayimg/config if its keys or colors ever need changing;
    # nothing here writes that file.
    loupe
    swayimg

    # PDF, DjVu, comic archives and TIFF documents.
    papers

    # Writer, Calc, Impress, Draw, Base and Math.
    libreoffice

    # Everyday calculations and unit conversions.
    gnome-calculator

    # Graphical file manager; GVFS and dconf support belong to the system
    # feature in nixos/features/desktop.nix.
    nautilus
  ];
}
