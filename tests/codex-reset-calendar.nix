# Preserve the source CLI tests with fake query/DAV commands and temporary data.
{ pkgs }:
let
  python = pkgs.python3.withPackages (p: [ p.icalendar ]);
in
pkgs.runCommand "codex-reset-calendar-test"
  {
    nativeBuildInputs = [
      python
      pkgs.bash
      pkgs.jq
      pkgs.coreutils
    ];
  }
  ''
    python3 ${../.}/tests/test-codex-reset-calendar.py
    touch "$out"
  ''
