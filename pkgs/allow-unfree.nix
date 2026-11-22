{ lib }:
pkg:
builtins.elem (lib.getName pkg) [
  "pycharm"
  "slack"
]
