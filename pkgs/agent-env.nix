{
  pkgs,
  lib,
  guests,
  hostName,
  vmStateDir,
  sshPolicy,
  stateHelper,
  hostKeyProgram,
  hostTools ? [ ],
  sudoCommand ? "/run/wrappers/bin/sudo",
  kvmDevice ? "/dev/kvm",
}:
let
  names = builtins.attrNames guests;
  hostEnvironment = "agent-${hostName}";
  defaultEnvironment =
    if builtins.length names == 1 then
      builtins.head names
    else if builtins.elem hostEnvironment names then
      hostEnvironment
    else
      "";
  operatorNames = builtins.filter (
    name: guests.${name}.config.workstation.agentEnvironment.operatorAuthorizedKeys != [ ]
  ) names;
  knownHostsPath = ''"$HOME"/${lib.escapeShellArg sshPolicy.knownHostsFile}'';
  sshOptions = lib.mapAttrsToList (
    key: value: "-o${key}=${if builtins.isBool value then lib.boolToYesNo value else toString value}"
  ) sshPolicy.options;
  details =
    name:
    let
      guest = guests.${name}.config;
      cfg = guest.workstation.agentEnvironment;
      stateDir = "${vmStateDir}/${name}";
      diskPath = image: if lib.hasPrefix "/" image then image else "${stateDir}/${image}";
      vpnClients =
        lib.optional cfg.vpn.tailscale.enable "Tailscale" ++ lib.optional cfg.vpn.netbird.enable "NetBird";
    in
    [
      "Physical host:"
      hostName
      "Address:"
      sshPolicy.targets.${name}.HostName
      "TAP interface:"
      "ae-${name}"
      "Configured CPUs:"
      (toString guest.microvm.vcpu)
      "Configured memory:"
      "${toString guest.microvm.mem} MiB"
      "VPN clients:"
      (if vpnClients == [ ] then "none" else lib.concatStringsSep ", " vpnClients)
      "State directory:"
      stateDir
      "Runner link:"
      "${stateDir}/current"
    ]
    ++ lib.concatMap (volume: [
      "Disk image:"
      (diskPath volume.image)
      "Guest mount:"
      (if volume.mountPoint == null then "unmounted" else volume.mountPoint)
      "Configured disk:"
      (if volume.size == null then "existing image" else "${toString volume.size} MiB (creation size)")
    ]) guest.microvm.volumes
    ++ [
      "Shared folders:"
      (if cfg.shares == { } then "none" else "")
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (shareName: share: [
        "  ${shareName}:"
        "${share.source} -> ${share.destination} (${share.access})"
      ]) cfg.shares
    );
