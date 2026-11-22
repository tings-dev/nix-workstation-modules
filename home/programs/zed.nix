# Native Zed preferences; the desktop feature supplies the Stylix theme.
{ lib, ... }:
{
  # These reproduce the existing Zed preferences managed by Chezmoi for the
  # Flatpak. Home Manager writes them to the native package's XDG location and
  # merges future edits made by Zed, so the original Chezmoi source is left
  # untouched during the migration to a NixOS host.
  programs.zed-editor = {
    enable = true;

    userSettings = {
      cli_default_open_behavior = "existing_window";
      agent_servers = {
        claude-acp = {
          default_config_options = {
            model = "claude-opus-5";
            effort = "high";
            mode = "plan";
          };
          type = "registry";
        };
        codex-acp = {
          default_config_options = {
            reasoning_effort = "high";
            model = "gpt-5.6-terra";
            mode = "read-only";
          };
          type = "registry";
        };
        pi-acp = {
          default_config_options.model = "openai-codex/gpt-5.6-terra";
          type = "registry";
        };
      };
      project_panel.dock = "left";
      outline_panel.dock = "left";
      collaboration_panel.dock = "left";
      git_panel.dock = "left";
      features.edit_prediction_provider = "zed";
      base_keymap = "Emacs";
      icon_theme = "Zed (Default)";

      # Stylix derives this from stylix.fonts.sizes.applications, in points,
      # scaled by 4/3 for Zed's pixels. This seat wants a
      # denser interface. mkForce is required because Stylix sets the same
      # key at normal priority. The editor text stays on the Stylix value.
      ui_font_size = lib.mkForce 11;

      terminal = {
        detect_venv.on = {
          directories = [
            ".env"
            "env"
            ".venv"
            "venv"
          ];
          activate_script = "default";
        };
      };
      languages.Python = { };
    };

    userKeymaps = [
      {
        context = "Workspace";
        bindings = { };
      }
      {
        context = "Editor";
        bindings = {
          ctrl-shift-g = "editor::GoToDefinition";
          ctrl-shift-c = "editor::ToggleComments";
        };
      }
      {
        context = "Terminal";
        bindings = {
          ctrl-p = [
            "terminal::SendKeystroke"
            "up"
          ];
          ctrl-f = [
            "terminal::SendKeystroke"
            "down"
          ];
        };
      }
    ];
  };

}
