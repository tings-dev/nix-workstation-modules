{ pkgs }:

let
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    set -euo pipefail
    test "$PWD" = "$HOME/projects/fixture-config"
    printf 'nix %s\n' "$*" >> "$NJUST_TEST_LOG"
    test "''${FAIL_UPDATE:-0}" = 0 || exit 23
    printf '%s\n' "''${UPDATE_CONTENT:-updated}" > flake.lock
  '';
  fakeSwitch = pkgs.writeShellScript "njust-test-switch" ''
    set -euo pipefail
    test "$PWD" = "$HOME/projects/fixture-config"
    test "$(cat flake.lock)" = "''${UPDATE_CONTENT:-updated}"
    test "$(git show HEAD:flake.lock)" = "$(cat flake.lock)"
    printf 'switch %s\n' "$*" >> "$NJUST_TEST_LOG"
    test "''${FAIL_SWITCH:-0}" = 0 || exit 24
  '';
  customNjust = import ../pkgs/njust.nix {
    inherit pkgs;
    repository = "../custom checkout with 'quote";
    switchCommand = [ "false" ];
  };
  njust = import ../pkgs/njust.nix {
    repository = "../home with spaces/projects/fixture-config";
    pkgs = pkgs // {
      nix = fakeNix;
    };
    updateCommand = [ "nix" "flake" "update" "--refresh" "modules/nixpkgs" ];
    switchCommand = [
      fakeSwitch
      "switch"
      "--flake"
      ".#test-host"
    ];
  };
