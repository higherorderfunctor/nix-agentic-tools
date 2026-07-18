# Hermetic branch-test for lib/validate-at-stop.sh. Exercises the Stop-hook
# orchestration (no-diff / auto-fix / block / loop-guard) against STUB
# git-hooks tools — the real linters are covered by git-hooks + CI, so this
# check stays fast and sandbox-safe. See
# docs/plans/prek-posttooluse-hook-feedback-channel.md.
{pkgs, ...}:
pkgs.runCommandLocal "validate-at-stop-check" {
  nativeBuildInputs = [pkgs.coreutils pkgs.git pkgs.python3 pkgs.shellcheck];
  src = ../lib/validate-at-stop.sh;
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$PWD/home"; mkdir -p "$HOME"
  git config --global user.email a@b.c; git config --global user.name a
  git config --global init.defaultBranch main

  # --- stub prek: `prek run <id> --files ...` ---
  #   id == treefmt        -> strip trailing WS on the given files, exit 0
  #   id == cspell-BAD      -> print a finding, exit 1
  #   id == missingfails    -> fail if any given file does not exist on disk
  #   anything else         -> exit 0
  mkdir -p stub
  cat > stub/prek <<'STUB'
  #!/usr/bin/env bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  [ "$1" = run ] || exit 0
  id="$2"; shift 2; [ "$1" = --files ] && shift
  case "$id" in
    treefmt) for f in "$@"; do sed -i 's/[[:space:]]\{1,\}$//' "$f"; done; exit 0 ;;
    cspell-BAD) echo "cspell: unknown word 'wibble' in $*"; exit 1 ;;
    missingfails) for f in "$@"; do [ -e "$f" ] || { echo "no such file: $f"; exit 1; }; done; exit 0 ;;
    *) exit 0 ;;
  esac
  STUB
  chmod +x stub/prek
  export PATH="$PWD/stub:$PATH"

  cp "$src" validate.sh; chmod +x validate.sh
  shellcheck -x validate.sh   # lint gate (matches the -x pre-commit standard)
  repo="$PWD/r"; mkdir -p "$repo"; ( cd "$repo"; git init -q; echo base > README; git add .; git commit -qm base )
  payload() { printf '{"cwd":"%s","stop_hook_active":%s,"hook_event_name":"Stop"}' "$repo" "$1"; }
  reset() { ( cd "$repo"; git reset -q --hard; git clean -qfdx ); }

  pass=0; fail=0
  ok() { if eval "$1"; then pass=$((pass+1)); else echo "FAIL: $2"; fail=$((fail+1)); fi; }

  # T1 no-diff -> silent exit 0
  reset; out="$(payload false | bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T1 rc"; ok '[ -z "$out" ]' "T1 silent"

  # T2 trailing WS -> auto-fixed via stub treefmt, no block
  reset; printf 'hi   \n' > "$repo/foo.txt"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T2 rc"
  ok '! printf "%s" "$out" | grep -q decision' "T2 no block"
  ok '! grep -nP "[ ]+\$" "$repo/foo.txt"' "T2 WS removed"

  # T3 judgment failure (stub cspell-BAD) first pass -> block w/ reason
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T3 rc"
  ok 'printf "%s" "$out" | grep -q "\"decision\": \"block\""' "T3 block"
  ok 'printf "%s" "$out" | grep -q project-terms' "T3 reason mentions escape"

  # T4 same failure, stop_hook_active=true -> loop-guard, no block
  reset; printf 'wibble\n' > "$repo/bar.txt"
  out="$(payload true | JUDGMENT_HOOKS_OVERRIDE=cspell-BAD bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T4 rc"
  ok '! printf "%s" "$out" | grep -q "\"decision\""' "T4 no block"
  ok 'printf "%s" "$out" | grep -q systemMessage' "T4 advisory"

  # T5 deleted tracked file in changeset -> excluded, no false block
  reset; ( cd "$repo"; echo x > gone.txt; git add gone.txt; git commit -qm addgone; rm gone.txt; echo ok > keep.txt )
  out="$(payload false | JUDGMENT_HOOKS_OVERRIDE=missingfails bash validate.sh)"; rc=$?
  ok '[ "$rc" -eq 0 ]' "T5 rc"
  ok '! printf "%s" "$out" | grep -q "\"decision\""' "T5 deleted file excluded"

  echo "validate-at-stop: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  mkdir -p "$out"; touch "$out/ok"
''
