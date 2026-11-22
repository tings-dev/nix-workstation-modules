# Screenshot capture, editing and output location.
{ config, pkgs, ... }:

let
  screenshotDir = "${config.home.homeDirectory}/Pictures/Screenshots";
  screenshot = pkgs.writeShellApplication {
    name = "frkl-screenshot";
    runtimeInputs = with pkgs; [
      coreutils
      grim
      slurp
      satty
      wl-clipboard
      libnotify
      jq
    ];
    text = ''
      image=$(mktemp --suffix=.png)
      trap 'rm -f "$image"' EXIT

      case "''${1:-region}" in
        region)
          # Escape cancels without capturing or opening the editor.
          geometry=$(slurp) || exit 0
          [[ -n "$geometry" ]] || exit 0
          grim -g "$geometry" "$image"
          ;;
        screen)
          grim "$image"
          ;;
        window)
          # swaymsg is provided by the Sway seat. Capture its focused window
          # before opening Satty, including floating and XWayland windows.
          if ! geometry=$(swaymsg -t get_tree | jq -er '
            first(.. | objects
              | select(.focused? == true and (.app_id? != null or .window? != null))
              | .rect
              | select(.width > 0 and .height > 0)
              | "\(.x),\(.y) \(.width)x\(.height)")
          '); then
            notify-send "Screenshot" "Could not find a focused Sway window."
            exit 1
          fi
          grim -g "$geometry" "$image"
          ;;
        clipboard)
          if ! wl-paste --no-newline --type image/png > "$image"; then
            notify-send "Screenshot" "The clipboard does not contain a PNG image."
            exit 1
          fi
          ;;
        *)
          echo "usage: frkl-screenshot [region|screen|window|clipboard]" >&2
          exit 2
          ;;
      esac

      mkdir -p ${pkgs.lib.escapeShellArg screenshotDir}
      # Keep the temporary image until Satty closes, including on cancellation.
      satty --filename "$image"
    '';
  };

in
{
  home.packages = with pkgs; [ grim slurp wl-clipboard screenshot ];

  programs.satty = {
    enable = true;
    settings.general = {
      fullscreen = true;
      copy-command = "${pkgs.wl-clipboard}/bin/wl-copy";
      output-filename = "${screenshotDir}/Screenshot-%Y-%m-%d_%H-%M-%S-%f.png";
      save-after-copy = true;
      early-exit = [
        "copy"
        "save"
        "save-as"
      ];
    };
  };
}
