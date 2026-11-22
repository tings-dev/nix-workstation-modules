{
  description = "Reusable NixOS and Home Manager workstation modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Pixi and Craft use the package channel, whose current outputs are cached.
    # Keep NixOS on its tested system channel without local Rust build fixes.
    nixpkgs-packages.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Executable lookup uses a prebuilt index. Keep its own nixpkgs pin so rexe
    # runs packages from the revision used to generate that index.
    nix-index-database.url = "github:nix-community/nix-index-database";

    # Consumers select the matching hardware module for each host.
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Dux Modular Shell (bar, launcher, notifications, OSD). The /stable branch is
    # the release channel; dropping it follows git and its breaking changes.
    # This input supplies the Home Manager module; home/programs/dux.nix
    # overrides its source-built package with the cache-backed nixpkgs one.
    dms = {
      url = "github:duxlabs-dev/dux-shell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DMS's local filesystem-search companion. Its Home Manager module owns
    # the user service; the index itself remains mutable runtime state.
    dsearch = {
      url = "github:AvengeMedia/danksearch";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Prebuilt Firefox extensions, packaged by rycee (same content the NUR
    # exposes, but as a standalone flake without the rest of the NUR).
    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Fast-moving AI tools, packaged and refreshed independently of nixpkgs.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Herdr's desktop threads panel, kept reproducible alongside the app.
    herdr-atuin-threads = {
      url = "github:atuinsh/herdr-atuin-threads";
      flake = false;
    };

    # Only the four Craft apps missing from nixpkgs use this input. Pin the
    # reviewed release set explicitly so routine flake updates keep it stable.
    # These are prebuilt tarballs, not cached source builds: following our
    # nixpkgs shares runtime libraries and only rebuilds the small wrappers.
    craft-prebuilt = {
      url = "github:mahlquistj/artcraft-flake/10f2199c6eaabf72bea95cb7f37e1515d51171fc";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Agent skills, one input per source repo. `flake = false` keeps each one a
    # plain source tree, so flake.lock records its revision and hash and no skill
    # ever needs a hand-written one. A skill is only Markdown, so nothing here is
    # built: home/skills points straight into these trees. Refresh them all with
    # `just update-skills`, or one with `nix flake update skills-<name>`.
    skills-mattpocock = {
      url = "github:mattpocock/skills";
      flake = false;
    };
    skills-copilot = {
      url = "github:github/awesome-copilot";
      flake = false;
    };

    stylix = {
      url = "github:nix-community/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      modules = {
        inherit inputs;
        load = path: {
          key = toString path;
          _file = toString path;
          imports = [ (import path modules) ];
        };
      };
    in
    {
      nixosModules = {
        agent-environment = modules.load ./nixos/agent-environment.nix;
        agent-environments = modules.load ./nixos/features/agent-environments.nix;
        common = ./nixos/common.nix;
        craft = ./nixos/features/craft.nix;
        desktop = modules.load ./nixos/features/desktop.nix;
        dev = ./nixos/features/dev.nix;
        gitea-runner = ./nixos/features/gitea-runner.nix;
        hardware = ./nixos/features/hardware.nix;
        management = ./nixos/management.nix;
        netbird = ./nixos/features/netbird.nix;
        openlogi = ./nixos/features/openlogi.nix;
        prepared-updates = ./nixos/features/prepared-updates.nix;
        seat = modules.load ./nixos/features/seat.nix;
        syncthing = ./nixos/features/syncthing.nix;
        unattended-key = ./nixos/features/unattended-key.nix;
        disko = inputs.disko.nixosModules.disko;
      };

      homeModules = {
        atuin = ./home/programs/atuin.nix;
        ai-skills = modules.load ./home/features/ai-skills.nix;
        bash = ./home/programs/bash.nix;
        codex-reset-calendar = ./home/features/codex-reset-calendar.nix;
        commands = modules.load ./home/features/commands.nix;
        common = modules.load ./home/common.nix;
        craft = modules.load ./home/features/craft.nix;
        desktop = modules.load ./home/features/desktop.nix;
        desktop-dev = modules.load ./home/features/desktop-dev.nix;
        dev = modules.load ./home/features/dev.nix;
        git = ./home/programs/git.nix;
        management = ./home/management.nix;
        personal-data = ./home/features/personal-data.nix;
        prepared-updates = ./home/features/prepared-updates.nix;
        seat = modules.load ./home/features/seat.nix;
        security-key = ./home/features/security-key.nix;
        ssh-key = ./home/features/ssh-key.nix;
        syncthing = ./home/features/syncthing.nix;
        terminal-tools = ./home/features/terminal-tools.nix;
        unattended-key = ./home/features/unattended-key.nix;
      };

      lib.mkHost =
        host:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.workstation = self;
          modules = [
            home-manager.nixosModules.home-manager
            ./nixos/features/prepared-updates.nix
            ./nixos/features/unattended-key.nix
            ./nixos/features/syncthing.nix
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs.workstation = self;
                sharedModules = [ self.homeModules.syncthing ];
              };
            }
            host
          ];
        };

      checks.${system} = import ./tests { workstation = self; };

      lib.mkHome =
        home:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = import ./pkgs/allow-unfree.nix { inherit (nixpkgs) lib; };
          };
          extraSpecialArgs.workstation = self;
          modules = [
            self.homeModules.syncthing
            home
          ];
        };
    };
}
