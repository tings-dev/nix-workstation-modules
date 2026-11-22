{ pkgs }:
pkgs.runCommand "agent-environment-state-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.lsof
    ];
  }
  ''
    python3 ${../.}/tests/test-agent-environment-state.py
    touch "$out"
  ''
