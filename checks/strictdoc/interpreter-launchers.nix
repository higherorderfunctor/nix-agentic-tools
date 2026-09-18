# Gate REQ-DEPS-FROM-DEVENV: active devenv process/task definitions and shell
# launchers under docs/ and dev/ may not resolve Python or Node from ambient
# PATH. The fixture is the removed docs/sdoc/board/serve launcher verbatim, so
# the positive control proves the scanner sees the defect that created it.
{
  pkgs,
  self,
}:
pkgs.runCommandLocal "interpreter-launchers-check" {
  nativeBuildInputs = [pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  ${pkgs.python3}/bin/python3 ${./interpreter-launchers.py} ${self} \
    | ${pkgs.coreutils}/bin/tee "$out"

  status=0
  ${pkgs.python3}/bin/python3 ${./interpreter-launchers.py} ${self} \
    ${./fixtures/interpreter-launchers/serve.fixture} \
    > "$TMPDIR/control.log" 2>&1 || status=$?
  ${pkgs.coreutils}/bin/cat "$TMPDIR/control.log"
  if [ "$status" -ne 1 ]; then
    echo "POSITIVE CONTROL FAILED: old board launcher exited $status, expected 1" >&2
    exit 1
  fi
  ${pkgs.gnugrep}/bin/grep -F \
    "bare interpreter python3: exec python3 \"\$script_dir/server.py\" \"\$@\"" \
    "$TMPDIR/control.log" >/dev/null
''
