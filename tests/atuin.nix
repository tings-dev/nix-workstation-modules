# Exercise runtime secret dispatch with dummy tools; no credentials or network.
{ workstation, pkgs }:
let
  repository = "/tmp/test checkout";
  rawAtuin = pkgs.writeShellApplication {
    name = "atuin";
    text = ''
      printf '%s\n' "$@" > "$TEST_LOG/arguments"
      printf '%s' "''${ATUIN_AI__API_TOKEN:-unset}" > "$TEST_LOG/token"
    '';
  };
  resolver = pkgs.writeShellApplication {
    name = "secretspec";
    text = ''
      printf '%s\n' "$@" > "$TEST_LOG/resolver"
      if [[ "''${FAIL_RESOLVER:-0}" == 1 ]]; then exit 42; fi
      printf '%s' 'dummy-token'
    '';
  };
  home = workstation.lib.mkHome {
    imports = [ workstation.homeModules.atuin ];
    home.username = "fixture";
    home.homeDirectory = "/home/fixture";
    home.stateVersion = "26.05";
    nixpkgs.overlays = [ (_: _: {
      secretspec = resolver;
      atuin = rawAtuin // { version = "test"; };
    }) ];
    workstation.atuin.aiSecret = {
      manifest = "${repository}/secretspec.toml";
      provider = "sops://${repository}/secrets/personal-data.enc.yaml";
      reason = "Authenticate Atuin AI with atuin.example.test";
    };
  };
  wrapped = home.config.programs.atuin.package;
in
pkgs.runCommand "atuin-runtime-dispatch-test" { } ''
  export TEST_LOG="$TMPDIR/log"
  mkdir -p "$TEST_LOG"
  unset ATUIN_AI__API_TOKEN

  # Normal commands must work without asking a secret provider.
  ${wrapped}/bin/atuin status
  test ! -e "$TEST_LOG/resolver"
  test "$(cat "$TEST_LOG/token")" = unset
  test "$(cat "$TEST_LOG/arguments")" = status

  ${wrapped}/bin/atuin ai "a question with spaces"
  test "$(cat "$TEST_LOG/token")" = dummy-token
  printf '%s\n' ai 'a question with spaces' > expected-arguments
  cmp expected-arguments "$TEST_LOG/arguments"
  cat > expected-resolver <<'ARGS'
  get
  ATUIN_AI__API_TOKEN
  --file
  /tmp/test checkout/secretspec.toml
  --profile
  atuin-ai
  --provider
  sops:///tmp/test checkout/secrets/personal-data.enc.yaml
  --reason
  Authenticate Atuin AI with atuin.example.test
  ARGS
  cmp expected-resolver "$TEST_LOG/resolver"

  # A resolver failure must stop before the raw CLI runs.
  rm "$TEST_LOG/arguments" "$TEST_LOG/token"
  if FAIL_RESOLVER=1 ${wrapped}/bin/atuin ai; then exit 1; fi
  test ! -e "$TEST_LOG/arguments"
  test ! -e "$TEST_LOG/token"
  touch "$out"
''
