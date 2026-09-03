# cspell:ignore dlopens reqifz reqs
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

A fifth thing is REGISTERED here rather than configured: the source readers
(dev/scripts/sdoc_extractors/), one per language in the glob manifest. strictdoc has no plugin point for a
language, but `SourceCodeReaderRegistry.get_reader` is resolved AT CALL TIME
by both of its call sites, so reassigning it costs zero package edits -- which
matters, because overlays/dev-tools/strictdoc.nix re-exports upstream's flake
output byte for byte and cache-hit parity depends on that staying true.

It happens at MODULE level, above create_config(), because strictdoc imports
this module before it builds the traceability index. It is IDEMPOTENT and
FAIL-CLOSED (see dev/scripts/sdoc_extractors/register.py), and it costs
nothing measurable: reader_registry is already pulled in by the two formats
imported above -- measured 0.36 s either way -- and the extractor itself,
which dlopens a grammar and compiles its queries, is built lazily on the first
`.nix` file.

  The cost is that THIS FILE IS NO LONGER SELF-CONTAINED: it imports repo
  modules from dev/scripts/. Anything that copies the config elsewhere -- a
  test corpus, a scratch export -- must copy dev/scripts/ with it, which is
  what dev/scripts/test_scribe_rpc.py's CORPUS_PATHS does. The import raises
  with that instruction rather than skipping registration, because a skip is
  invisible: with the traceability feature on, an unregistered `.nix` reader
  turns every File relation naming a Nix item into a silent no-op.

THE FEATURE IS ON, and the reader registry is REPLACED rather than extended.
`registry.SOURCE_EXTRACTORS` (dev/scripts/sdoc_extractors/registry.py) is the
whole manifest: a glob, and the extractor that parses what it matches. It is
NOT declared here, because the write path validates an `ID:` against the same
table. Everything else in the tree is read by
`NullSourceReader` -- no parser, no cost -- and NO INTERNAL STRICTDOC READER IS
EVER REACHED, `.py` and `.rs` included. That is the operator's 2026-09-02
ruling ("i have no ambitions for generic matching at all"), and it is what made
the feature affordable: with strictdoc's generic textX reader in play a cold
export was 15.4 s, 77% of it that reader recompiling its grammar once per file
across ~1300 files.

WHAT IT COSTS, MEASURED RATHER THAN ASSUMED. Wall clock over this corpus
(1397 indexed source files, JSON format, one machine, one method):

              cold                     warm
    off       2.39 / 2.42 s            2.18 / 2.20 / 2.21 s
    on        9.69 / 9.88 s            2.82 / 2.82 / 2.84 s

So the flip costs about +0.64 s, roughly +29%, on EVERY export -- a standing
cost, not a first-run one. Phase timers split it into +0.47 s inside the index
build (0.30 s uncached directory walk, 0.10 s of PickleCache stat-and-unpickle
across 1397 files, 0.03 s relation resolution) and +0.20 s inside the export
phase itself.

THAT MISSES THE BAR THIS WORK WAS PLANNED AGAINST, and the bar was derived from
a measurement that could not have shown it. The profiling note recorded "on,
warm 2.30 s" beside a 2.31 s baseline, from which "warm must stay at ~2.3 s"
was written. Its own text says every feature-on run exited 1 on
docs/sdoc/board/assets/board.js (NUL bytes, fixed since in 3affe78b). That
failure is raised inside `validate_and_resolve`, which runs INSIDE the index
build -- so those runs stopped before the export phase, while the baseline they
were compared against ran it in full. Measured here, that phase is 0.29 s of a
feature-on run against 0.09 s of a feature-off one, which is about half the
gap; the rest is not attributed, and the note's corpus (1368 files, an rsync
copy under /tmp) is not this one. The lesson is narrower than "the bar was
wrong": A RUN THAT FAILS INSIDE THE INDEX BUILD IS NOT A TIMING OF AN EXPORT,
and it reads as one.

No lever is left that does not give something up. The walk is strictdoc's own
and is uncached by design; the per-file cache read is what makes the cold
export 9.7 s instead of 15.4 s; and the one remaining reduction -- narrowing
what is INDEXED -- is exactly what the next paragraph forbids, because it turns
every whole-file relation to a pruned path into a hard error. A caller that
needs none of this passes `skip_source_files=True`, as dev/scripts/sdoc_model.py
does for the scribe daemon (see the end of this docstring). That flag guards
the whole source block in `traceability_index_builder.create`, so none of the
cost above can reach it: measured, a daemon graph load is 0.69-0.84 s with
this feature on.

One side effect worth knowing, because it is invisible until you look: the walk
calls `mkdir -p` on an `_source_files/<dir>` path per source file, so a bare
`strictdoc export .` now leaves ~400 empty directories under `output/html/`
even for a JSON-only export. `output/` is gitignored, so this is noise rather
than a defect.

GLOBS DECIDE WHAT IS PARSED, NOT WHAT IS INDEXED. The walk is untouched, so
every file still enters the index and a whole-file `TYPE: File` relation to a
`.md` or a `.js` still resolves. Narrowing `include_source_paths` instead would
have broken exactly those: the File-relation resolver's predicate is "was
indexed", not "exists", so a relation to a path outside the include set is a
HARD ERROR (docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc).
`exclude_source_paths` is a different lever and is used below -- it prunes the
WALK, which is why only genuinely uninteresting directories belong in it.

