# Execute the generated Markdown tree's byte-limit guard. Codex launcher
# warnings are calibrated separately with the real binary in its owner checks.
#
# The boundary is the point: a limit is the largest size the reader takes
# whole, so the file AT the limit passes and one byte past it fails. `é\n` is
# two characters and three bytes, so a limit of two tells bytes from
# characters.
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
      sized() {
        head -c "$1" /dev/zero | tr '\0' x >"$2"
      }
      sized 32767 below.md
      sized 32768 exact.md
      sized 32769 above.md
      printf 'é\n' >unicode.md
      ${check} below.md 32768 probe 'Raise it.' || fail "32767 bytes fail a 32768-byte limit"
      ${check} exact.md 32768 probe 'Raise it.' || fail "32768 bytes fail a 32768-byte limit"
      if ${check} above.md 32768 probe 'Raise it.' 2>err; then
        fail "32769 bytes pass a 32768-byte limit"
      fi
      [ "$(cat err)" = "probe: above.md renders to 32769 bytes, exceeding its limit (32768 bytes). Raise it." ] \
        || fail "unexpected failure message: $(cat err)"
      ${check} unicode.md 3 probe 'Raise it.' || fail "3 bytes fail a 3-byte limit"
      if ${check} unicode.md 2 probe 'Raise it.' 2>err; then
        fail "a 3-byte file passes a 2-byte limit: characters were counted, not bytes"
      fi
      grep -q -F "renders to 3 bytes" err || fail "unexpected failure message: $(cat err)"

      echo PASS >"$out"
    '';
}
