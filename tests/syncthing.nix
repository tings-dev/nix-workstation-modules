# Exercise the actual pre-start command offline, never starting a sync daemon.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  homeModule = {
    home = {
      username = "fixture";
      homeDirectory = "/home/fixture";
      stateVersion = "26.05";
    };
  };
  home = (workstation.lib.mkHome {
    imports = [ homeModule ];
    workstation.features.syncthing.enable = true;
  }).config;
  system = enabled: (workstation.lib.mkHost {
    boot.isContainer = true;
    system.stateVersion = "26.05";
    services.tailscale.interfaceName = "tail-test";
    users.users.fixture.isNormalUser = true;
    home-manager.users.fixture = {
      imports = [ homeModule ];
      workstation.features.syncthing.enable = enabled;
    };
  }).config;
  enabled = system true;
  disabled = system false;
in
assert home.services.syncthing.enable;
assert !home.services.syncthing.overrideDevices && !home.services.syncthing.overrideFolders;
assert !home.services.syncthing.tray.enable;
assert home.services.syncthing.guiAddress == "127.0.0.1:8384";
assert home.services.syncthing.settings.devices == { };
assert home.services.syncthing.settings.folders == { };
assert !(home.systemd.user.services ? syncthing-init);
assert home.systemd.user.services.syncthing.Install.WantedBy == [ "default.target" ];
assert enabled.services.tailscale.enable && enabled.users.users.fixture.linger;
assert !enabled.services.syncthing.enable;
assert enabled.networking.firewall.interfaces.tail-test.allowedTCPPorts == [ 22000 ];
assert !(builtins.elem 22000 enabled.networking.firewall.allowedTCPPorts);
assert enabled.networking.firewall.allowedUDPPorts == [ ];
assert !disabled.services.tailscale.enable && disabled.users.users.fixture.linger != true;
assert disabled.networking.firewall.interfaces == { };
pkgs.runCommand "syncthing-runtime-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./test-syncthing.py} \
    ${lib.escapeShellArgs home.systemd.user.services.syncthing.Service.ExecStartPre}
  touch "$out"
''
