# One definition of the interactive aliases, applied to every shell.
#
# Fish is the login shell on the source NixOS hosts, but bash is what non-interactive
# tooling, `ssh <host> <command>` and the odd script land in, and having the
# muscle memory work in only one of them is the whole problem this file exists
# to remove.
#
# Nothing here may be fish syntax or bash syntax written by hand. Aliases go in
# the attribute sets below and the two shells are rendered from them, so a new
# alias cannot arrive in one shell and be forgotten in the other.
{ lib, ... }:

let
  # Aliases whose text is identical in both shells. `home.shellAliases` is the
  # seam: Home Manager writes it into bash and fish alike, so there is no second
  # copy to keep in step.
  portable = {
    gs = "git status";
    ga = "git add";
    gb = "git branch";
    gc = "git commit";
    gd = "git diff";
    gco = "git checkout";
    gl = "git hist";
    gt = "git tag";
    gsu = "git submodule update --recursive";
    sync-template = "git add .* * && git commit -m 'chore: sync project template'";
    syt = "git add .* * && git commit -m 'chore: sync project template'";

    sc = "systemctl";
    scs = "systemctl start";
    scr = "systemctl restart";
    sct = "systemctl stop";
    sce = "systemctl enable";
    scd = "systemctl disable";
    scu = "systemctl --user";
    scus = "systemctl --user start";
    scuu = "systemctl --user status";
    scur = "systemctl --user restart";
    scut = "systemctl --user stop";
    scue = "systemctl --user enable";
    scud = "systemctl --user disable";

    ssh-no-key = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
    port = "netstat -tulanp";
    listen = "lsof -P -i -n";
    grep = "grep --color=auto --exclude-dir={.bzr,CVS,.git,.hg,.svn}";
  };

  # Aliases worth defining only when the command is installed, keyed by the
  # command to test for. This module reaches every host, while most of these
  # packages arrive with a profile, so an unguarded alias would shadow the real
  # command with a broken one on a host that never asked for it.
  whenInstalled = {
    bat = {
      cat = "bat";
      c = "bat -pp";
    };

    chezmoi.ccd = "chezmoi cd";

    curl.my_ip = "curl https://ipinfo.io";

    eza = {
      ls = "eza";
      lr = "eza -lasmodified";
      lss = "eza -lassize";
      lR = "eza -R";
      ll = "eza -la";
      e = "eza";
      el = "eza --long --header --git";
      et2 = "eza --long --tree --level=2";
      et3 = "eza --long --tree --level=3";
      et4 = "eza --long --tree --level=4";
      et5 = "eza --long --tree --level=5";
      ett = "eza --long --tree --level ";
      tree = "eza --tree";
      tree1 = "eza --tree -L1";
      tree2 = "eza --tree -L2";
      tree3 = "eza --tree -L3";
      treel = "eza --tree|less -R";
      treel1 = "eza --tree -L1|less -R";
      treel2 = "eza --tree -L2|less -R";
      treel3 = "eza --tree -L3|less -R";
    };

    htop.htop = "TERM=xterm-256color command htop";

    just.j = "just";

    pass.old-pass = "PASSWORD_STORE_DIR=~/.pass/old command pass";

    superfile.spf = "superfile";
  };

  # `command -v` rather than either shell's helper function, so this module
  # depends on nothing but POSIX and renders the same test into both files.
  aliasLines = lib.mapAttrsToList (name: value: "  alias ${name}=${lib.escapeShellArg value}");

  fishBlock = command: aliases: lib.concatStringsSep "\n" (
    [ "if command -v ${command} >/dev/null 2>&1" ] ++ aliasLines aliases ++ [ "end" ]
  );

  bashBlock = command: aliases: lib.concatStringsSep "\n" (
    [ "if command -v ${command} >/dev/null 2>&1; then" ] ++ aliasLines aliases ++ [ "fi" ]
  );

  render = block: lib.concatStringsSep "\n\n" (lib.mapAttrsToList block whenInstalled) + "\n";
in
{
  home.shellAliases = portable;

  # The one pair that genuinely differs: fish cannot source a POSIX activate
  # script, and bash cannot source the fish one. Kept adjacent so the divergence
  # is a visible decision rather than two files drifting apart.
  programs.fish.shellAliases = {
    venv = "source .venv/bin/activate.fish";
    vv = "source .venv/bin/activate.fish";
  };
  programs.bash.shellAliases = {
    venv = "source .venv/bin/activate";
    vv = "source .venv/bin/activate";
  };

  programs.fish.interactiveShellInit = render fishBlock;
  programs.bash.initExtra = render bashBlock;
}
