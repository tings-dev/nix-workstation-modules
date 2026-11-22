# Fish-only configuration. The aliases moved to ./shell-aliases.nix when bash
# started sharing them; what stays here is the part that has no bash equivalent
# — fish's own settings, key bindings and shell hook.
{ ... }:

{
  programs.fish = {
    enable = true;

    functions = {
      has_command = {
        body = ''
          command -v $argv[1] >/dev/null 2>&1
        '';
      };

    };

    interactiveShellInit = ''
      set fish_greeting

      bind alt-backspace backward-kill-path-component

      if has_command direnv
        direnv hook fish | source
      end

      # Declarative stand-in for `wt config shell install`, which would want to
      # write into fish's config itself.
      if has_command wt
        wt config shell init fish | source
      end
    '';
  };

  # Keep values which apply beyond Fish declarative. SSH_AUTH_SOCK is omitted:
  # it is a runtime agent socket and must never be hard-coded into a profile.
  home.sessionVariables = {
    PIP_REQUIRE_VIRTUALENV = "true";
  };
}
