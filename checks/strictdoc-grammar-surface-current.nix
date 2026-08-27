# cspell:ignore PYTHONDONTWRITEBYTECODE
# checks/strictdoc-grammar-surface-current.nix -- acceptance items 1 and 2 of
# SLICE-GRAMMAR-FROM-NIX (packages/strictdoc-grammar/docs/implementation-brief.md).
#
# The two GENERATED layers must be current. `lib/faithful.nix` is extracted
# from strictdoc's own grammar string and `lib/normalized.nix` is rewritten
# from faithful, so either one can silently rot the moment the pinned input's
# strictdoc moves -- and a stale surface is worse than no surface: it
# type-checks values against a grammar strictdoc no longer speaks.
#
# Both entry points already carry `--check`, which regenerates in memory and
# diffs against the committed file rather than writing it. This check is that
# flag, run against `${self}` so the committed bytes are what gets diffed.
#
# `alejandra` is NOT optional here. `emit_nix.format_nix` shells out to it and
# DOWNGRADES a miss to a warning, passing the source through unformatted -- so
# a check run without it would diff unformatted output against the committed
# (formatted) file and report drift that does not exist. The package's own
# wrapper deliberately does not carry it (its PATH holds only what extraction
# needs), which is why it is named here instead.
#
# POSITIVE CONTROL. A `--check` that can only ever exit 0 is not a gate, and
# nothing in the pass path distinguishes "regenerated output matches" from
# "the comparison never ran". Both entry points are therefore also run against
# a MUTATED copy of their target and required to report drift. The copies live
# in $TMPDIR; the committed files are read-only store paths and are never
# touched by either arm.
{
  pkgs,
  self,
  strictdocGrammarExtract,
}: let
  grammarDir = "${self}/packages/strictdoc-grammar";
in
  pkgs.runCommand "strictdoc-grammar-surface-current" {
    nativeBuildInputs = [
      strictdocGrammarExtract
      pkgs.alejandra
    ];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    export HOME="$TMPDIR"
    # The extractor's sources are read-only store paths; without this python
    # tries (and silently fails) to drop a __pycache__ beside each of them.
    export PYTHONDONTWRITEBYTECODE=1

    extract=${grammarDir}/extract
    faithful=${grammarDir}/lib/faithful.nix
    normalized=${grammarDir}/lib/normalized.nix

    rc=0
    fail() { echo "  FAIL: $*" >&2; rc=1; }

    echo "== 1. faithful.nix is what strictdoc's grammar extracts to =="
    strictdoc-grammar-extract "$extract/extract.py" --output "$faithful" --check \
      || fail "lib/faithful.nix is STALE -- run: devenv tasks run --mode before generate:sdoc-grammar"

    echo "== 2. normalized.nix is what faithful.nix normalizes to =="
    strictdoc-grammar-extract "$extract/normalize.py" \
      --input "$faithful" --output "$normalized" --check \
      || fail "lib/normalized.nix is STALE -- run: devenv tasks run --mode before generate:sdoc-grammar"

    echo "== positive control: --check reports drift when the target differs =="
    # One appended comment line is enough of a difference and cannot change
    # what either generator PRODUCES -- only what it is compared against.
    for pair in "$faithful:faithful" "$normalized:normalized"; do
      cp "''${pair%%:*}" "$TMPDIR/''${pair##*:}-drifted.nix"
      chmod +w "$TMPDIR/''${pair##*:}-drifted.nix"
      echo '# deliberate drift, injected by the positive control' \
        >> "$TMPDIR/''${pair##*:}-drifted.nix"
    done

    if strictdoc-grammar-extract "$extract/extract.py" \
         --output "$TMPDIR/faithful-drifted.nix" --check >/dev/null 2>&1; then
      fail "extract.py --check called a DRIFTED faithful.nix current -- gate 1 is inert"
    else
      echo "  ok: extract.py --check reports drift"
    fi
    # `--input` stays the COMMITTED faithful surface: mutating the input could
    # make normalize.py raise UnrecognizedShape (exit 2) instead of reporting
    # drift, and a non-zero exit for the wrong reason proves nothing.
    if strictdoc-grammar-extract "$extract/normalize.py" \
         --input "$faithful" --output "$TMPDIR/normalized-drifted.nix" --check \
         >/dev/null 2>&1; then
      fail "normalize.py --check called a DRIFTED normalized.nix current -- gate 2 is inert"
    else
      echo "  ok: normalize.py --check reports drift"
    fi

    if [ "$rc" -ne 0 ]; then
      echo "generated grammar surface: STALE" >&2
      exit 1
    fi
    echo "generated grammar surface: current" | tee "$out"
  ''
