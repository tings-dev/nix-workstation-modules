# Real lifecycle + SSH, offline fixtures, private test workspace, no host shares.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  previousTool = pkgs.writeShellScriptBin "previous-tool" "echo previous-closure-ok";
  projectShell = pkgs.mkShell { packages = [ pkgs.hello ]; };
  buildDependencies = pkgs.linkFarm "project-build-dependencies" {
    shell = projectShell;
    # Trivial builders use stdenvNoCC, distinct from mkShell's C/C++ stdenv.
    package = pkgs.mkShellNoCC { };
  };
  image = pkgs.dockerTools.buildImage {
    name = "agent-development-fixture";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "container-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sh" ];
  };
  # Compiled outside Nix's ELF interpreter path; exercises nix-ld and libstdc++.
  genericLinux =
    pkgs.runCommand "generic-linux-runtime" { nativeBuildInputs = [ pkgs.stdenv.cc ]; }
      ''
        mkdir -p $out/bin
        cat > main.cc <<'EOF'
        #include <iostream>
        int main() { std::cout << "generic-linux-ok\n"; }
        EOF
        g++ main.cc -o $out/bin/generic-linux -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2
        ${pkgs.patchelf}/bin/patchelf --remove-rpath $out/bin/generic-linux
      '';
  projectFlake = pkgs.writeText "agent-development-flake.nix" ''
    {
      inputs.nixpkgs.url = "path:${workstation.inputs.nixpkgs}";
      outputs = { self, nixpkgs }: let
        pkgs = import nixpkgs { system = "x86_64-linux"; };
        oldTool = pkgs.writeShellScriptBin "previous-tool" "echo previous-closure-ok";
      in {
        devShells.x86_64-linux.default = pkgs.mkShell {
          packages = [ pkgs.hello ];
          shellHook = "export AGENT_PROJECT_SHELL=project-shell-ok";
        };
        packages.x86_64-linux.garbage = pkgs.writeText "collect-me" "collect-me";
        packages.x86_64-linux.default = pkgs.writeShellScriptBin "agent-package"
          ("echo " + builtins.readFile ./revision + "\nexec ''${oldTool}/bin/previous-tool");
      };
    }
  '';
  pythonProject = pkgs.writeText "agent-dependency-pyproject.toml" ''
    [build-system]
    requires = ["setuptools"]
    build-backend = "setuptools.build_meta"
    [project]
    name = "agent-dependency"
    version = "1.0"
  '';
  fixtures =
    pkgs.runCommand "agent-development-fixtures"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (ps: [
            ps.build
            ps.setuptools
            ps.wheel
          ]))
        ];
      }
      ''
            mkdir -p $out/language/agent_dependency
            printf 'def message(): return "language-dependency-ok"\n' > $out/language/agent_dependency/__init__.py
            cp ${pythonProject} $out/language/pyproject.toml
            python -m build --wheel --no-isolation --outdir $out/wheels $out/language
            echo ${workstation.inputs.nixpkgs} > $out/nixpkgs-path
        ln -s ${buildDependencies} $out/build-dependencies
            ln -s ${image} $out/container.tar
            ln -s ${genericLinux}/bin/generic-linux $out/generic-linux
            cp ${projectFlake} $out/flake.nix
      '';
  guest =
    updated:
    mkGuest [
      workstation.nixosModules.dev
      {
        home-manager.users.agent.imports = [ workstation.homeModules.dev ];
        networking.hostName = "development";
        workstation.agentEnvironment = {
          linkId = 103;
          memoryMiB = 3072;
          storageMiB = 32768;
        };
        environment.etc."development-generation".text = if updated then "updated" else "initial";
        home-manager.users.agent.home.file.".config/operator-baseline".text =
          if updated then "reviewed-baseline-update\n" else "initial-baseline\n";
        # Fixtures are present in the initial closure only. The installed package
        # must retain previousTool even after the new bootstrap image omits it.
        environment.etc."development-fixtures" = lib.mkIf (!updated) { source = fixtures; };
        environment.systemPackages = [ pkgs.python3 ] ++ lib.optional (!updated) previousTool;
      }
    ];
in
pkgs.testers.runNixOSTest {
  name = "agent-development-lifecycle";
  meta.timeout = 2400;
  nodes.host = {
    imports = [ workstation.nixosModules.agent-environments ];
    workstation.agentEnvironments.development = guest false;
    # Apply a real operator-side NixOS configuration update, preserving disks.
    specialisation.updated.configuration.workstation.agentEnvironments.development = lib.mkForce (
      guest true
    );
    boot.kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    networking.useDHCP = false;
    virtualisation = {
      cores = 4;
      memorySize = 6144;
      diskSize = 65536;
      qemu.options = [
        "-cpu"
        "host"
      ];
    };
    environment.etc."agent-test-key".source = keys.snakeOilEd25519PrivateKey;
    environment.systemPackages = [ pkgs.openssh ];
  };
  testScript = builtins.readFile ./test-agent-development.py;
}
