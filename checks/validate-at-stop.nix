# Hermetic branch-test for lib/validate-at-stop.sh. Exercises the Stop-hook
# orchestration (no-diff / auto-fix / block / loop-guard) against STUB
# git-hooks tools — the real linters are covered by git-hooks + CI, so this
# check stays fast and sandbox-safe. See
# docs/plans/prek-posttooluse-hook-feedback-channel.md.
# cspell:ignore addgone missingfails prekhome wibble  (test-scaffold tokens, not project vocabulary)
{pkgs, ...}:
pkgs.runCommandLocal "validate-at-stop-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.python3 pkgs.shellcheck];
  src = ../lib/validate-at-stop.sh;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  outdir="$out"   # capture $out before the test loop reuses `out` as a local var
  export HOME="$PWD/home"; mkdir -p "$HOME"
  git config --global user.email a@b.c; git config --global user.name a
  git config --global init.defaultBranch main

  # --- stub prek: `prek run <id> --hook-stage manual --config <cfg> --files ...` ---
  #   id == treefmt         -> strip trailing WS; exit 1 on change, then 0
  #   id == treefmt-BAD     -> persistent formatter failure
  #   id == cspell-BAD      -> print a finding, exit 1
  #   id == missingfails    -> fail if any given file does not exist on disk
  #   id == echo-env        -> print the resolved config + PREK_HOME, exit 1
  #   anything else         -> exit 0
  # The stub asserts the argv SHAPE by construction: the stage is mandatory,
  # and dropping --config leaves `cfg` empty and fails the echo-env probe.
  mkdir -p stub
  cat > stub/prek <<'STUB'
  #!${pkgs.bash}/bin/bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  [ "$1" = run ] || exit 0
  id="$2"; shift 2
  cfg=""; stage=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hook-stage) stage="$2"; shift 2 ;;
      --config) cfg="$2"; shift 2 ;;
      --files) shift; break ;;
      *) echo "unexpected prek argument: $1" >&2; exit 2 ;;
    esac
  done
  [ "$stage" = manual ] || { echo "missing manual hook stage" >&2; exit 2; }
  case "$id" in
    treefmt*) [ "''${TREEFMT_NO_CACHE:-}" = true ] || { echo "treefmt cache must be disabled at Stop" >&2; exit 2; } ;;
  esac
  case "$id" in
    treefmt)
      changed=0
      for f in "$@"; do
        if grep -q '[[:space:]]$' "$f"; then changed=1; fi
        sed -i 's/[[:space:]]\{1,\}$//' "$f"
      done
      exit "$changed"
      ;;
    treefmt-BAD) echo "treefmt: configuration failed"; exit 1 ;;
    cspell-BAD) echo "cspell: unknown word 'wibble' in $*"; exit 1 ;;
    missingfails) for f in "$@"; do [ -e "$f" ] || { echo "no such file: $f"; exit 1; }; done; exit 0 ;;
    echo-env) echo "CFG=$cfg"; echo "PREKHOME=''${PREK_HOME:-}"; exit 1 ;;
    *) exit 0 ;;
  esac
  STUB
  chmod +x stub/prek
  export PATH="$PWD/stub:$PATH"
  export FORMATTER_HOOK_ID_OVERRIDE=treefmt

  cp "$src" validate.sh; chmod +x validate.sh
  shellcheck -x validate.sh   # lint gate (matches the -x pre-commit standard)
  repo="$PWD/r"; mkdir -p "$repo"
  ( cd "$repo"; git init -q; echo base > README; git add .; git commit -qm base
    echo '.pre-commit-config.yaml' >> .git/info/exclude )
  # Model the real config faithfully: a gitignored devenv `files.*` artifact,
  # UNTRACKED in the primary checkout. Tracking it in the fixture would make
  # `git worktree add` check a copy out into the linked worktree and quietly
  # defeat T6. `git clean -fdx` deletes it, so re-materialize after each reset —
  # which is exactly what a devenv shell entry does for real.
  make_config() { echo 'repos: []' > "$repo/.pre-commit-config.yaml"; }
  make_config
  payload() { printf '{"cwd":"%s","stop_hook_active":%s,"hook_event_name":"Stop"}' "$repo" "$1"; }
  reset() { ( cd "$repo"; git reset -q --hard; git clean -qfdx ); make_config; }

  pass=0; fail=0
  ok() { if eval "$1"; then pass=$((pass+1)); else echo "FAIL: $2"; fail=$((fail+1)); fi; }

  # Assertions below match with `grep -q … <<<"$out"`, NEVER
  # `printf "%s" "$out" | grep -q …`. `ok` runs `eval` on its argument, so the
  # pipeline would inherit this script's `set -euETo pipefail`; `grep -q`
  # exits at its first match and bash's printf builtin writes a multi-line
  # capture a line at a time, so the writes after the match EPIPE and poison
  # the pipeline's status. That silently inverts every assertion here: the
  # positive forms report FAIL on output that matched, and the `!` forms
  # report PASS on output that also matched. A here-string has no writer
  # process, so neither can happen.

  # T1 no-diff -> silent exit 0
  reset; out="$(payload false | bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T1 rc"; ok '[ -z "$out" ]' "T1 silent"

  # T2 trailing WS -> auto-fixed via stub treefmt, no block, and the Stop hook
  # leaves a deliberately different staged snapshot untouched.
  reset
  printf 'staged   \n' > "$repo/README"; ( cd "$repo"; git add README )
  cached_before="$(cd "$repo"; git show :README)"
  printf 'working   \n' > "$repo/README"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T2 rc"
  ok '! grep -q decision <<<"$out"' "T2 no block"
  ok '! grep -nP "[ ]+\$" "$repo/README"' "T2 WS removed"
  ok '[ "$(cd "$repo"; git show :README)" = "$cached_before" ]' "T2 index untouched"

  # T3 judgment failure (stub cspell-BAD) first pass -> block w/ reason
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T3 rc"
  ok 'grep -q "\"decision\": \"block\"" <<<"$out"' "T3 block"
  ok 'grep -q project-terms <<<"$out"' "T3 reason mentions escape"

  # T4 same failure, stop_hook_active=true -> loop-guard, no block
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload true | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T4 rc"
  ok '! grep -q "\"decision\"" <<<"$out"' "T4 no block"
  ok 'grep -q systemMessage <<<"$out"' "T4 advisory"

  # T5 deleted tracked file in changeset -> excluded, no false block
  reset; ( cd "$repo"; echo x > gone.txt; git add gone.txt; git commit -qm addgone; rm gone.txt; echo ok > keep.txt )
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=missingfails bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T5 rc"
  ok '! grep -q "\"decision\"" <<<"$out"' "T5 deleted file excluded"

  # T6 session cwd is a LINKED WORKTREE that has no config of its own -> the
  # config resolves from the primary checkout (shared common git dir) while
  # PREK_HOME stays under the committing worktree. This is the launch-from-main
  # topology: devenv is entered in the primary checkout only.
  reset
  wt="$PWD/wt"; ( cd "$repo"; git worktree add -q -b feature "$wt" )
  ok '[ ! -e "$wt/.pre-commit-config.yaml" ]' "T6 fixture worktree has no config of its own"
  printf 'wibble\n' > "$wt/w.txt"
  wt_payload='{"cwd":"'"$wt"'","stop_hook_active":false,"hook_event_name":"Stop"}'
  out="$(printf '%s' "$wt_payload" | JUDGMENT_HOOKS_OVERRIDE=echo-env bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T6 rc"
  ok 'grep -q "CFG=$repo/.pre-commit-config.yaml" <<<"$out"' "T6 config from primary checkout"
  ok 'grep -q "PREKHOME=$wt/.devenv/state/prek" <<<"$out"' "T6 PREK_HOME under committing worktree"

  # T7 primary checkout never bootstrapped -> advise, never block. Blocking here
  # would be unfixable from inside the turn, and the bare `prek run` it replaces
  # exits 2 with a config-not-found error the judgment loop reads as a finding.
  # An ordinary repo with no config, NOT a `git init --bare` one: a bare repo
  # never reaches this code at all, it exits at the work-tree gate.
  no_config="$PWD/no_config"; mkdir -p "$no_config"
  ( cd "$no_config"; git init -q; echo base > README; git add .; git commit -qm base; printf 'wibble\n' > b.txt )
  out="$(printf '{"cwd":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$no_config" \
    | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T7 rc"
  ok '! grep -q "\"decision\"" <<<"$out"' "T7 no block on missing config"
  ok 'grep -q systemMessage <<<"$out"' "T7 advisory"
  ok 'grep -q "devenv shell true" <<<"$out"' "T7 advisory names the fix"

  # T8 a formatter that still fails after the convergence pass is a finding,
  # not a swallowed error. It uses the same block channel as judgment lint.
  reset; printf 'broken\n' > "$repo/formatter.txt"
  out="$(payload false | FORMATTER_HOOK_ID_OVERRIDE=treefmt-BAD JUDGMENT_HOOKS_OVERRIDE=cspell bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T8 rc"
  ok 'grep -q "\"decision\": \"block\"" <<<"$out"' "T8 block"
  ok 'grep -q "treefmt: configuration failed" <<<"$out"' "T8 formatter error reported"

  echo "validate-at-stop: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  mkdir -p "$outdir"; touch "$outdir/ok"
''
