# Check effective SSH routing without connecting, enrolling keys or starting agents.
{ workstation, pkgs }:
let
  targets = [ "192.0.2.1" "git.example.test" "satellite" ];
  home = backend: (workstation.lib.mkHome {
    imports = [
      workstation.homeModules.ssh-key
      workstation.homeModules.security-key
      workstation.homeModules.unattended-key
      {
        home.username = "fixture";
        home.homeDirectory = "/home/fixture";
        home.stateVersion = "26.05";
        workstation.unattendedKey = { inherit backend targets; };
      }
    ];
  }).config;
  software = home "software";
  tpm = home "tpm";
  sshConfig = config: pkgs.writeText "identity-ssh-config" config.home.file.".ssh/config".text;
  noAmbientAgent = config:
    !(config.home.sessionVariables ? SSH_AUTH_SOCK)
    && !config.services.ssh-agent.enable
    && !config.services.ssh-tpm-agent.enable;
in
assert noAmbientAgent software && noAmbientAgent tpm;
assert software.systemd.user.services.unattended-key-agent.Install.WantedBy == [ "default.target" ];
assert tpm.systemd.user.services.unattended-key-agent.Install.WantedBy == [ "default.target" ];
pkgs.runCommand "identity-routing-test" { nativeBuildInputs = [ pkgs.openssh ]; } ''
  export XDG_RUNTIME_DIR="$TMPDIR/runtime"
  unset SSH_AUTH_SOCK
  for backend in software tpm; do
    case "$backend" in
      software) cfg=${sshConfig software}; key='~/.ssh/id_ed25519_unattended' ;;
      tpm) cfg=${sshConfig tpm}; key='~/.ssh/id_ecdsa.pub' ;;
    esac
    for host in ${pkgs.lib.escapeShellArgs targets}; do
      ssh -G -F "$cfg" "$host" > effective
      grep -Fx 'identitiesonly yes' effective
      grep -Fx "identityfile $key" effective
      grep -F 'identityagent ' effective | grep -F '/unattended-key.sock'
    done
    # An unrelated connection must not inherit the unattended key or agent.
    ssh -G -F "$cfg" unrelated.invalid > effective
    if grep -F 'unattended-key.sock' effective; then exit 1; fi
    if grep -Fx "identityfile $key" effective; then exit 1; fi
  done
  touch "$out"
''
