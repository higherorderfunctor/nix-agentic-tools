# The two byte-limit programs in lib/markdown/byte-limit.nix, executed. A
# Markdown tree's install check runs `byteLimitCheck` on each limited file,
# and devenv's shell entry runs `windowNotice` on the project's AGENTS.md; the
# module checks prove each is wired to the right file and limit, and this
# proves what each one does with it.
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
    notice = lib.getExe byteLimit.windowNotice;
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
      sized 40000 big.md
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

      ${notice} missing.md 32768 codex 2>err || fail "the notice fails on a missing file"
      [ -s err ] && fail "the notice warns about a missing file: $(cat err)"
      ${notice} exact.md 32768 codex 2>err || fail "the notice fails on a file within the limit"
      [ -s err ] && fail "the notice warns about a file within the limit: $(cat err)"
      ${notice} big.md 32768 codex 2>err || fail "the notice fails on a file past the limit"
      [ "$(cat err)" = "warning: big.md is 40000 bytes; codex in an untrusted project reads only the first 32768. Trust the project in codex, or shrink the always-loaded content." ] \
        || fail "unexpected notice: $(cat err)"

      echo PASS >"$out"
    '';
}
