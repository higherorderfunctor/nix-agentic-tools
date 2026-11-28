# Execute the generated Markdown tree's byte-limit guard. Codex launcher
# warnings are calibrated separately with the real binary in its owner checks.
#
# `é\n` is two characters and three bytes, so a limit of two rejects the
# file only if the guard counts bytes. The Codex owner check covers success
# at the limit, and the runtime-files context routing check covers a file
# below it.
{
  lib,
  pkgs,
  ...
}: {
  checks.markdown-byte-limit-scripts = let
    byteLimit = import ../../lib/markdown/byte-limit.nix pkgs;
    check = lib.getExe byteLimit.byteLimitCheck;
  in
    pkgs.runCommand "markdown-byte-limit-scripts" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      fail() {
        echo "FAIL: markdown-byte-limit-scripts: $1" >&2
        exit 1
      }
      printf 'é\n' >unicode.md
      # One over must fail even though the character count fits.
      rc=0
      ${check} unicode.md 2 probe 'Raise it.' 2>err || rc=$?
      diagnostic='probe: unicode.md renders to 3 bytes, exceeding its limit (2 bytes). Raise it.'
      got=$(cat err)
      [ "$rc" -eq 1 ] || fail "above-limit: expected exit 1, got $rc: $got"
      [ "$got" = "$diagnostic" ] || fail "above-limit: expected '$diagnostic', got '$got'"

      echo PASS >"$out"
    '';
}
