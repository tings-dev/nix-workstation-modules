# Real temporary Git repos; Nix, activation, notifications and systemctl are fake.
{ pkgs }:
pkgs.runCommand "prepared-updates-tests"
  {
    nativeBuildInputs = with pkgs; [
      python3
      git
      gnutar
      coreutils
    ];
  }
  ''
    python3 ${../.}/tests/test-prepared-system-update.py
    touch "$out"
  ''
