# cspell:ignore reqifz
"""StrictDoc project configuration for nix-agentic-tools.

The project root is the repository root so that plan documents under
docs/plans/, settled architecture under **/.sdoc/, and any future
source-extracted nodes all land in ONE graph and can cite each other.

Four things make that work and all four are load-bearing:

* grammars: IMPORT_FROM_FILE accepts only a bare filename resolved next to the
  document, so a nested layout would need a copy of grammar.sgra in every
  directory. Registering an alias here means every document, at any depth,
  writes `IMPORT_FROM_FILE: @repo`.

* exclude_doc_paths: StrictDoc ingests every .md file in the input tree as a
  document. Unfiltered, an export aborts on the first markdown file with no H1
  or with a second H1. The two globs cost nothing measurable and re-arm the
  moment MarkdownFormat is registered again, so they stay as written -- but
  with MarkdownFormat gone below they are no longer what makes an export pass.

* formats (MECH-SDOC-LEAN-FORMATS): exactly SDocFormat and JSONFormat. The
  traceability index build is 3 ms; the cost of every strictdoc command is
  startup, config construction and the format stack that default_formats()
  imports. Measured on this corpus: export 2.02 s to 1.09 s, format 1.50 s to
  0.73 s, manage auto-uid 1.70 s to 0.73 s. `format` and `manage` take no
  --formats flag, so this config is the only lever on their cost, and a second
  config would be two files obliged to agree about the same thing.

  It is also what makes dev/scripts/sdoc_cli.py able to hold strictdoc's
  progress output in a buffer: html2pdf4doc, reached through the default
  format stack, reassigns sys.stdout at IMPORT time and needs a real file
  descriptor, so a captured stdout raised io.UnsupportedOperation before this
  pin existed.

  Instances, not classes: default_formats() returns constructed objects and
  the dispatcher calls read_grammar on the member, so a class here raises a
  missing-self TypeError at load.

  strictdoc.api exports ProjectConfig and no Format class at all, so these two
  come from non-public module paths on an overlay that tracks latest upstream.
  That fails closed: a renamed module exits 1 naming this file and the import
  line, which the two corpus-export gates already run.

  What the repository gives up is exporting html, html2pdf, rst, markdown,
  excel, reqif-sdoc, reqifz-sdoc, doxygen and spdx, and ingesting .md,
  .markdown and .gra.md as documents or grammars. Nothing asks for any of
  them: every check, script, skill recipe and README line passes
  --formats=json. .sgra grammar reading is unaffected -- it comes from
  SDocFormat, which stays.

  The cost is a false green whose shape is narrower than it looks. Asking for
  a handle no registered format claims -- html, rst, markdown, excel, or the
  bare default, which is html -- exits 0 and writes no non-cache file. It is
  confined to OUTPUT: the traceability index is built before any format is
  dispatched, so a corpus with a field-order violation exits 1 under every one
  of those handles. Both existing gates read their output file immediately
  after exporting and die on its absence, so neither can pass on an empty
  export. `sdoc check` is the loud replacement and does not go through a
  format handle at all.

* dir_for_sdoc_cache (MECH-SDOC-CACHE-DIR-FOR-WORKTREES): "$TMPDIR" is a
  SENTINEL, not a shell variable -- strictdoc expands that exact literal to
  <tempfile.gettempdir()>/strictdoc_cache/<md5 of os.getcwd()>/<version>, so
  every worktree gets its own cache outside its own checkout. It covers the
  parse cache written by export, format, manage and server alike, because the
  expansion happens in ProjectConfig.__init__. It does NOT cover the export
  artifact directory: a bare `strictdoc export .` still writes ./output/json,
  so the output/ line in .gitignore stays.

  Do not set STRICTDOC_CACHE_DIR to "fix" a cache path. It is read BEFORE this
  value and asserts it equals exactly "Output/_cache" -- capital O -- so it is
  not a relocation lever, it is a way to undo this line.
"""

from strictdoc.api import ProjectConfig
from strictdoc.backend.json.json_format import JSONFormat
from strictdoc.backend.sdoc.sdoc_format import SDocFormat


def create_config() -> ProjectConfig:
    return ProjectConfig(
        project_title="nix-agentic-tools design graph",
        grammars={"@repo": "docs/sdoc/grammar.sgra"},
        exclude_doc_paths=["*.md", "**/*.md"],
        formats=[SDocFormat(), JSONFormat()],
        dir_for_sdoc_cache="$TMPDIR",
    )