dev/scripts/sdoc_model.py still passes skip_source_files=True for the scribe
daemon's own export, which is a separate decision from this one.
"""

import sys
from pathlib import Path

from strictdoc.api import ProjectConfig
from strictdoc.backend.json.json_format import JSONFormat
from strictdoc.backend.sdoc.sdoc_format import SDocFormat

_REPO_ROOT = Path(__file__).resolve().parent

# dev/scripts/ holds plain modules rather than an installed package, and this
# is the same path every scribe program puts on sys.path. Guarded so a second
# import of this config does not grow sys.path.
_DEV_SCRIPTS = str(_REPO_ROOT / "dev" / "scripts")
if _DEV_SCRIPTS not in sys.path:
    sys.path.insert(0, _DEV_SCRIPTS)

try:
    from sdoc_extractors import registry  # noqa: E402
    from sdoc_extractors.register import (  # noqa: E402
        register_forward_descriptions,
    )
    from sdoc_extractors.strictdoc_reader import (  # noqa: E402
        make_reader_factory,
        register_source_extractors,
    )
except ImportError as error:
    # LOUD ON PURPOSE, and not silently skipped. This config is NOT
    # self-contained: it needs dev/scripts/sdoc_extractors/ beside it. A
    # corpus that copies the config alone -- a test fixture, a scratch export
    # -- dies here, inside strictdoc, with a message that names the cause
    # rather than a bare ModuleNotFoundError.
    #
    # Degrading to "register nothing" would be worse than failing: with the
    # traceability feature on, an unregistered reader makes every File
    # relation naming a source item resolve to nothing, and strictdoc reports
    # THAT as success (exit 0, no marker, relation absent from every page).
    # A copier must carry dev/scripts/, as dev/scripts/test_scribe_rpc.py's
    # CORPUS_PATHS does.
    raise ImportError(
        "strictdoc_config.py: cannot import the source readers from "
        f"{_DEV_SCRIPTS!r} ({error}). This config is not self-contained -- a "
        "copy of it must carry dev/scripts/ too."
    ) from error

# THE MANIFEST LIVES IN dev/scripts/sdoc_extractors/registry.py, not here, and
# that is load-bearing rather than tidy. The same table answers two questions
# that must never diverge: which extractor strictdoc ROUTES a source file to
# (below), and whether an `ID:` a `.sdoc` writes is really an item of that file
# (dev/scripts/element-check.py and the scribe write path). When those two
# disagree the failure is SILENT -- strictdoc drops an unresolvable forward
# `ID:` with exit 0 and no marker.
#
# A reader factory per language, built LAZILY: building an extractor dlopens a
# grammar and compiles every query, so it happens on the first file of that
# language and never at import. `registry.build` holds the extractor cache, so
# the reader below and the write-path verifier share one compiled extractor per
# language.
_FACTORY_CACHE: dict = {}


def _reader_for(spec):
    """A `source_node_tags -> reader` callable over one language's extractor."""

    def reader(source_node_tags=None):
        factory = _FACTORY_CACHE.get(spec.language)
        if factory is None:
            factory = _FACTORY_CACHE[spec.language] = make_reader_factory(
                registry.build(spec, path_root=str(_REPO_ROOT)),
                spec.kind_elements,
            )
        return factory(source_node_tags)

    return reader


#: Directories with nothing to trace, pruned from the WALK rather than filtered
#: after it -- `exclude_source_paths` cuts the traversal at the directory,
#: while `include_source_paths` would filter afterwards and break every
#: whole-file relation outside the include set. `output` and `Output` are
#: pruned by strictdoc itself; they are listed anyway so this reads as the
#: whole answer rather than most of it.
EXCLUDE_SOURCE_PATHS = [
    ".devenv/",
    ".direnv/",
    ".git/",
    ".rumdl_cache/",
    "__pycache__/",
    "node_modules/",
    "output/",
    "Output/",
    "result*/",
    # NOT a build directory, and the one entry here that is about CONTENT.
    # `fixtures/mod.nix` carries BACKWARD `@relation(REQ-..., ...)` markers in
    # its comments, naming requirements that exist only in the scratch project
    # checks/strictdoc-nix-extractor.nix assembles. Read as part of THIS
    # corpus, every one of them is a hard error -- "references a requirement
    # that does not exist" -- and the export exits 1. The same hazard is why
    # the document beside it is committed as `reqs.sdoc.fixture` rather than
    # `reqs.sdoc`; a source fixture has no equivalent rename, so it is pruned
    # here instead.
    "dev/scripts/sdoc_extractors/fixtures/",
]

register_source_extractors(
    {
        glob: _reader_for(spec)
        for glob, spec in registry.SOURCE_EXTRACTORS.items()
    },
    path_root=str(_REPO_ROOT),
)

# A FORWARD File relation's label is generated by strictdoc after the reader is
# finished, so without this the same item that reads `option services.foo.port`
# from a source comment renders `function services.foo.port()` when a `.sdoc`
# points at it. See register.py.
register_forward_descriptions()


def create_config() -> ProjectConfig:
    return ProjectConfig(
        project_title="nix-agentic-tools design graph",
        grammars={"@repo": "docs/sdoc/grammar.sgra"},
        exclude_doc_paths=["*.md", "**/*.md"],
        formats=[SDocFormat(), JSONFormat()],
        dir_for_sdoc_cache="$TMPDIR",
        project_features=["REQUIREMENT_TO_SOURCE_TRACEABILITY"],
        # The repository root, so a File relation's PATH is written the way it
        # is everywhere else in this tree.
        source_root_path=str(_REPO_ROOT),
        exclude_source_paths=EXCLUDE_SOURCE_PATHS,
    )
