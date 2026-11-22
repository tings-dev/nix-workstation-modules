{ workstation, pkgs }:
let
  lib = pkgs.lib;
  keys = import (workstation.inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  mkGuest = import ./agent-guest.nix { inherit workstation pkgs; };
  guest = name: linkId: mkGuest [
    {
      networking.hostName = name;
      workstation.agentEnvironment = {
        inherit linkId;
        operatorAuthorizedKeys = [ keys.snakeOilEd25519PublicKey ];
      };
    }
  ];
  recorder = pkgs.writeScript "record-agent-command" ''
    #!${lib.getExe pkgs.python3}
    import json
    import os
    from pathlib import Path
    import sys

    command = Path(sys.argv[0]).name
    args = [command, *sys.argv[1:]]
    if command == "ssh-add":
        args.append(os.environ["SSH_AUTH_SOCK"])
    with open(os.environ["OPERATIONS"], "a") as stream:
        print(json.dumps(args), file=stream)
    if command == "systemctl" and sys.argv[1] == "show":
        print("inactive")
    elif command == "ssh-keyscan":
        print("fixture ssh-ed25519")
  '';
  hostTools = pkgs.runCommand "agent-command-test-tools" { } ''
    mkdir -p "$out/bin"
    for tool in sudo systemctl ssh ssh-add ssh-keyscan trust-host-key; do
      ln -s ${recorder} "$out/bin/$tool"
    done
  '';
  helper =
    environments: unattendedIdentity:
    let
      host = workstation.inputs.nixpkgs.lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          workstation.nixosModules.agent-environments
          {
            networking.hostName = "laptop";
            workstation.agentEnvironments = environments;
            workstation.agentSSH.unattendedIdentity = unattendedIdentity;
            programs.ssh.systemd-ssh-proxy.enable = false;
            system.stateVersion = "26.05";
          }
        ];
      };
      command = lib.findFirst (p: lib.getName p == "agent-env") null host.config.environment.systemPackages;
    in
    {
      cli = lib.getExe (command.override {
        hostTools = [ hostTools ];
        sudoCommand = "${hostTools}/bin/sudo";
        hostKeyProgram = "${hostTools}/bin/trust-host-key";
        kvmDevice = "/dev/null";
      });
      sshConfig = pkgs.writeText "agent-ssh-config" host.config.environment.etc."ssh/ssh_config".text;
    };
  fixtures = pkgs.writeText "agent-environment-command-fixtures.json" (
    builtins.toJSON {
      single = helper { work = guest "work" 101; } null;
      unattended = helper { work = guest "work" 101; } ".ssh/fixture.pub";
      matching = helper {
        alpha = guest "alpha" 101;
        agent-laptop = guest "agent-laptop" 102;
      } null;
      ambiguous = helper {
        alpha = guest "alpha" 101;
        beta = guest "beta" 102;
      } null;
      publicKey = keys.snakeOilEd25519PublicKey;
      sshKeygen = lib.getExe' pkgs.openssh "ssh-keygen";
      ssh = lib.getExe' pkgs.openssh "ssh";
      hostKeyProgram = pkgs.writers.writePython3 "agent-environment-host-key" { } (
        builtins.readFile ../nixos/agent-host-key.py
      );
    }
  );
in
pkgs.runCommand "agent-environment-command-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.fish
    ];
  }
  ''
    python3 ${./test-agent-environment-commands.py} ${fixtures}
    touch "$out"
  ''
