# A global task runner with the activation command supplied by the host's layer.
{
  pkgs,
  switchCommand,
  repository,
  updateCommand ? [ "nix" "flake" "update" ],
}:

let
  justfile = pkgs.writeText "njust.just" (
    builtins.replaceStrings
      [ "@switchCommand@" "@updateCommand@" ]
      (map pkgs.lib.escapeShellArgs [ switchCommand updateCommand ])
      (builtins.readFile ../scripts/njust.just)
  );
in
pkgs.writeShellApplication {
  name = "njust";
  runtimeInputs = with pkgs; [
    git
    just
    nix
  ];
  derivationArgs = {
    nativeBuildInputs = [
      pkgs.installShellFiles
      pkgs.just
    ];
    postCheck = ''
      # Generate the full dynamic scripts, with independent njust registrations
      # and callbacks, rather than the small `just --completions` loaders.
      for shell in bash fish; do
        JUST_COMPLETE="$shell" just > "njust.$shell"
        substituteInPlace "njust.$shell" --replace-fail just njust
        installShellCompletion --cmd njust "--$shell" "njust.$shell"
      done
    '';
  };
  text = ''
    repository=${pkgs.lib.escapeShellArg repository}
    if [[ ! -f "$repository/flake.nix" ]]; then
      printf 'Missing configuration checkout: %s\n' "$repository" >&2
      exit 1
    fi
    # Completion parses the command line after `--`. Insert the same context
    # there, adjusting Bash's cursor index for the five inserted words.
    if [[ -n "''${JUST_COMPLETE:-}" && "''${1:-}" == -- ]]; then
      shift
      completion_command="$1"
      shift
      if [[ -n "''${_CLAP_COMPLETE_INDEX:-}" ]]; then
        export _CLAP_COMPLETE_INDEX=$((_CLAP_COMPLETE_INDEX + 5))
      fi
      exec just -- "$completion_command" --justfile ${justfile} \
        --working-directory "$repository" --no-dotenv "$@"
    fi
    exec just --justfile ${justfile} --working-directory "$repository" \
      --no-dotenv --default-list "$@"
  '';
}
