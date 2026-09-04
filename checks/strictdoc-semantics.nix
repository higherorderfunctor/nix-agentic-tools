# cspell:ignore PYTHONDONTWRITEBYTECODE sdoc
# checks/strictdoc-semantics.nix -- the CI gate for the state-field semantics
# spike (dev/scripts/sdoc_semantics/).
#
# Two arms, and they answer different questions.
#
# 1. The contract suite, dev/scripts/test_sdoc_semantics.py. Its subject is not
#    "do the machines say what we meant" -- nobody has decided what they mean
#    yet, which is the point of the spike -- but every closed predicate
#    operation, transactional dispatch and ripple, relation contracts, the five
#    eval-time diagnostics, and the `sdoc-semantics/2` payload the board
#    consumes. Every negative contract has a positive fixture beside it.
#
# 2. The CLI, run once, on the REAL grammar. Arm 1 renders through the same
#    functions but never crosses a process boundary, so it cannot see an entry
#    point that fails to resolve its imports -- which is exactly the failure a
#    package run as `-m` from the wrong sys.path anchor produces. One
#    invocation closes that, and it is the invocation the operator types.
#
# THE INTERPRETER IS THE DELIVERY SEAM. `strictdocGrammarExtract` is the wrap
# every scribe program takes as its runner, so running here proves that seam.
# The interpreter itself imports only the standard library.
{
  pkgs,
  self,
  strictdocGrammarExtract,
}:
pkgs.runCommand "strictdoc-semantics" {
  nativeBuildInputs = [strictdocGrammarExtract];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  # The sources are read-only store paths; without this python tries (and
  # silently fails) to drop a __pycache__ beside each of them.
  export PYTHONDONTWRITEBYTECODE=1

  echo "== 1. the semantics contract suite =="
  strictdoc-grammar-extract ${self}/dev/scripts/test_sdoc_semantics.py | tee "$out"

  echo "== 2. the CLI resolves its own imports and renders the real grammar ==" \
    | tee -a "$out"
  strictdoc-grammar-extract ${self}/dev/scripts/sdoc_semantics/__main__.py \
    --root ${self} | tee -a "$out"
''