in
pkgs.runCommand "njust-tests"
  {
    nativeBuildInputs = [
      njust
      pkgs.git
      pkgs.bashInteractive
      pkgs.fish
    ];
  }
  ''
    export HOME="$TMPDIR/home with spaces"
    export JUST_TEMPDIR="$TMPDIR"
    export NJUST_TEST_LOG="$TMPDIR/commands"
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    export GIT_AUTHOR_NAME='Njust Test' GIT_AUTHOR_EMAIL='njust@example.invalid'
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
    repository="$HOME/projects/fixture-config"
    mkdir -p "$repository" elsewhere
    touch "$repository/flake.nix"
    printf 'original\n' > "$repository/flake.lock"
    git -C "$repository" init -b main
    printf 'original\n' > "$repository/unrelated"
    git -C "$repository" add flake.nix flake.lock unrelated
    git -C "$repository" commit -m 'test: initialize configuration'
    printf 'staged change\n' > "$repository/unrelated"
    git -C "$repository" add unrelated
    printf 'unstaged change\n' >> "$repository/unrelated"
    cat > "$repository/.git/hooks/pre-commit" <<'EOF'
    #!${pkgs.runtimeShell}
    exit "''${FAIL_COMMIT:-0}"
    EOF
    chmod +x "$repository/.git/hooks/pre-commit"
    cat > "$repository/justfile" <<'EOF'
    update-status host="":
        printf 'status %s\n' "{{ host }}" >> "$NJUST_TEST_LOG"
        test "''${FAIL_STATUS:-0}" = 0
    EOF
    # A caller's project justfile must not affect the global tasks.
    printf 'update:\n    exit 99\n' > elsewhere/justfile
    cd elsewhere

    # Explicit checkout paths are quoted literally, including apostrophes.
    mkdir -p "../custom checkout with 'quote"
    touch "../custom checkout with 'quote/flake.nix"
    ${customNjust}/bin/njust --command pwd > custom-path
    test "$(cat custom-path)" = "$(cd "../custom checkout with 'quote" && pwd)"

    njust > listing
    grep -q update listing

    # Complete from an unrelated project, through the installed shell scripts.
    # Neither completion may run a recipe or use the caller's justfile.
    printf 'update\nupdate-status\n' > expected-completions
    fish --no-config -c '
      source ${njust}/share/fish/vendor_completions.d/njust.fish
      complete -C "njust up" | string split -f 1 \t | sort
    ' > completions
    diff -u expected-completions completions
    fish --no-config -c '
      source ${njust}/share/fish/vendor_completions.d/njust.fish
      complete -C "njust --dry-run up" | string split -f 1 \t | sort
    ' > completions
    diff -u expected-completions completions
    bash --noprofile --norc <<'EOF' > completions
    source ${njust}/share/bash-completion/completions/njust.bash
    COMP_WORDS=(njust up)
    COMP_CWORD=1 COMP_LINE='njust up' COMP_POINT=8 COMP_TYPE=9
    _clap_complete_njust
    printf '%s\n' "''${COMPREPLY[@]}" | sort
    EOF
    diff -u expected-completions completions
    bash --noprofile --norc <<'EOF' > completions
    source ${njust}/share/bash-completion/completions/njust.bash
    COMP_WORDS=(njust --dry-run up)
    COMP_CWORD=2 COMP_LINE='njust --dry-run up' COMP_POINT=17 COMP_TYPE=9
    _clap_complete_njust
    printf '%s\n' "''${COMPREPLY[@]}" | sort
    EOF
    diff -u expected-completions completions

    printf '%s\n' --dry-run > expected-completions
    fish --no-config -c '
      source ${njust}/share/fish/vendor_completions.d/njust.fish
      complete -C "njust --dr" | string split -f 1 \t
    ' > completions
    diff -u expected-completions completions
    bash --noprofile --norc <<'EOF' > completions
    source ${njust}/share/bash-completion/completions/njust.bash
    COMP_WORDS=(njust --dr)
    COMP_CWORD=1 COMP_LINE='njust --dr' COMP_POINT=10 COMP_TYPE=9
    _clap_complete_njust
    printf '%s\n' "''${COMPREPLY[@]}"
    EOF
    diff -u expected-completions completions

    njust --dry-run update
    test ! -e "$NJUST_TEST_LOG"
    test "$(cat "$repository/flake.lock")" = original

    njust update-status
    njust update-status workstation
    printf 'status \nstatus workstation\n' > expected
    diff -u expected "$NJUST_TEST_LOG"
    if FAIL_STATUS=1 njust update-status; then
      echo 'status-task failure was ignored' >&2
      exit 1
    fi
    test "$(cat "$repository/flake.lock")" = original
    rm "$NJUST_TEST_LOG"

    njust update
    printf 'nix flake update --refresh modules/nixpkgs\nswitch switch --flake .#test-host\n' > expected
    diff -u expected "$NJUST_TEST_LOG"
    test "$(git -C "$repository" log -1 --format=%s)" = 'chore(nix): update flake inputs'
    test "$(git -C "$repository" diff-tree --no-commit-id --name-only -r HEAD)" = flake.lock
    test "$(git -C "$repository" diff --cached --name-only)" = unrelated
    test "$(git -C "$repository" show :unrelated)" = 'staged change'
    test "$(tail -1 "$repository/unrelated")" = 'unstaged change'
    update_commit=$(git -C "$repository" rev-parse HEAD)

    # Identical inputs create no empty commit and still activate the host.
    : > "$NJUST_TEST_LOG"
    njust update
    diff -u expected "$NJUST_TEST_LOG"
    test "$(git -C "$repository" rev-parse HEAD)" = "$update_commit"

    : > "$NJUST_TEST_LOG"
    printf 'original\n' > "$repository/flake.lock"
    if FAIL_UPDATE=1 njust update; then
      echo 'input-update failure was ignored' >&2
      exit 1
    fi
    printf 'nix flake update --refresh modules/nixpkgs\n' > expected
    diff -u expected "$NJUST_TEST_LOG"
    test "$(cat "$repository/flake.lock")" = original
    test "$(git -C "$repository" rev-parse HEAD)" = "$update_commit"

    : > "$NJUST_TEST_LOG"
    if UPDATE_CONTENT=commit-failed FAIL_COMMIT=1 njust update; then
      echo 'commit failure was ignored' >&2
      exit 1
    fi
    diff -u expected "$NJUST_TEST_LOG"
    test "$(git -C "$repository" rev-parse HEAD)" = "$update_commit"
    test "$(cat "$repository/flake.lock")" = commit-failed
    test "$(git -C "$repository" diff --cached --name-only)" = unrelated

    if UPDATE_CONTENT=switch-failed FAIL_SWITCH=1 njust update; then
      echo 'switch failure was ignored' >&2
      exit 1
    fi
    test "$(cat "$repository/flake.lock")" = switch-failed
    test "$(git -C "$repository" show HEAD:flake.lock)" = switch-failed

    rm "$repository/flake.nix"
    if njust update; then
      echo 'missing checkout was ignored' >&2
      exit 1
    fi
    touch "$out"
  ''
