# Kitty terminal settings for graphical sessions.  Stylix owns its palette
# (and the terminal font), so this file contains behavior only.
{
  config,
  ...
}:

{
  programs.kitty = {
    enable = true;

    settings = {
      enable_audio_bell = false;
      shell = "fish";
    };

    keybindings = {
      # Preserve the old undo binding and browser-like font zoom shortcuts.
      "ctrl+shift+minus" = "send_text all \\x1a";
      "ctrl+minus" = "decrease_font_size";
      "ctrl+equal" = "increase_font_size";
    };
  };

  # Explicit because this profile is where the terminal joins the central
  # Stylix theme.  Do not add a Kitty theme file or hard-coded colors here.
  stylix.targets.kitty.enable = true;

  # This is the configuration for Kitty's `choose-files` kitten.  It was not
  # part of the color theme and remains an independent, user-facing behavior.
  xdg.configFile."kitty/choose-files.conf".text = ''
    map ctrl+t cd /tmp
    map ctrl+p cd ~/projects
    ignore **/${config.home.username}/Archive/**
  '';
}