in
pkgs.writeShellApplication {
  name = "agent-env";
  runtimeInputs = hostTools ++ [
    pkgs.systemd
    pkgs.openssh
    pkgs.coreutils
    pkgs.gnugrep
  ];
  text = ''
    environment_status() {
      local state
      state=$(systemctl show "microvm@$1.service" --property=ActiveState --value) || return
      case "$state" in
        active) echo running ;;
        inactive) echo stopped ;;
        activating) echo starting ;;
        deactivating) echo stopping ;;
        *) echo "$state" ;;
      esac
    }
    if [[ "''${1:-}" == list ]]; then
      if (( $# != 1 )); then
        echo 'usage: agent-env list' >&2
        exit 2
      fi
      printf '%-16s %s\n' NAME STATUS
      environments=( ${lib.escapeShellArgs names} )
      for name in "''${environments[@]}"; do
        status=$(environment_status "$name")
        printf '%-16s %s\n' "$name" "$status"
      done
      exit 0
    fi
    if (( $# == 0 )); then
      echo 'usage: agent-env list | agent-env {start|stop|restart|delete|status|details|ssh|ssh-operator|public-ssh-key|public-age-key|trust-host-key} [NAME] [-- remote command...]' >&2
      exit 2
    fi
    action=$1; shift
    case "$action" in
      start|stop|restart|delete|status|details|ssh|ssh-operator|public-ssh-key|public-age-key|trust-host-key) ;;
      *) echo "Unknown operation: $action" >&2; exit 2 ;;
    esac
    if (( $# == 0 )) || [[ "$1" == -- ]]; then
      name=${lib.escapeShellArg defaultEnvironment}
      if [[ -z "$name" ]]; then
        echo ${lib.escapeShellArg "No default agent environment: declare just one environment or one named ${hostEnvironment}, or specify NAME."} >&2
        echo ${lib.escapeShellArg "Available environments: ${lib.concatStringsSep ", " names}"} >&2
        exit 2
      fi
    else
      name=$1; shift
    fi
    if [[ "''${1:-}" == -- ]]; then
      shift
    fi
    case "$name" in
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: target: ''
        ${name})
          address=${lib.escapeShellArg target.HostName}
          host_alias=${lib.escapeShellArg target.HostKeyAlias}
          ;;
      '') sshPolicy.targets)}
      *) echo "Unknown agent environment: $name" >&2; exit 2 ;;
    esac
    case "$action" in
      ssh|ssh-operator) ;;
      *)
        if (( $# != 0 )); then
          echo "usage: agent-env $action [NAME]" >&2
          exit 2
        fi
        ;;
    esac
    unit="microvm@$name.service"
    case "$action" in
      trust-host-key)
        exec ${hostKeyProgram} "$name" ${knownHostsPath} "$host_alias" \
          ${lib.getExe' pkgs.systemd "systemctl"} \
          ${lib.getExe' pkgs.systemd "journalctl"} \
          ${lib.getExe' pkgs.openssh "ssh-keygen"} ${lib.escapeShellArg sudoCommand}
        ;;
      details)
        status=$(environment_status "$name")
        printf '%-20s %s\n' 'Name:' "$name" 'Status:' "$status" 'Service:' "$unit"
        case "$name" in
          ${lib.concatMapStringsSep "\n" (
            name: "${name}) printf '%-20s %s\\n' ${lib.escapeShellArgs (details name)} ;;"
          ) names}
        esac
        ;;
      start|restart)
        if [[ ! -c ${lib.escapeShellArg kvmDevice} ]]; then
          echo 'Runtime blocker: KVM is unavailable; no guest was started.' >&2
          exit 1
        fi
        ${lib.escapeShellArg sudoCommand} ${stateHelper} "$action" "$name"
        # QEMU's service is simple: active alone is not guest readiness.
        # First boot seeds the complete development closure on private disk.
        deadline=$((SECONDS + 600))
        while ((SECONDS < deadline)); do
          if ! systemctl is-active --quiet "$unit"; then
            echo "Failed to start $name; inspect journalctl -u $unit" >&2
            exit 1
          fi
          if timeout 1 ssh-keyscan -T 1 -p ${toString sshPolicy.options.Port} -t ed25519 "$address" 2>/dev/null | grep -q ssh-ed25519; then
            echo "$name is running (SSH ready)."
            exit 0
          fi
          sleep 1
        done
        echo "SSH readiness timed out for $name; inspect journalctl -u $unit" >&2
        exit 1
        ;;
      stop) exec ${lib.escapeShellArg sudoCommand} systemctl stop "$unit" ;;
      delete)
        exec ${lib.escapeShellArg sudoCommand} ${stateHelper} delete "$name"
        ;;
      status) exec systemctl status "$unit" ;;
      ssh|ssh-operator|public-ssh-key|public-age-key)
        ssh_user=${lib.escapeShellArg sshPolicy.user}
        tty_args=()
        if [[ "$action" == ssh-operator ]]; then
          case "$name" in
            ${lib.concatMapStringsSep "\n" (name: "${name}) operator_enabled=yes ;;") operatorNames}
            *) operator_enabled=no ;;
          esac
          if [[ "$operator_enabled" != yes ]]; then
            echo "Operator login is not enabled for $name; configure workstation.agentEnvironment.operatorAuthorizedKeys first." >&2
            exit 2
          fi
          ssh_user=operator
          if (( $# == 0 )); then
            tty_args=(-t)
          fi
        fi
        case "$action" in
          public-ssh-key) set -- 'cat /home/agent/.ssh/id_ed25519.pub' ;;
          public-age-key) set -- 'age-keygen -y /home/agent/.config/sops/age/keys.txt' ;;
        esac
        known_hosts=${knownHostsPath}
        if [[ -e "$known_hosts" && ( ! -f "$known_hosts" || ! -r "$known_hosts" ) ]]; then
          echo "Cannot read the SSH known-hosts file: $known_hosts" >&2
          exit 255
        fi
        if [[ ! -f "$known_hosts" ]] || ! ssh-keygen -F "$host_alias" -f "$known_hosts" >/dev/null; then
          cat >&2 <<EOF
    No SSH host key has been trusted for agent environment '$name' yet.
    Run this on the physical host to retrieve and save its current boot's console key:
      agent-env trust-host-key $name

    This creates $known_hosts with mode 0600 if needed and preserves other entries.
    Then retry:
      agent-env $action $name
    EOF
          exit 255
        fi
        # Let OpenSSH expand runtime paths after it parses each option so a
        # space in HOME or XDG_RUNTIME_DIR stays part of a single path.
        identity_args=()
        ${lib.optionalString (sshPolicy.identityFile != null) ''
          XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          export XDG_RUNTIME_DIR
          socket="$XDG_RUNTIME_DIR"/${lib.escapeShellArg sshPolicy.identitySocket}
          if [[ ! -S "$socket" ]] || ! SSH_AUTH_SOCK="$socket" ssh-add -l >/dev/null 2>&1; then
            echo 'Unattended SSH key unavailable or disarmed; run frkl-arm on the physical host and retry.' >&2
            exit 1
          fi
          identity="$HOME"/${lib.escapeShellArg sshPolicy.identityFile}
          identity_args=(-o "IdentityAgent=\''${XDG_RUNTIME_DIR}/${sshPolicy.identitySocket}" -i "$identity")
        ''}
        exec ssh -F /dev/null "''${tty_args[@]}" "''${identity_args[@]}" \
          ${lib.escapeShellArgs sshOptions} \
          -o "UserKnownHostsFile=\''${HOME}/${sshPolicy.knownHostsFile}" \
          -o HostKeyAlias="$host_alias" -o ConnectTimeout=5 \
          "$ssh_user@$address" "$@"
        ;;
      *) echo "Unknown operation: $action" >&2; exit 2 ;;
    esac
  '';
}
