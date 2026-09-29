# Behavioral contract for the shared prek-hook rewrite used by linked worktrees.
{
  isolator,
  pkgs,
  ...
}: let
  mkLintedCheck = import ../../lib/mk-linted-check.nix {inherit pkgs;};
in {
  checks.isolate-prek-hooks = mkLintedCheck "isolate-prek-hooks-check" {
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep];
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
      printf 'PREK_HOME=%s\n' "$PREK_HOME" > "$PREK_CAPTURE"
      printf 'ARGV=' >> "$PREK_CAPTURE"
      printf '%s ' "$@" >> "$PREK_CAPTURE"
      printf '\n' >> "$PREK_CAPTURE"
      STUB
      chmod 0755 stub/prek
      echo 'repos: []' > primary/.pre-commit-config.yaml
      echo 'repos: []' > base/.pre-commit-config.yaml
      echo 'repos: []' > other/.pre-commit-config.yaml
      export PATH="$PWD/stub:$PATH"
      export PREK_CAPTURE="$PWD/capture"
      root="$PWD"
      expect_config() {
        grep -Fq -- "--config=$1/.pre-commit-config.yaml" capture \
          || { cat capture >&2; return 1; }
      }

      # No devenv shell (an editor or plain-terminal commit): the primary.
      ( cd worktree; env -u DEVENV_ROOT "$hooks_dir/pre-commit" )
      expect_config "$PWD/primary"
      grep -Fq "PREK_HOME=$PWD/worktree/.devenv/state/prek" capture

      ( cd worktree; DEVENV_ROOT="$root/primary" "$hooks_dir/pre-commit" )
      expect_config "$root/primary"

      # Launched from a long-lived worktree of this repository: its config.
      ( cd worktree; DEVENV_ROOT="$root/base" "$hooks_dir/pre-commit" )
      expect_config "$root/base"

      # Launched from another repository: never its config, and git exports
      # GIT_DIR to hooks, which, left in place, makes that repository look like this one.
      ( cd worktree; DEVENV_ROOT="$root/other" "$hooks_dir/pre-commit" )
      expect_config "$PWD/primary"

      ( cd worktree
        GIT_DIR="$(git rev-parse --path-format=absolute --git-dir)" \
          DEVENV_ROOT="$root/other" "$hooks_dir/pre-commit" )
      expect_config "$PWD/primary"

      rm base/.pre-commit-config.yaml
      if ( cd worktree; DEVENV_ROOT="$root/base" "$hooks_dir/pre-commit" ) >base.out 2>&1; then
        echo "rewritten hook allowed a missing launch-checkout config" >&2
        exit 1
      fi
      grep -Fq "missing: $root/base/.pre-commit-config.yaml" base.out
      grep -Fq "devenv shell true\" in $root/base" base.out

      mkdir -p "$out"
      touch "$out/ok"
    '';
  };
}
