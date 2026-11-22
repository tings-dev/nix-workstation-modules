# Home development tools; usable with standalone or NixOS Home Manager.
modules@{ inputs, ... }:
{ pkgs, ... }:

let
  agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  packagePkgs = inputs.nixpkgs-packages.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in

{
  imports = [
    # Development builds on the lightweight terminal interface instead of
    # repeating its tools here.
    ./terminal-tools.nix

    # Skills are only useful next to the agents that read them, so they arrive
    # with this profile rather than through an enable flag of their own.
    (modules.load ./ai-skills.nix)
    ../programs/codex.nix
  ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.atuin = {
    daemon.enable = true;
    settings.threads.capture = true;
  };

  home.packages = with pkgs; [
    # One language-server set shared by every editor on any dev host:
    # basedpyright and ruff for Python, vtsls for JS/TS, bash-language-server
    # for shell — the latter shells out to shellcheck and shfmt when they are
    # in PATH, so those two travel with it. Keeping the servers in PATH also
    # means an editor that remotes in over SSH (Zed) finds these instead of
    # downloading its own binaries onto a NixOS host.
    basedpyright
    bash-language-server
    bubblewrap
    # copier needs its Jinja extension loader inside its own environment, so it
    # arrives as a package of ours rather than the bare nixpkgs one.
    (pkgs.callPackage ../../pkgs/copier-with-extensions.nix { })
    duckdb
    fzf
    gh
    llm
    mprocs
    # terminal-tools provides yazi for day-to-day use; dev adds a mouse-friendly
    # multi-pane view and a tiny fallback for slow or minimal terminals.
    nnn
    patchelf
    packagePkgs.pixi
    ruff
    shellcheck
    shfmt
    sqlite
    superfile
    # The bare `tailwindcss` attribute is still v3 in this nixpkgs; pin the v4
    # line explicitly so the CLI matches what current projects expect.
    tailwindcss_4
    uv
    vtsls
    worktrunk
    yq-go
    zellij
    agents.claude-code
    agents.codex
    agents.collie
    agents.herdr
    agents.herdr-core
    agents.nono
    agents.omp
    agents.orca
    agents.pi
  ];

  # Keep mprocs's navigation consistent across every dev-profile host.  This
  # is declarative configuration, not process state, so Home Manager owns it.
  xdg.configFile."mprocs/mprocs.yaml".text = ''
    keymap_procs: # keymap when process list is focused
      <C-o>: { c: toggle-focus }
      <C-a>: null # unbind key
    keymap_term: # keymap when terminal is focused
      reset: true
      <C-o>: { c: toggle-focus }
      <C-a>: null # unbind key
  '';
}
