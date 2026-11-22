# Small commands shared by every Home Manager host.
{ inputs, ... }:
{ pkgs, ... }:

let
  executableHelpers = import ../../pkgs/executable-helpers.nix {
    inherit pkgs;
    nixIndex =
      inputs.nix-index-database.packages.${pkgs.stdenv.hostPlatform.system}.nix-index-with-small-db;
    nixpkgs = inputs.nix-index-database.inputs.nixpkgs;
  };
  queryCodexResets = pkgs.writeShellApplication {
    name = "query-codex-resets";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = builtins.readFile ../scripts/query-codex-resets;
  };
  queryCodexUsage = pkgs.writeShellApplication {
    name = "query-codex-usage";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = builtins.readFile ../scripts/query-codex-usage;
  };
in
{
  home.packages = [ executableHelpers ];

  home.file.".local/scripts/query-codex-resets".source = "${queryCodexResets}/bin/query-codex-resets";
  home.file.".local/scripts/query-codex-usage".source = "${queryCodexUsage}/bin/query-codex-usage";

  # Home Manager loads this in Bash login sessions and Fish shells.
  home.sessionPath = [ "$HOME/.local/scripts" ];

  # Interactive Bash shells started without a login profile need the path too.
  programs.bash.initExtra = ''
    case ":$PATH:" in
      *":$HOME/.local/scripts:"*) ;;
      *) export PATH="$HOME/.local/scripts:$PATH" ;;
    esac
  '';

  # The current Fish session can inherit Home Manager's sourced marker from
  # before this path existed, so ensure new Fish shells add it themselves.
  programs.fish.shellInit = ''
    if not contains -- "$HOME/.local/scripts" $PATH
      set -gx PATH "$HOME/.local/scripts" $PATH
    end
  '';
}
