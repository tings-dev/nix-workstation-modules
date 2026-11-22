# Real Traefik, DNS-01 issuance/renewal against Pebble, and controlled VPN links.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  python = pkgs.python3.withPackages (ps: [
    ps.websockets
    ps.pyyaml
  ]);
  web = message: pkgs.writeTextDir "index.html" message;
  hook = pkgs.writeShellScript "test-dns-hook" ''
    set -eu
    if [ "$1" = present ]; then
      ${pkgs.curl}/bin/curl -fsS --data "{\"host\":\"$2\",\"value\":\"$3\"}" http://acme.test:8055/set-txt
    else
      ${pkgs.curl}/bin/curl -fsS --data "{\"host\":\"$2\"}" http://acme.test:8055/clear-txt
    fi
  '';
  websocket = pkgs.writeText "test-websocket.py" ''
    from websockets.sync.server import serve
    def echo(connection):
        for message in connection:
            connection.send(message)
    with serve(echo, "127.0.0.1", 3002) as server:
        server.serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "agent-services";
  meta.timeout = 900;
  nodes = {
    acme = { nodes, ... }: {
      imports = [ (workstation.inputs.nixpkgs + "/nixos/tests/common/acme/server") ];
      virtualisation.memorySize = 512;
      environment.systemPackages = [ pkgs.nftables ];
      networking.nameservers = lib.mkForce [ "127.0.0.1" ];
      networking.firewall = {
        allowedTCPPorts = [
          53
          8055
        ];
        allowedUDPPorts = [ 53 ];
      };
      systemd.services.pebble-challtestsrv = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dnsserver :53 -defaultIPv6 '' -defaultIPv4 ${nodes.guest.networking.primaryIPAddress}";
      };
    };
    guest = { config, nodes, ... }: {
      imports = [ ../nixos/agent-services.nix ];
      networking.hostName = "agent-test";
      virtualisation.memorySize = 768;
      users.groups.agent.gid = 1000;
      users.users.agent = {
        isNormalUser = true;
        uid = 1000;
        group = "agent";
      };
      workstation.agentEnvironment.services = {
        enable = true;
        acmeEmail = "operator@example.test";
        baseDomain = "envs.example.test";
        vpnInterfaces = [
          "tailscale0"
          "wt0"
        ];
        dnsProvider = "exec";
        acmeServer = "https://acme.test/dir";
        dnsResolvers = [ "${nodes.acme.networking.primaryIPAddress}:53" ];
        dnsCredentialFiles.EXEC_PATH = "/run/agent-services-fixture/exec-path";
      };
      security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
      environment.systemPackages = [
        python
        pkgs.curl
        pkgs.jq
        pkgs.openssl
        pkgs.netcat-openbsd
      ];
      systemd.services.traefik = {
        requires = [ "agent-services-fixture.service" ];
        after = [ "agent-services-fixture.service" ];
        environment = {
          LEGO_CA_CERTIFICATES = "${nodes.acme.test-support.acme.caCert}";
          EXEC_POLLING_INTERVAL = "1";
          EXEC_PROPAGATION_TIMEOUT = "5";
          EXEC_SEQUENCE_INTERVAL = "1";
        };
        # Only test timing/propagation settings differ from production config.
        # A long expected lifetime makes the 90-day fixture cert due for renewal
        # at each restart, exercising renewal without waiting real-world days.
        serviceConfig.ExecStartPre = [
          (pkgs.writeShellScript "test-traefik-config" ''
            ${python}/bin/python3 - ${config.services.traefik.staticConfigFile} <<'PY'
            import sys, yaml
            with open(sys.argv[1]) as source:
                config = yaml.safe_load(source)
            acme = config["certificatesResolvers"]["letsencrypt"]["acme"]
            acme["certificatesDuration"] = 87600
            acme["dnsChallenge"]["propagation"] = {"disableChecks": True}
            with open("/run/traefik/test-config.yaml", "w") as target:
                yaml.safe_dump(config, target)
            PY
          '')
        ];
        serviceConfig.ExecStart = lib.mkForce "${pkgs.traefik}/bin/traefik --configfile=/run/traefik/test-config.yaml";
        serviceConfig.StandardOutput = "journal+console";
        serviceConfig.StandardError = "journal+console";
      };
      systemd.services.agent-services-fixture = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "agent-services-fixture";
          RuntimeDirectoryMode = "0700";
        };
        script = ''
          printf '%s' '${hook}' > /run/agent-services-fixture/exec-path
          chmod 600 /run/agent-services-fixture/exec-path
        '';
      };
      systemd.services.fixture-http = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "agent";
          ExecStart = "${python}/bin/python3 -m http.server 3000 --bind 127.0.0.1 --directory ${web "first-backend"}";
        };
      };
      systemd.services.fixture-replacement = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "agent";
          ExecStart = "${python}/bin/python3 -m http.server 3001 --bind 127.0.0.1 --directory ${web "replacement-backend"}";
        };
      };
      systemd.services.fixture-websocket = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "agent";
          ExecStart = "${python}/bin/python3 ${websocket}";
        };
      };
    };
  };
  testScript = { nodes, ... }: ''
    guest_ip = "${nodes.guest.networking.primaryIPAddress}"
    ${builtins.readFile ./test-agent-services-runtime.py}
  '';
}
