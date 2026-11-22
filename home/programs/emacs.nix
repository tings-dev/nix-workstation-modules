# Small, shared Emacs baseline. The base package is terminal-only so headless
# hosts do not pull in a graphical stack; the desktop profile replaces it with
# a graphical build.
{ lib, pkgs, ... }:

{
  programs.emacs = {
    enable = true;
    package = lib.mkDefault pkgs.emacs-nox;

    extraConfig = ''
      (setq use-short-answers t)
      (setq-default indent-tabs-mode nil)

      (column-number-mode 1)
      (delete-selection-mode 1)
      (electric-pair-mode 1)
      (save-place-mode 1)
      (show-paren-mode 1)
    '';
  };

  home.sessionVariables = {
    EDITOR = "emacs -nw";
    VISUAL = "emacs";
  };
}
