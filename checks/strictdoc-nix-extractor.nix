# cspell:ignore PYEOF PYTHONDONTWRITEBYTECODE reqs sdoc
# checks/strictdoc-nix-extractor.nix -- the CI gate for the tree-sitter source
# extractor (dev/scripts/sdoc_extractors/).
#
# Three arms, and the last is the one that matters.
#
# 1. The extractor's contract suite, dev/scripts/test_sdoc_extractors.py. Each
#    negative contract carries its positive control, and all of them run on
#    strictdoc's OWN venv -- the only interpreter here that imports both
#    `strictdoc` and `tree_sitter`, and the one that carries the
#    `SDOC_TS_*_PARSER` variables. That is `strictdocGrammarExtract`, the same
#    runner `ai.strictdoc` puts in the dev shell and hands to every scribe
#    program, so a session and CI exercise one environment.
#
# 1b. The FLIP suite, dev/scripts/test_sdoc_flip.py. Same interpreter, separate
#    file, and it must be invoked separately -- a suite nothing runs is a suite
#    that does not exist. It covers the surface the source-traceability flip
#    added and arm 1 does not touch: the bash kinds, the glob routing table,
#    `NullSourceReader`, the three NAMED extensionless scripts, and the bash
#    sub-grammar injected into Nix indented strings (ids, kinds, absolute line
#    numbers, Nix interpolation excluded from the bash parse, inject_bash off).
#
#    IT ALSO CARRIES THE ONLY DEMONSTRATION THAT AN EXTENSIONLESS SCRIPT YIELDS
#    A FUNCTION ITEM, and that is a property of the repository rather than a
#    shortcut. All three extensionless scripts the manifest names are real
#    files with no shell function in them -- `docs/sdoc/board/serve` offers one
#    variable, the two `checks/fixtures/claude-hooks/` hooks offer nothing --
#    so routing is provable on repository files and the function half is not.
#    The suite's own fixture is what closes that, which is exactly why it has
#    to run somewhere merge-blocking.
#
# 2. A REAL strictdoc export, in a scratch project, with
#    REQUIREMENT_TO_SOURCE_TRACEABILITY ON and `include_source_paths` narrowed
#    to the copied source file.
#
#    ARM 2 EXISTS BECAUSE ARM 1 CANNOT SEE THE FAILURE THAT MATTERS. A forward
#    File relation whose `ID:` resolves to nothing is not an error: strictdoc
#    exits 0, creates no marker, and the relation is absent from both the
#    document page and the source page. An `ELEMENT` the resolver does not know
#    degrades to a whole-file marker just as quietly. So an export that exits 0
#    proves nothing at all, and this arm asserts on the RENDERED source page:
#    every expected requirement present, with its kind label, and the deliberate
#    ghost id ABSENT.
#
#    The ghost is the check's own positive control. Without it, "all five
#    markers rendered" is indistinguishable from a page that renders every
#    requirement in the project regardless of resolution.
#
# THE FEATURE IS NOW ON in the repository's own strictdoc_config.py (operator
# ruling 2026-09-02; the cost that used to rule it out was strictdoc's generic
# textX reader, which the glob manifest no longer reaches). This check keeps
# its own scratch project anyway, and the reason is isolation rather than cost:
# arm 2 asserts on a RENDERED page whose every marker it also authored, and it
# can only do that over a corpus it fully controls. Narrowing has its own
# hazard, recorded in
# docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc -- the
# File-relation resolver's predicate is "was indexed", not "exists" -- which is
# why the scratch project holds exactly one source file and one document.
#
# The scratch config below registers ONE suffix route rather than the glob
# manifest, and that is deliberate for the same reason: arm 2 is a proof about
# the Nix reader's rendered output, over a project with a single `.nix` file in
# it. The manifest itself is arm 1b's subject.
{
  pkgs,
  self,
  strictdocGrammarExtract,
}:
pkgs.runCommand "strictdoc-nix-extractor" {
  nativeBuildInputs = [
    strictdocGrammarExtract
    pkgs.ai.devTools.strictdoc
    pkgs.python3
  ];
} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    export HOME="$TMPDIR"
    # The sources are read-only store paths; without this python tries (and
    # silently fails) to drop a __pycache__ beside each of them.
    export PYTHONDONTWRITEBYTECODE=1

    echo "== 1. the extractor's contract suite =="
    strictdoc-grammar-extract ${self}/dev/scripts/test_sdoc_extractors.py | tee "$out"

    # A SECOND INVOCATION, not a second path appended to the first: each suite
    # is a script with its own `main`, so naming both on one command line would
    # run the first and silently ignore the second.
    echo "== 1b. the source-traceability flip's contract suite ==" | tee -a "$out"
    strictdoc-grammar-extract ${self}/dev/scripts/test_sdoc_flip.py | tee -a "$out"

    echo "== 2. a real export renders the markers, and drops the ghost =="
    project="$TMPDIR/project"
    mkdir -p "$project/src" "$project/docs"
    cp ${self}/dev/scripts/sdoc_extractors/fixtures/mod.nix "$project/src/mod.nix"
    # The document fixture is `reqs.sdoc.fixture`, NOT `reqs.sdoc`, and that is
    # load-bearing -- the same reason checks/doubled-words-fixtures.nix spells
    # its inputs `*.md.fixture`. The repository's strictdoc project root IS the
    # repository root, so every `*.sdoc` anywhere in the tree joins the ONE
    # graph. Committed as `reqs.sdoc`, this document is ingested by `scribe
    # check` and by dev/scripts/file-check.py, where its `PATH: src/mod.nix`
    # relations resolve against the repo root and report four findings against a
    # file that exists only in the scratch project below. Renaming it back
    # reintroduces exactly that. Copy it into place under its real name here,
    # which is the only place it is a document.
    cp ${self}/dev/scripts/sdoc_extractors/fixtures/reqs.sdoc.fixture \
      "$project/docs/reqs.sdoc"

    # The scratch config: the repository's reader, with the feature ON. Written
    # here rather than committed because it exists only to prove the reader, and
    # a second committed config is a second thing obliged to agree.
    # The heredoc body sits at the block's MINIMUM indentation on purpose. Nix
    # strips the common prefix from an indented string, so these lines reach python
    # at column 0 while the shell around them keeps its indent; a heredoc
    # otherwise preserves leading whitespace and python would raise
    # IndentationError on the first line. Do not "fix" the alignment.
    cat > "$project/strictdoc_config.py" <<PYEOF
  import sys
  from strictdoc.api import ProjectConfig

  sys.path.insert(0, "${self}/dev/scripts")

  from sdoc_extractors.nix import NIX_KIND_ELEMENTS, nix_extractor
  from sdoc_extractors.register import (
      register_forward_descriptions,
      register_readers,
  )
  from sdoc_extractors.strictdoc_reader import make_reader_factory

  _FACTORY = make_reader_factory(
      nix_extractor(path_root="$project"), NIX_KIND_ELEMENTS
  )
  register_readers({".nix": lambda tags=None: _FACTORY(tags)})
  register_forward_descriptions()


  def create_config() -> ProjectConfig:
      return ProjectConfig(
          project_title="nix extractor gate",
          project_features=["REQUIREMENT_TO_SOURCE_TRACEABILITY"],
          include_doc_paths=["/docs/**"],
          include_source_paths=["/src/**"],
      )
  PYEOF

    # strictdoc's own CLI, not the runner: the `SDOC_TS_*_PARSER` variables are
    # set on the runner's wrapper, so hand them over explicitly. That
    # indirection is the whole delivery seam
    # (packages/strictdoc-grammar/lib/mkExtract.nix) and reading them off the
    # runner here is what keeps ONE pinned grammar per language in play.
    #
    # Enumerated rather than named one by one: the Nix extractor INJECTS the
    # bash one into every indented Nix string, so it needs SDOC_TS_BASH_PARSER
    # too, and a third language would need a third line. Reading whatever the
    # wrapper carries means adding a grammar stays one row in
    # packages/strictdoc-grammar/lib/tsGrammars.nix.
    eval "$(strictdoc-grammar-extract -c '
    import os
    for key, value in sorted(os.environ.items()):
        if key.startswith("SDOC_TS_") and key.endswith("_PARSER"):
            print(f"export {key}={value}")
    ')"

    strictdoc export "$project" --formats=html,json \
      --output-dir "$TMPDIR/out" > "$TMPDIR/export.log" 2>&1 \
      || { cat "$TMPDIR/export.log" >&2; exit 1; }

    page="$TMPDIR/out/html/_source_files/src/mod.nix.html"
    python3 ${self}/dev/scripts/sdoc_extractors/fixtures/assert_page.py "$page" \
      | tee -a "$out"
''
