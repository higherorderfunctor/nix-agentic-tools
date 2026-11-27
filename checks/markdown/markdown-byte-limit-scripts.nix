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
      expect() {
        local row=$1 file=$2 limit=$3 status=$4 diagnostic="''${5-}" rc=0
        ${check} "$file" "$limit" probe 'Raise it.' 2>err || rc=$?
        [ "$rc" -eq "$status" ] || fail "$row: expected exit $status''${diagnostic:+ ($diagnostic)}, got $rc: $(cat err)"
        if [ -n "$diagnostic" ] && [ "$(cat err)" != "$diagnostic" ]; then
          fail "$row: expected '$diagnostic', got '$(cat err)'"
        fi
      }
      #      row                      file        limit  exit
      expect above-limit              above.md    32768  1 \
        'probe: above.md renders to 32769 bytes, exceeding its limit (32768 bytes). Raise it.'
      expect at-limit                 exact.md    32768  0
      expect below-limit              below.md    32768  0
      expect unicode-at               unicode.md  3      0
      expect unicode-bytes-not-chars  unicode.md  2      1 \
        'probe: unicode.md renders to 3 bytes, exceeding its limit (2 bytes). Raise it.'

      echo PASS >"$out"
    '';
}
