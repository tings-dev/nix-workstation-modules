# Sway preferences and bindings. Selected by home/features/seat.nix.
# NixOS owns the compositor package; standalone Home Manager installs it.
{
  config,
  lib,
  ...
}:

let
  backlight = lib.optionalString (
    config.workstation.dux.backlightDevice != null
  ) " \"${config.workstation.dux.backlightDevice}\"";
  commands = {
    launcher = "dms ipc call spotlight toggle";
    clipboard = "dms ipc call clipboard toggle";
    audioRaise = "dms ipc call audio increment 3";
    audioLower = "dms ipc call audio decrement 3";
    audioMute = "dms ipc call audio mute";
    brightnessUp = "dms ipc call brightness increment 5${backlight}";
    brightnessDown = "dms ipc call brightness decrement 5${backlight}";
  };
in
{
  options.workstation.sway.externalOutputs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Preferred external Sway output identifiers for workspaces 7–10, in order. Set these in the host's Home Manager configuration.";
  };

  config = {
    wayland.windowManager.sway = {
      enable = true;

      config = {
        # Dux provides the bar and status UI; suppress the default swaybar.
        bars = [ ];

        modifier = "Mod4";

        # Vim-style home-row direction keys; home-manager threads these through
        # every generated focus/move keybinding.
        left = "h";
        down = "j";
        up = "k";
        right = "l";

        terminal = "xdg-terminal-exec";
        menu = commands.launcher;

        # The complete set of bindings, replacing home-manager's generated
        # defaults wholesale: muscle memory is exactly the kind of fact that
        # should be spelled out rather than inherited (e.g. kill is $mod+q here,
        # not the stock $mod+Shift+q).
        keybindings =
          let
            mod = "Mod4";
            shell = commands;
          in
          {
            # Basics
            "${mod}+Return" = "exec ${config.wayland.windowManager.sway.config.terminal}";
            "${mod}+q" = "kill";
            "${mod}+d" = "exec ${shell.launcher}";
            "${mod}+Shift+c" = "reload";
            "${mod}+Shift+e" =
              "exec swaynag -t warning -m 'You pressed the exit shortcut. Do you really want to exit sway? This will end your Wayland session.' -B 'Yes, exit sway' 'swaymsg exit'";
            "${mod}+Shift+s" = "exec systemctl suspend";

            # Capture and annotate; Shift+Print also edits clipboard captures.
            "Print" = "exec frkl-screenshot region";
            "Control+Print" = "exec frkl-screenshot screen";
            "Mod1+Print" = "exec frkl-screenshot window";
            "Shift+Print" = "exec frkl-screenshot clipboard";

            # Focus, vim keys and arrows
            "${mod}+h" = "focus left";
            "${mod}+j" = "focus down";
            "${mod}+k" = "focus up";
            "${mod}+l" = "focus right";
            "${mod}+Left" = "focus left";
            "${mod}+Down" = "focus down";
            "${mod}+Up" = "focus up";
            "${mod}+Right" = "focus right";

            # Move windows, same keys with Shift
            "${mod}+Shift+h" = "move left";
            "${mod}+Shift+j" = "move down";
            "${mod}+Shift+k" = "move up";
            "${mod}+Shift+l" = "move right";
            "${mod}+Shift+Left" = "move left";
            "${mod}+Shift+Down" = "move down";
            "${mod}+Shift+Up" = "move up";
            "${mod}+Shift+Right" = "move right";

            # Workspaces
            "${mod}+1" = "workspace number 1";
            "${mod}+2" = "workspace number 2";
            "${mod}+3" = "workspace number 3";
            "${mod}+4" = "workspace number 4";
            "${mod}+5" = "workspace number 5";
            "${mod}+6" = "workspace number 6";
            "${mod}+7" = "workspace number 7";
            "${mod}+8" = "workspace number 8";
            "${mod}+9" = "workspace number 9";
            "${mod}+0" = "workspace number 10";
            "${mod}+Shift+1" = "move container to workspace number 1";
            "${mod}+Shift+2" = "move container to workspace number 2";
            "${mod}+Shift+3" = "move container to workspace number 3";
            "${mod}+Shift+4" = "move container to workspace number 4";
            "${mod}+Shift+5" = "move container to workspace number 5";
            "${mod}+Shift+6" = "move container to workspace number 6";
            "${mod}+Shift+7" = "move container to workspace number 7";
            "${mod}+Shift+8" = "move container to workspace number 8";
            "${mod}+Shift+9" = "move container to workspace number 9";
            "${mod}+Shift+0" = "move container to workspace number 10";

            # Workspace navigation
            "Control+Shift+B" = "workspace prev_on_output";
            "Control+Shift+F" = "workspace next_on_output";
            "${mod}+Tab" = "workspace next";
            "${mod}+Shift+Tab" = "workspace prev";

            # Layout
            "${mod}+y" = "splith";
            "${mod}+v" = "splitv";
            "${mod}+s" = "layout stacking";
            "${mod}+w" = "layout tabbed";
            "${mod}+e" = "layout toggle split";
            "${mod}+Shift+t" = "layout toggle tabbed split";
            "${mod}+f" = "fullscreen";
            "${mod}+Shift+space" = "floating toggle";
            "${mod}+space" = "focus mode_toggle";
            "${mod}+a" = "focus parent";

            # Scratchpad
            "${mod}+Shift+minus" = "move scratchpad";
            "${mod}+minus" = "scratchpad show";

            # Resizing: a dedicated mode plus direct fine-grained bindings
            "${mod}+r" = "mode \"resize\"";
            "${mod}+semicolon" = "resize shrink width 5 px or 5 ppt";
            "${mod}+apostrophe" = "resize grow width 5 px or 5 ppt";
            "${mod}+slash" = "resize grow height 5 px or 5 ppt";
            "${mod}+period" = "resize shrink height 5 px or 5 ppt";

            # Audio and brightness use Dux IPC; the mic
            # toggle talks to pipewire-pulse directly.
            "XF86AudioRaiseVolume" = "exec ${shell.audioRaise}";
            "XF86AudioLowerVolume" = "exec ${shell.audioLower}";
            "XF86AudioMute" = "exec ${shell.audioMute}";
            "XF86AudioMicMute" = "exec pactl set-source-mute @DEFAULT_SOURCE@ toggle";
            "XF86MonBrightnessUp" = "exec ${shell.brightnessUp}";
            "XF86MonBrightnessDown" = "exec ${shell.brightnessDown}";

            # Media keys
            "XF86AudioPlay" = "exec playerctl play-pause";
            "XF86AudioNext" = "exec playerctl next";
            "XF86AudioPrev" = "exec playerctl previous";
          }
          // lib.optionalAttrs (shell.clipboard != null) {
            # Clipboard history, the successor to the old copyq toggle.
            "${mod}+Shift+v" = "exec ${shell.clipboard}";
          };

        modes = {
          resize = {
            "h" = "resize shrink width 10px";
            "j" = "resize grow height 10px";
            "k" = "resize shrink height 10px";
            "l" = "resize grow width 10px";
            "Left" = "resize shrink width 10px";
            "Down" = "resize grow height 10px";
            "Up" = "resize shrink height 10px";
            "Right" = "resize grow width 10px";
            "Return" = "mode \"default\"";
            "Escape" = "mode \"default\"";
          };
        };

        input = {
          "type:pointer" = {
            accel_profile = "flat";
            pointer_accel = "0";
            scroll_factor = "1";
          };
          "type:keyboard" = {
            # Use the immutable source so Sway can validate before activation.
            xkb_file = "${config.xdg.configFile."xkb/keymap.xkb".source}";
          };
          "type:touchpad" = {
            dwt = "enabled";
            tap = "enabled";
            tap_button_map = "lrm";
          };
        };

        gaps = {
          inner = 6;
          outer = 0;
          smartBorders = "on";
        };

        # titlebar = false is what `default_border pixel 2` meant: a plain
        # 2px border and no title bar, for tiled and floating windows alike.
        floating = {
          border = 2;
          titlebar = false;
        };

        # Where applications land when they start. Browsers and the IDE get
        # their own workspaces; everything conversational shares 10.
        #
        # The criteria match the nixpkgs builds, whose app_ids differ from the
        # flatpak ones the old config matched (e.g. `firefox`, not
        # `org.mozilla.firefox`). Verify with `swaymsg -t get_tree` if an app
        # stops landing where it should.
        assigns = {
          "1" = [ { app_id = "firefox"; } ];
          "3" = [ { class = "jetbrains-pycharm"; } ];
          "7" = [ { app_id = "chromium-browser"; } ];
          "10" = [
            { app_id = "signal"; }
            { class = "Slack"; }
            { app_id = "thunderbird"; }
          ];
        };

        # Workspaces 1–6 use the internal panel. Workspaces 7–10 prefer
        # configured external outputs and fall back to the panel. Dux manages
        # the output layout (mode, position, and scale).
        workspaceOutputAssign =
          let
            internal = "eDP-1";
            externals = config.workstation.sway.externalOutputs;
            internalWs = map toString (lib.range 1 6);
            externalWs = map toString (lib.range 7 10);
          in
          map (ws: {
            workspace = ws;
            output = [ internal ];
          }) internalWs
          ++ map (ws: {
            workspace = ws;
            output = externals ++ [ internal ];
          }) externalWs;

        # Session applications. The systemd environment import that used to sit
        # here is gone on purpose: the module's `systemd.enable` default already
        # publishes WAYLAND_DISPLAY & co. to the user manager and D-Bus, and
        # provides the sway-session.target these can hook into.
        startup = [
          { command = "firefox"; }
          { command = "chromium"; }
          { command = "signal-desktop"; }
          { command = "slack"; }
          { command = "thunderbird"; }
        ];

        window = {
          border = 2;
          titlebar = false;

          commands = [
            {
              criteria.title = "Firefox — Sharing Indicator";
              command = "floating enable";
            }
            {
              criteria.app_id = "firefox";
              command = "opacity 0.98";
            }
            {
              criteria.app_id = "org.gnome.Nautilus";
              command = "opacity 0.98";
            }
            {
              criteria.app_id = "pavucontrol";
              command = "floating enable, resize set width 800 height 600";
            }
            {
              criteria.app_id = "blueman-manager";
              command = "floating enable";
            }
            {
              criteria.title = "Picture-in-Picture";
              command = "floating enable, sticky enable";
            }
            {
              criteria.app_id = "mpv";
              command = "floating enable";
            }

            # Transient window roles and types float rather than tile.
            {
              criteria.window_role = "pop-up";
              command = "floating enable";
            }
            {
              criteria.window_role = "bubble";
              command = "floating enable";
            }
            {
              criteria.window_role = "task_dialog";
              command = "floating enable";
            }
            {
              criteria.window_role = "Preferences";
              command = "floating enable";
            }
            {
              criteria.window_type = "dialog";
              command = "floating enable";
            }
            {
              criteria.window_type = "menu";
              command = "floating enable";
            }
            {
              criteria.window_role = "About";
              command = "floating enable";
            }
          ];
        };
      };
    };
  };
}
