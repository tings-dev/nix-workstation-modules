# The global agent-skill catalogue.
#
# One attribute per skill: the name is the directory every agent sees, the value
# is where that directory comes from. A skill is a folder of Markdown, so there
# is nothing to build — a remote skill is a subdirectory of a `flake = false`
# input that Nix has already fetched, and a local one is a folder in this repo.
#
# Add a remote source by adding a `skills-<name>` input to flake.nix, then a line
# here. Add a local skill by creating `local/<name>/SKILL.md`; it needs no entry.
{ inputs, lib }:

let
  # Every subdirectory of `dir` becomes a skill named after that directory. Use
  # it for a source laid out as one folder per skill. Name a skill explicitly
  # instead when you want only some of them, or a different installed name.
  skillsIn =
    dir:
    lib.mapAttrs (name: _: "${dir}/${name}") (
      lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir)
    );
in

# Later entries win a name collision, so an explicit line always beats a sweep
# above it, and a local skill always beats a remote one of the same name.
lib.mergeAttrsList [
  (skillsIn "${inputs.skills-mattpocock}/skills/engineering")
  (skillsIn "${inputs.skills-mattpocock}/skills/productivity")

  { git-commit = "${inputs.skills-copilot}/skills/git-commit"; }

  (skillsIn ./local)
]
