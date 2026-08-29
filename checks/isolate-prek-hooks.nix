# Behavioral contract for the shared prek-hook rewrite used by linked worktrees.
{
  isolator,
  pkgs,
}:
pkgs.runCommandLocal "isolate-prek-hooks-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$PWD/home"
  mkdir -p "$HOME" primary stub
  git config --global user.email validation@example.invalid
  git config --global user.name validation
  git -C primary init -q -b main
  echo base > primary/README
  git -C primary add README
  git -C primary commit -qm base
  git -C primary worktree add -q -b feature/isolation "$PWD/worktree"

  hooks_dir="$(git -C primary rev-parse --path-format=absolute --git-path hooks)"
  cat > "$hooks_dir/pre-commit" <<'HOOK'
  #!${pkgs.bash}/bin/bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  exec prek run --config="/stale/checkout/.pre-commit-config.yaml" "$@"
  HOOK
  chmod 0755 "$hooks_dir/pre-commit"
  echo 'non-prek hook fixture' > "$hooks_dir/post-commit"
  chmod 0755 "$hooks_dir/post-commit"
  cp "$hooks_dir/post-commit" post-commit.before

  ( cd worktree; ${pkgs.lib.getExe isolator} )
  grep -Fq 'PREK_HOME="$(git rev-parse --show-toplevel)/.devenv/state/prek"' "$hooks_dir/pre-commit"
  grep -Fq '_devenv_primary="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"' "$hooks_dir/pre-commit"
  grep -Fq -- '--config="$_devenv_config"' "$hooks_dir/pre-commit"
  cmp post-commit.before "$hooks_dir/post-commit"
  test "$(stat --format=%a "$hooks_dir/pre-commit")" = 755

  cp "$hooks_dir/pre-commit" first-generation
  ( cd primary; ${pkgs.lib.getExe isolator} )
  cmp first-generation "$hooks_dir/pre-commit"
  test "$(grep -Fc 'devenv worktree bootstrap guard' "$hooks_dir/pre-commit")" = 2

  # A linked worktree needs no config of its own. Missing primary bootstrap is
  # a hard failure with the actionable diagnostic, not prek's skip advice.
  if ( cd worktree; "$hooks_dir/pre-commit" ) >missing.out 2>&1; then
    echo "rewritten hook allowed a missing primary config" >&2
    exit 1
  fi
  grep -Fq 'primary checkout has not been bootstrapped' missing.out
  grep -Fq 'devenv shell true' missing.out

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
  export PATH="$PWD/stub:$PATH"
  export PREK_CAPTURE="$PWD/capture"
  ( cd worktree; "$hooks_dir/pre-commit" )
  grep -Fq "PREK_HOME=$PWD/worktree/.devenv/state/prek" capture
  grep -Fq -- "--config=$PWD/primary/.pre-commit-config.yaml" capture

  mkdir -p "$out"
  touch "$out/ok"
''
