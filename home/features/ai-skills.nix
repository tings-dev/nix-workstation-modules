# Global agent skills.
#
# One catalogue, linked into each selected agent's skills directory. The catalogue lives
# in home/skills; this file only decides where its entries land. A skill is a
# folder of Markdown, so nothing is built: each entry is a symlink to a store
# path the flake inputs already provide.
#
# Usable with standalone Home Manager as well as NixOS.
{ inputs, ... }:
{
  config,
  lib,
  ...
}:

let
  cfg = config.workstation.aiSkills;
in
{
  options.workstation.aiSkills = {
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = import ../skills { inherit inputs lib; };
      defaultText = lib.literalExpression "import ../skills { inherit inputs lib; }";
      description = ''
        Skills to install, keyed by the directory name every agent sees. Each
        value is a directory holding a SKILL.md.
      '';
      example = lib.literalExpression ''
        { tdd = "''${inputs.skills-mattpocock}/skills/engineering/tdd"; }
      '';
    };

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ".agents/skills"
        ".claude/skills"
        ".codex/skills"
        ".pi/agent/skills"
      ];
      description = ''
        Home-relative directories that each receive one symlink per skill.
        Every skill is linked on its own rather than the parent directory as a
        whole, so a skill an agent installs for itself keeps working alongside
        the managed ones.
      '';
    };
  };

  config = {
    # An upstream repo can move a skill without warning, and a `flake = false`
    # input has no build step that would notice. Without this check the skill
    # would simply stop existing, silently, on the next `nix flake update`.
    assertions = lib.mapAttrsToList (name: source: {
      assertion = builtins.pathExists "${source}/SKILL.md";
      message = "workstation.aiSkills.skills.${name} has no SKILL.md at ${source}";
    }) cfg.skills;

    home.file = lib.listToAttrs (
      lib.concatMap (
        target:
        lib.mapAttrsToList (
          name: source: lib.nameValuePair "${target}/${name}" { inherit source; }
        ) cfg.skills
      ) cfg.targets
    );
  };
}
