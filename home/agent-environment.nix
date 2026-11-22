# Operator-owned baseline; user profiles and unmanaged home files stay mutable.
modules:
{ config, lib, pkgs, ... }:
{
  imports = [ (modules.load ./features/ai-skills.nix) ];
  home = {
    username = "agent";
    homeDirectory = "/home/agent";
    stateVersion = "26.05";
  };
  programs.bash.enable = true;
  programs.git.enable = true;
  home.packages = with pkgs; [
    curl
    jq
    just
  ];
  # Guest-local history only. Do not import the personal Atuin secret wrapper,
  # account endpoints or authentication state from home/common.nix.
  programs.atuin = {
    enable = true;
    settings = {
      auto_sync = false;
      update_check = false;
    };
  };

  # Extend the shared skill defaults only for guests, including lean test VMs.
  workstation.aiSkills.skills = lib.mkOptionDefault {
    agent-vm-packages = ./skills/agent-environment/agent-vm-packages;
    agent-vm-runtime = ./skills/agent-environment/agent-vm-runtime;
  };
  home.file = {
    ".codex/AGENTS.md".source = ./configs/agent-environment/AGENTS.md;
  } // lib.genAttrs [
    ".claude/CLAUDE.md"
    ".omp/agent/AGENTS.md"
    ".pi/agent/AGENTS.md"
  ] (_: {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.codex/AGENTS.md";
  });
}
