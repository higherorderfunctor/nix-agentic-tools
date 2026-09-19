# checks/strictdoc/daemon-only-source.nix -- the executing guard for
# REQ-DAEMON-IS-THE-ONLY-SOURCE. The source scanner rejects new grammar and
# corpus readers outside the daemon, sandboxed checks, tests, and the recorded
# semantics violation.
{
  pkgs,
  self,
}:
pkgs.runCommand "daemon-only-source" {
  nativeBuildInputs = [pkgs.python3];
} ''
  python3 ${./daemon-only-source.py} ${self} | tee "$out"

  fixture="$TMPDIR/daemon-only-source-fixture"
  mkdir -p "$fixture/dev/scripts" "$fixture/docs/sdoc"
  cat > "$fixture/dev/scripts/rogue.py" <<'PY'
  import os
  from scribe_grammar import parse_sgra

  grammar = "grammar.sgra"
  for directory, _directories, files in os.walk("."):
      print(directory, [name for name in files if name.endswith(".sdoc")])
  PY

  if python3 ${./daemon-only-source.py} "$fixture" \
      >"$TMPDIR/fixture-out" 2>"$TMPDIR/fixture-err"; then
    echo "self-test FAILED: the planted disk reader passed" >&2
    exit 1
  fi
  for expected in \
      "imports parse_sgra" \
      "names a grammar.sgra path literal" \
      "walks the filesystem for .sdoc files"; do
    if ! grep -qF -- "$expected" "$TMPDIR/fixture-err"; then
      echo "self-test FAILED: planted reader did not report: $expected" >&2
      cat "$TMPDIR/fixture-err" >&2
      exit 1
    fi
  done
  echo "self-test: planted disk reader is rejected" | tee -a "$out"
''
