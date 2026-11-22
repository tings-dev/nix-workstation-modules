# Home Manager owns non-secret settings and the shell integration. AI's token
# is resolved at invocation time; account credentials remain Atuin runtime state.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  secret = config.workstation.atuin.aiSecret;
  wrapper = pkgs.writeShellApplication {
    name = "atuin";
    runtimeInputs = [
      pkgs.age
      pkgs.sops
      pkgs.secretspec
    ];
    text = ''
      if [[ "''${1:-}" == ai ]]; then
        ATUIN_AI__API_TOKEN=$(secretspec get ATUIN_AI__API_TOKEN \
          --file ${lib.escapeShellArg secret.manifest} \
          --profile atuin-ai \
          --provider ${lib.escapeShellArg secret.provider} \
          --reason ${lib.escapeShellArg secret.reason})
        export ATUIN_AI__API_TOKEN
      fi

      exec ${lib.getExe pkgs.atuin} "$@"
    '';
  };
  atuinWithSecret = pkgs.symlinkJoin {
    name = "atuin-with-ai-secret-${pkgs.atuin.version}";
    paths = [ pkgs.atuin ];
    postBuild = ''
      ln -sf ${wrapper}/bin/atuin "$out/bin/atuin"
    '';
    inherit (pkgs.atuin) meta version;
  };
in
{
  options.workstation.atuin.aiSecret = lib.mkOption {
    default = null;
    description = "Optional SecretSpec lookup for the Atuin AI token.";
    type = lib.types.nullOr (lib.types.submodule {
      options = {
        manifest = lib.mkOption { type = lib.types.str; };
        provider = lib.mkOption { type = lib.types.str; };
        reason = lib.mkOption { type = lib.types.str; };
      };
    });
  };

  config.programs.atuin = {
    enable = true;
    package = lib.mkIf (secret != null) atuinWithSecret;
    enableFishIntegration = lib.mkDefault true;
    forceOverwriteSettings = lib.mkDefault true;
  };
}
