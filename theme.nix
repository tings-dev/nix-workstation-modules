# The single declarative Stylix theme shared by NixOS and standalone Home
# Manager configurations. The importing layer supplies the appropriate Stylix
# module and passes its package set here.
{ pkgs }:

{
  enable = true;
  polarity = "light";

  base16Scheme = {
    scheme = "Nord Light";
    author = "arcticicestudio (adapted)";
    base00 = "eceff4"; # background (Snow Storm 3)
    base01 = "e5e9f0"; # lighter background (Snow Storm 2)
    base02 = "d8dee9"; # selection (Snow Storm 1)
    base03 = "aebacf"; # comments / muted
    base04 = "60728a"; # dark foreground
    base05 = "434c5e"; # default text (Polar Night 2)
    base06 = "3b4252"; # light foreground (Polar Night 1)
    base07 = "2e3440"; # darkest (Polar Night 0)
    base08 = "bf616a"; # red (urgent)
    base09 = "d08770"; # orange
    base0A = "ebcb8b"; # yellow
    base0B = "a3be8c"; # green
    base0C = "8fbcbb"; # cyan
    base0D = "81a1c1"; # blue (focused border)
    base0E = "b48ead"; # purple
    base0F = "5e81ac"; # deep blue
  };

  # Every Stylix font option is spelled out, including the ones that only
  # restate the current upstream default. A default that changes upstream then
  # cannot quietly change how these hosts look. `fonts.packages` is the one
  # exception: Stylix computes it from the four families and it is read-only.
  fonts = {
    monospace = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMono Nerd Font";
    };
    sansSerif = {
      package = pkgs.inter;
      name = "Inter";
    };
    # Stylix's default, pinned. No target here selects a serif face; it reaches
    # only applications that ask for the serif category themselves.
    serif = {
      package = pkgs.dejavu_fonts;
      name = "DejaVu Serif";
    };
    # Stylix's default, pinned. Fontconfig offers this as the emoji fallback.
    emoji = {
      package = pkgs.noto-fonts-color-emoji;
      name = "Noto Color Emoji";
    };

    # Point sizes. Targets that measure in pixels, such as Zed, scale these by
    # 4/3. Upstream derives `terminal` from `applications` and `popups` from
    # `desktop`; both are given directly here, so that link no longer holds.
    sizes = {
      # Shared application size in points; GTK and Qt follow this value.
      # Individual application modules can override their own UI size.
      applications = 11;
      # Window-manager chrome. Sway is the only target here that reads it, and
      # `bars = [ ]` plus `titlebar = false` leave just the titles on tabbed
      # and stacked containers. Matches Stylix's default.
      desktop = 11;
      # Notifications, launchers and other overlays. DMS owns those surfaces
      # and sizes them itself, so nothing reads this today. Matches Stylix's
      # default of following `desktop`.
      popups = 11;
      # Preserve the compact terminal size from the former Kitty dotfile.
      terminal = 9;
    };
  };
}
