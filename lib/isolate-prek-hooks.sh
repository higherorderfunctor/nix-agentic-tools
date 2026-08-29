#!/usr/bin/env bash
# Rewrite shared prek hooks so config follows the primary checkout while state
# follows the committing worktree. Non-prek hooks are left byte-for-byte alone.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
[ -d "$hooks_dir" ] || exit 0
exec {isolate_lock_fd}>"$hooks_dir/.devenv-isolate.lock"
flock "$isolate_lock_fd"

# The shared lock serializes writers. A complete hook is rendered beside its
# target, receives the original mode, then is published by atomic rename.
guard_begin="# --- devenv worktree bootstrap guard (hooks:isolate-config) ---"
guard_end="# --- end devenv worktree bootstrap guard ---"
IFS= read -r -d "" guard_body <<'GUARD' || :
PREK_HOME="$(git rev-parse --show-toplevel)/.devenv/state/prek"
export PREK_HOME
_devenv_primary="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
_devenv_config="$_devenv_primary/.pre-commit-config.yaml"
if [ ! -f "$_devenv_config" ]; then
    echo 'prek: the primary checkout has not been bootstrapped.' >&2
    echo "  missing: $_devenv_config" >&2
    echo >&2
    echo '  .pre-commit-config.yaml is a devenv files.* artifact: it is' >&2
    echo '  materialized on devenv shell entry, and neither "git clone"' >&2
    echo '  nor "git worktree add" runs devenv.' >&2
    echo >&2
    echo "  Fix: run \"devenv shell true\" in $_devenv_primary once," >&2
    echo '  then commit again. Linked worktrees need no bootstrap of' >&2
    echo '  their own: they read the primary checkout config.' >&2
    echo >&2
    echo '  Do NOT silence this with PREK_ALLOW_NO_CONFIG=1,' >&2
    echo '  --allow-missing-config, or "prek uninstall". prek suggests' >&2
    echo '  them, but they skip every pre-commit check instead of fixing' >&2
    echo '  the bootstrap.' >&2
    exit 1
fi
GUARD

# Rewrite only prek-generated hooks: branchless and other hooks carry neither
# marker and are untouched. Strip any previous marker block before injecting
# the current one, so migrations and repeated runs are idempotent.
for hook in "$hooks_dir"/*; do
  [ -f "$hook" ] || continue
  grep -q 'prek' "$hook" || continue
  grep -q -- '--config=' "$hook" || continue

  tmp="$(mktemp "$hooks_dir/.devenv-hook.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  # shellcheck disable=SC2016 # $_devenv_config is literal hook-time shell.
  sed 's#--config="[^"]*"#--config="$_devenv_config"#' "$hook" |
    {
      in_guard=""
      injected=""
      while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$in_guard" ]; then
          if [ "$line" = "$guard_end" ]; then
            in_guard=""
          fi
          continue
        fi
        if [ "$line" = "$guard_begin" ]; then
          in_guard=1
          continue
        fi
        case "$line" in
        'exec '*)
          if [ -z "$injected" ]; then
            printf '%s\n%s%s\n' "$guard_begin" "$guard_body" "$guard_end"
            injected=1
          fi
          ;;
        *) ;;
        esac
        printf '%s\n' "$line"
      done
    } >"$tmp"

  # If prek changes its emitted shape, fail instead of publishing a hook that
  # silently resolves some other config. An unterminated old block also lands
  # here because stripping it consumes the exec line.
  grep -qF -- "$guard_begin" "$tmp" || {
    echo "hooks:isolate-config: refusing to install $hook without the bootstrap guard; it has no single-line 'exec', or an unterminated guard block swallowed it" >&2
    exit 1
  }
  chmod --reference="$hook" "$tmp"
  mv -f "$tmp" "$hook"
  trap - EXIT
done
