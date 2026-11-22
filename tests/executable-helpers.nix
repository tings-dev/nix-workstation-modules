{ pkgs }:
pkgs.runCommand "executable-helper-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${../.}/tests/test-executable-helpers.py
  touch "$out"
''
