# cspell:ignore PYTHONDONTWRITEBYTECODE
# checks/strictdoc-grammar-model-equal.nix -- acceptance items 4 and 5 of
# SLICE-GRAMMAR-FROM-NIX (packages/strictdoc-grammar/docs/implementation-brief.md).
#
# The `.sgra` this repository's five node types render to must be the same
# grammar as the committed `docs/sdoc/grammar.sgra`. Two gates, and they are
# NOT the same gate:
#
#   SEMANTIC equality is the correctness gate -- both files are read through
#     `SDocGrammarReader.read` and the two object graphs are walked. A rendered
#     file differing in whitespace or key order but parsing to the same model
#     is correct.
#   BYTE identity is the regression gate. It catches a canonical-form change
#     the model comparison cannot see, and it is the weaker of the two: a file
#     matching byte for byte but parsing to something else would still be
#     wrong.
#
# THE RENDER HAPPENS IN NIX EVALUATION, not in a `nix eval` subprocess. The
# surface is a set of `lib.types`, so evaluating it IS the type check
# (`lib/check.nix` runs the values through `evalModules` before the emitter
# ever sees them). A value that cannot type-check therefore fails this check at
# evaluation, before a derivation is built at all -- which is the intended
# review surface for this milestone.
#
# POSITIVE CONTROL. "models equal" is only worth something if the comparator
# can say otherwise, and a comparator that returned 0 unconditionally would
# make both gates above pass forever. It is therefore also run over two
# grammars that really differ -- the committed one and `fixtures/foreign.sgra`
# -- and required to report them as differing.
{
  lib,
  pkgs,
  self,
}: let
  grammarDir = "${self}/packages/strictdoc-grammar";

  grammar = import "${grammarDir}/lib" {inherit lib;};

  rendered =
    pkgs.writeText "grammar-rendered.sgra"
    (grammar.render (import "${grammarDir}/values.nix" {inherit (grammar) dsl;}));
in
  pkgs.runCommand "strictdoc-grammar-model-equal" {
    nativeBuildInputs = [pkgs.ai.devTools.strictdoc-grammar-extract];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    export HOME="$TMPDIR"
    export PYTHONDONTWRITEBYTECODE=1

    compare=${grammarDir}/extract/compare.py
    committed=${self}/docs/sdoc/grammar.sgra
    foreign=${grammarDir}/fixtures/foreign.sgra

    rc=0
    fail() { echo "  FAIL: $*" >&2; rc=1; }

    echo "== correctness: the rendered grammar parses to the committed model =="
    strictdoc-grammar-extract "$compare" "$committed" ${rendered} \
      || fail "values.nix renders a DIFFERENT grammar than docs/sdoc/grammar.sgra"

    echo "== regression: byte identity against docs/sdoc/grammar.sgra =="
    if diff -u "$committed" ${rendered}; then
      echo "  ok: byte-identical"
    else
      fail "byte diff against docs/sdoc/grammar.sgra (shown above)"
    fi

    echo "== positive control: the comparator separates two different grammars =="
    if strictdoc-grammar-extract "$compare" "$committed" "$foreign" >/dev/null 2>&1; then
      fail "compare.py called two DIFFERENT grammars equal -- the semantic gate is inert"
    else
      echo "  ok: compare.py reports the difference"
    fi

    if [ "$rc" -ne 0 ]; then
      echo "rendered grammar: DIVERGED from docs/sdoc/grammar.sgra" >&2
      exit 1
    fi
    echo "rendered grammar: model-equal and byte-identical" | tee "$out"
  ''
