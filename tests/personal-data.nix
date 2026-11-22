# Verify runtime secret dispatch and the enrollment gate without credentials.
{ workstation, pkgs }:
let
  lib = pkgs.lib;
  resolver = pkgs.writeShellApplication {
    name = "secretspec";
    text = ''
      printf '%s\n' "$@" > "$TEST_LOG/resolver"
      if [[ "''${FAIL_RESOLVER:-0}" == 1 ]]; then exit 42; fi
      printf '%s' 'dummy-secret'
    '';
  };
  evaluate =
    extra:
    (workstation.lib.mkHome {
      imports = [
        workstation.homeModules.personal-data
        {
          home = {
            username = "fixture";
            homeDirectory = "/home/fixture";
            stateVersion = "26.05";
          };
          nixpkgs.overlays = [ (_: _: { secretspec = resolver; }) ];
          workstation.repositoryPath = lib.mkDefault "/tmp/test checkout";
          workstation.personalData = {
            realName = "Fixture User";
            accounts.mail = {
              provider = "fastmail";
              address = "fixture@example.test";
              primary = true;
              mail.enable = true;
            };
          };
        }
        extra
      ];
    }).config;
  base = evaluate { };
  changed = evaluate { workstation.personalData.accounts.mail.contacts.enable = true; };
  helper = lib.findFirst (p: lib.getName p == "frkl-personal-data-secret") null base.home.packages;
  marker = base.systemd.user.services.personal-data-mail.Unit.ConditionPathExists;
  policy = pkgs.writeText "personal-data.conf" base.xdg.configFile."frkl/personal-data.conf".text;
in
assert marker != changed.systemd.user.services.personal-data-mail.Unit.ConditionPathExists;
assert
  marker == (evaluate { workstation.repositoryPath = "/tmp/another checkout"; })
  .systemd.user.services.personal-data-mail.Unit.ConditionPathExists;
assert !(base.systemd.user.services ? personal-data-pim);
assert
  changed.systemd.user.services.personal-data-pim.Unit.ConditionPathExists
  == changed.systemd.user.services.personal-data-mail.Unit.ConditionPathExists;
pkgs.runCommand "personal-data-runtime-test" { } ''
  export TEST_LOG="$TMPDIR/log"
  mkdir -p "$TEST_LOG"
  # The exported policy must remain sourceable when paths contain spaces.
  . ${policy}
  test "$manifest" = '/tmp/test checkout/secretspec.toml'
  test "$provider" = 'sops:///tmp/test checkout/secrets/personal-data.enc.yaml'
  test "$marker" = ${lib.escapeShellArg marker}
  test ! -e "$marker"

  for key in FASTMAIL_MAIL_PASSWORD FASTMAIL_DAV_PASSWORD GOOGLE_MAIL_PASSWORD POSTEO_MAIL_PASSWORD NEXTCLOUD_DAV_PASSWORD; do
    test "$(${helper}/bin/frkl-personal-data-secret "$key")" = dummy-secret
    printf '%s\n' get "$key" --file '/tmp/test checkout/secretspec.toml' --profile personal-data --provider 'sops:///tmp/test checkout/secrets/personal-data.enc.yaml' > expected
    cmp expected "$TEST_LOG/resolver"
  done
  rm "$TEST_LOG/resolver"
  if ${helper}/bin/frkl-personal-data-secret UNKNOWN; then exit 1; fi
  test ! -e "$TEST_LOG/resolver"
  if FAIL_RESOLVER=1 ${helper}/bin/frkl-personal-data-secret FASTMAIL_MAIL_PASSWORD > result; then exit 1; fi
  test ! -s result
  touch "$out"
''
