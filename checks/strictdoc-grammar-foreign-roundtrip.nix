# cspell:ignore PYTHONDONTWRITEBYTECODE
# checks/strictdoc-grammar-foreign-roundtrip.nix -- acceptance item 7 of
# SLICE-GRAMMAR-FROM-NIX (packages/strictdoc-grammar/docs/implementation-brief.md).
#
# This repository's five node types exercise about HALF the surface. The
# package is general purpose and intended for publication, so the half they
# never touch has to be exercised by something: `fixtures/foreign.nix` carries
# a composite element, a VIEW_STYLE, a field HUMAN_TITLE, a Child relation, a
# File relation with a ROLE, a role-less Parent relation, a Tag field, a
# MultipleChoice field, an element with no PREFIX and no PROPERTIES block, and
# a quoted choice option containing parentheses.
#
# The round trip is: DSL values -> `.sgra` text (in Nix evaluation, through the
# type check) -> strictdoc, which must accept it.
#
# ACCEPTANCE IS AN EXPORT, NOT A PARSE. `SDocValidator` is never called on a
# bare read -- its only callers are the traceability-index build -- so a
# grammar that parses may still be rejected by the rules that matter
# (reverse-role-without-role, SECTION-not-composite, TEXT-composite). A parse
# would be a weaker gate wearing the same green. The export therefore runs over
# a whole throwaway project, in a directory outside the repository, with its
# own fresh `--output-dir`: `strictdoc export` caches under that directory and
# a warm one turns a failing input into exit 0 on the next run, which is
# exactly the false green this check exists to avoid.
#
# The emitted file is also compared against the committed `foreign.sgra`
# semantically and byte for byte, on the same two-gate split as
# ./strictdoc-grammar-model-equal.nix: the model comparison is the correctness
# gate and byte identity is the regression gate.
{
  lib,
  pkgs,
  self,
  strictdocGrammarExtract,
}: let
  grammarDir = "${self}/packages/strictdoc-grammar";

  grammar = import "${grammarDir}/lib" {inherit lib;};

  emitted =
    pkgs.writeText "foreign-rendered.sgra"
    (grammar.render (import "${grammarDir}/fixtures/foreign.nix" {inherit (grammar) dsl;}));
in
  pkgs.runCommand "strictdoc-grammar-foreign-roundtrip" {
    nativeBuildInputs = [
      pkgs.ai.devTools.strictdoc
      strictdocGrammarExtract
    ];
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    export HOME="$TMPDIR"
    export PYTHONDONTWRITEBYTECODE=1

    committed=${grammarDir}/fixtures/foreign.sgra

    rc=0
    fail() { echo "  FAIL: $*" >&2; rc=1; }

    echo "== correctness: the emitted foreign grammar parses to the committed model =="
    strictdoc-grammar-extract ${grammarDir}/extract/compare.py "$committed" ${emitted} \
      || fail "foreign.nix renders a DIFFERENT grammar than fixtures/foreign.sgra"

    echo "== regression: byte identity against fixtures/foreign.sgra =="
    if diff -u "$committed" ${emitted}; then
      echo "  ok: byte-identical"
    else
      fail "byte diff against fixtures/foreign.sgra (shown above)"
    fi

    echo "== round trip: strictdoc exports a project built on the EMITTED grammar =="
    # Outside the repository, because a whole-project export reads every
    # `.sgra` beneath the project root; `IMPORT_FROM_FILE` resolves a bare
    # filename beside the document, so the emitted file is copied in as
    # `g.sgra`.
    project="$TMPDIR/project"
    mkdir -p "$project"
    cp ${emitted} "$project/g.sgra"
    printf '[DOCUMENT]\nTITLE: Foreign round trip\n\n[GRAMMAR]\nIMPORT_FROM_FILE: g.sgra\n' \
      > "$project/d.sdoc"
    if strictdoc export "$project" --formats=json --output-dir "$TMPDIR/out"; then
      echo "  ok: exported, exit 0"
    else
      fail "strictdoc rejected the emitted foreign grammar"
    fi

    if [ "$rc" -ne 0 ]; then
      echo "foreign grammar: did NOT round-trip" >&2
      exit 1
    fi
    echo "foreign grammar: round-trips (model-equal, byte-identical, exports clean)" | tee "$out"
  ''
