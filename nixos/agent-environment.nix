# Deliberately independent of nixos/common.nix and the personal access policy.
modules@{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.workstation.agentEnvironment;
  publicKeyType = lib.types.strMatching "(ssh-ed25519|sk-(ecdsa-sha2-nistp256|ssh-ed25519)@openssh[.]com) [A-Za-z0-9+/=]+( .*)?";
  hasOperator = cfg.operatorAuthorizedKeys != [ ];
in
{
  imports = [
    inputs.microvm.nixosModules.microvm
    inputs.home-manager.nixosModules.home-manager
    ./nix.nix
    ./agent-private-store.nix
    ./agent-shares.nix
    ./agent-vpn.nix
    ./agent-services.nix
  ];
  options.workstation.agentEnvironment = {
    cpus = lib.mkOption {
      type = lib.types.ints.between 1 64;
      default = 2;
      description = "Guest virtual CPU count.";
    };
    memoryMiB = lib.mkOption {
      type = lib.types.ints.between 256 262144;
      default = 1536;
      description = "Guest memory in MiB.";
    };
    storageMiB = lib.mkOption {
      type = lib.types.ints.between 512 1048576;
      default = 16384;
      description = "Private root disk size in MiB, fixed at first creation.";
    };
    linkId = lib.mkOption {
      type = lib.types.ints.between 1 254;
      description = "Unique host-local link number; uses 10.83.<id>.0/30.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.nonEmptyListOf publicKeyType;
      description = "Explicit incoming SSH public keys for agent; never private keys.";
    };
    operatorAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf publicKeyType;
      default = [ ];
      description = "Explicit human operator SSH public keys. A nonempty list creates a separate operator account with passwordless sudo; agent remains unprivileged.";
    };
  };

  config = {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.agent = (modules.load ../home/agent-environment.nix);

    assertions = [
      {
        assertion = cfg.memoryMiB != 2048;
        message = "Agent environment memoryMiB must differ from 2048: QEMU's microvm machine hangs at exactly 2 GiB (microvm.nix issue 171).";
      }
    ];
    microvm = {
      hypervisor = "qemu";
      vcpu = cfg.cpus;
      mem = cfg.memoryMiB;
      # Only the guest closure is exposed, as an immutable bootstrap image.
      # agent-private-store.nix seeds a fully private persistent writable store.
      storeOnDisk = true;
      socket = "control.socket";
      preStart = ''
        if [ -e private.img ] && [ "$(${pkgs.coreutils}/bin/stat -c %s private.img)" -ne ${
          toString (cfg.storageMiB * 1048576)
        } ]; then
          echo 'Private disk size differs from storageMiB; stop and resize it through operator-reviewed maintenance before starting.' >&2
          exit 1
        fi
      '';
      qemu.machineOpts = {
        accel = "kvm";
        acpi = "on";
        pit = "off";
        pic = "off";
        # microvm.nix uses PCI virtio devices when shares are present.
        pcie = if config.microvm.shares != [ ] then "on" else "off";
        usb = "off";
        mem-merge = "off";
      };
      volumes = [
        {
          image = "private.img";
          mountPoint = "/";
          label = "agent-root";
          size = cfg.storageMiB;
        }
      ];
      interfaces = [
        {
          type = "tap";
          id = "ae-${config.networking.hostName}";
          mac = "02:00:00:83:00:${lib.fixedWidthString 2 "0" (lib.toHexString cfg.linkId)}";
        }
      ];
    };
    fileSystems."/".neededForBoot = true;
    networking = {
      useDHCP = false;
      useNetworkd = true;
      # Shares switch QEMU from MMIO to PCI virtio devices. Keep the single
      # management NIC named eth0 so the static address and gateway still apply.
      usePredictableInterfaceNames = lib.mkIf (config.microvm.shares != [ ]) false;
      defaultGateway = {
        address = "10.83.${toString cfg.linkId}.1";
        interface = "eth0";
      };
      # Query public resolvers directly; no guest access to a host DNS proxy.
      nameservers = lib.mkDefault [
        "9.9.9.9"
        "149.112.112.112"
      ];
      interfaces.eth0.ipv4.addresses = [
        {
          address = "10.83.${toString cfg.linkId}.2";
          prefixLength = 30;
        }
      ];
      firewall.allowedTCPPorts = [ 22 ];
    };
    users = {
      # Administrative access is a separate, explicitly authorized account.
      allowNoPasswordLogin = true;
      mutableUsers = false;
      users.agent = {
        isNormalUser = true;
        uid = 1000;
        group = "agent";
        home = "/home/agent";
        # A locked password still permits public-key authentication via PAM.
        hashedPassword = "!";
        # Herdr Core starts its own transient user services on demand. Keep the
        # user manager alive after the last SSH/client logout, without sudo or
        # a competing repository-owned core service.
        linger = true;
        subUidRanges = [
          {
            startUid = 100000;
            count = 65536;
          }
        ];
        subGidRanges = [
          {
            startGid = 100000;
            count = 65536;
          }
        ];
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      };
      groups.agent.gid = 1000;
      users.operator = lib.mkIf hasOperator {
        isNormalUser = true;
        uid = 1001;
        group = "operator";
        home = "/home/operator";
        homeMode = "0700";
        hashedPassword = "!";
        openssh.authorizedKeys.keys = cfg.operatorAuthorizedKeys;
      };
      groups.operator = lib.mkIf hasOperator { gid = 1001; };
    };
    security.sudo = {
      enable = hasOperator;
      extraRules = lib.optional hasOperator {
        users = [ "operator" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      };
    };
    security.doas.enable = false;
    # No rootful container API. The agent may enable its own user socket.
    systemd.sockets.podman.enable = false;
    nix.settings.trusted-users = lib.mkForce [ "root" ];
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ "agent" ] ++ lib.optional hasOperator "operator";
        AllowAgentForwarding = false;
        AllowTcpForwarding = false;
        X11Forwarding = false;
      };
    };
    environment.systemPackages = [ pkgs.age ];
    # SOPS's default age identity, generated only inside the running guest.
    # Keep this independent of SSH key setup so either identity can be repaired.
    systemd.services.agent-age-key = {
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "agent";
        Group = "agent";
        WorkingDirectory = "/home/agent";
        UMask = "0077";
      };
      path = [
        pkgs.age
        pkgs.coreutils
      ];
      script = ''
        install -d -m 700 .config/sops/age
        key=.config/sops/age/keys.txt
        if [ ! -e "$key" ] && [ ! -L "$key" ]; then
          age-keygen -o "$key"
        fi
        chmod 600 "$key"
        # Validate existing identities without replacing them or logging secrets.
        age-keygen -y "$key" > /dev/null
      '';
    };
    # Runtime-only, agent-owned client identity on the persistent private disk.
    # The default OpenSSH filename works without owning the agent's SSH config.
    systemd.services.agent-ssh-client-key = {
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "agent";
        Group = "agent";
        WorkingDirectory = "/home/agent";
        UMask = "0077";
      };
      path = [
        pkgs.openssh
        pkgs.coreutils
      ];
      script = ''
        install -d -m 700 .ssh
        key=.ssh/id_ed25519
        if [ ! -e "$key" ] && [ ! -L "$key" ]; then
          if [ -e "$key.pub" ] || [ -L "$key.pub" ]; then
            echo 'Outgoing SSH private key is missing; recover or deliberately rotate the identity.' >&2
            exit 1
          fi
          ssh-keygen -q -t ed25519 -N "" -C 'agent@${config.networking.hostName}' -f "$key"
        fi
        chmod 600 "$key"
        # Derive only the public half; repair a missing/stale public file without
        # replacing the private identity. Invalid/encrypted private keys fail.
        public=$(mktemp .ssh/.public-key.XXXXXX)
        trap 'rm -f "$public"' EXIT
        ssh-keygen -y -P "" -f "$key" > "$public"
        chmod 644 "$public"
        mv -f "$public" "$key.pub"
      '';
    };
    # First-use trust comes from the operator's authenticated host console,
    # never an unauthenticated ssh-keyscan. The private key stays in the guest.
    systemd.services.agent-ssh-host-key = {
      requires = [ "sshd-keygen.service" ];
      after = [ "sshd-keygen.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        printf 'AGENT_SSH_HOST_KEY %s %s\n' '${config.networking.hostName}' "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" > /dev/ttyS0
      '';
    };
    system.stateVersion = "26.05";
  };
}
