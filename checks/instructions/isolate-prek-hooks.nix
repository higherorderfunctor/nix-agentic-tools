# Behavioral contract for the shared prek-hook rewrite used by linked worktrees.
{
  isolator,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
in {
  checks.isolate-prek-hooks = mkLintedCheck "isolate-prek-hooks-check" {
    runtimeInputs = [pkgs.coreutils pkgs.diffutils pkgs.git pkgs.gnugrep];
    text = ''
      export HOME="$PWD/home"
      mkdir -p "$HOME" primary stub
      git config --global user.email validation@example.invalid
      git config --global user.name validation
      git -C primary init -q -b main
      echo base > primary/README
      git -C primary add README
      git -C primary commit -qm base
      git -C primary worktree add -q -b feature/isolation "$PWD/worktree"
      git -C primary worktree add -q -b base "$PWD/base"
      git init -q -b main other

      hooks_dir="$(git -C primary rev-parse --path-format=absolute --git-path hooks)"
      # prek's shim is `#!/bin/sh`; dash keeps the injected guard honest POSIX.
      cat > "$hooks_dir/pre-commit" <<'HOOK'
      #!${pkgs.dash}/bin/dash
      set -eu
      exec prek run --config="/stale/checkout/.pre-commit-config.yaml" "$@"
      HOOK
      chmod 0755 "$hooks_dir/pre-commit"
      echo 'non-prek hook fixture' > "$hooks_dir/post-commit"
      chmod 0755 "$hooks_dir/post-commit"
      cp "$hooks_dir/post-commit" post-commit.before

      ( cd worktree; ${pkgs.lib.getExe isolator} )
      cmp post-commit.before "$hooks_dir/post-commit"
      test "$(stat --format=%a "$hooks_dir/pre-commit")" = 755

      cp "$hooks_dir/pre-commit" first-generation
      ( cd primary; ${pkgs.lib.getExe isolator} )
      cmp first-generation "$hooks_dir/pre-commit"

      cat > stub/prek <<'STUB'
      #!${pkgs.bash}/bin/bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      printf '%s\n' "PREK_HOME=$PREK_HOME" "$@" > "$PREK_CAPTURE"
      STUB
      chmod 0755 stub/prek
      for checkout in base other primary; do
        echo 'repos: []' > "$checkout/.pre-commit-config.yaml"
      done
      export PATH="$PWD/stub:$PATH"
      export PREK_CAPTURE="$PWD/capture"
      root="$PWD"

      run_hook() (
        cd worktree || exit 2
        unset DEVENV_ROOT
        if [ "$1" != none ]; then
          export DEVENV_ROOT="$root/$1"
        fi
        if [ "$2" = set ]; then
          GIT_DIR="$(git rev-parse --path-format=absolute --git-dir)"
          export GIT_DIR
        fi
        "$hooks_dir/pre-commit"
      )

      # No shell (editor or plain-terminal commit) uses the primary. A launch
      # worktree of this repo uses its own config. An unrelated repo never does,
      # even if Git exports a GIT_DIR that would make it look like this repo.
      while read -r launch git_dir config; do
        rm -f "$PREK_CAPTURE"
        run_hook "$launch" "$git_dir"
        if ! printf 'PREK_HOME=%s\nrun\n--config=%s\n' \
          "$root/worktree/.devenv/state/prek" "$root/$config/.pre-commit-config.yaml" \
          | diff -u - "$PREK_CAPTURE"; then
          echo "wrong hook state or config: launch=$launch GIT_DIR=$git_dir" >&2
          exit 1
        fi
      done <<'CASES'
      base unset base
      none unset primary
      other set primary
      other unset primary
      primary unset primary
      CASES

      rm base/.pre-commit-config.yaml "$PREK_CAPTURE"
      status=0
      run_hook base unset >base.out 2>&1 || status=$?
      if [ "$status" -ne 1 ] || [ -e "$PREK_CAPTURE" ] \
        || ! grep -Fxq "prek: missing: $root/base/.pre-commit-config.yaml" base.out \
        || ! grep -Fxq "  Run \"devenv shell true\" in $root/base, then commit again." base.out; then
        echo "missing launch config should abort before invoking prek (exit was $status)" >&2
        cat base.out >&2
        exit 1
      fi

      mkdir -p "$out"
      touch "$out/ok"
    '';
  };
}
