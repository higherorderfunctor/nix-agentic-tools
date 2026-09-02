# cspell:ignore dlopens reqifz
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

A fifth thing is REGISTERED here rather than configured: the `.nix` source
reader (dev/scripts/sdoc_extractors/). strictdoc has no plugin point for a
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

REGISTERING A READER IS NOT TURNING THE FEATURE ON. With
REQUIREMENT_TO_SOURCE_TRACEABILITY absent from the config below, and
dev/scripts/sdoc_model.py passing skip_source_files=True, no source file is
read at all and this patch is inert. Both stay as they are: the ~11 s that
feature costs on this corpus is a separate examination. The strictdoc-native
proof of the reader runs from a SCRATCH copy of this config with the feature
on and include_source_paths narrowed -- and narrowing has its own hazard,
because the File-relation resolver's predicate is "was indexed", not "exists",
so a File relation to a path outside include_source_paths becomes a hard error
(docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc).
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
    from sdoc_extractors.nix import NIX_KIND_ELEMENTS, nix_extractor  # noqa: E402
    from sdoc_extractors.register import (  # noqa: E402
        register_forward_descriptions,
        register_readers,
    )
    from sdoc_extractors.strictdoc_reader import (  # noqa: E402
        make_reader_factory,
    )
except ImportError as error:
    # LOUD ON PURPOSE, and not silently skipped. This config is NOT
    # self-contained: it needs dev/scripts/sdoc_extractors/ beside it. A
    # corpus that copies the config alone -- a test fixture, a scratch export
    # -- dies here, inside strictdoc, with a message that names the cause
    # rather than a bare ModuleNotFoundError.
    #
    # Degrading to "register nothing" would be worse than failing: with the
    # traceability feature on, an unregistered `.nix` reader makes every File
    # relation naming a Nix item resolve to nothing, and strictdoc reports
    # THAT as success (exit 0, no marker, relation absent from every page).
    # A copier must carry dev/scripts/, as dev/scripts/test_scribe_rpc.py's
    # CORPUS_PATHS does.
    raise ImportError(
        "strictdoc_config.py: cannot import the .nix source reader from "
        f"{_DEV_SCRIPTS!r} ({error}). This config is not self-contained -- a "
        "copy of it must carry dev/scripts/ too."
    ) from error

# A one-slot cache rather than a module global plus `global`: the extractor
# dlopens a grammar and compiles every query, so it is built once, on the
# first `.nix` file, and never when the feature is off.
_NIX_READER_FACTORY: list = []


def _nix_reader(source_node_tags=None):
    if not _NIX_READER_FACTORY:
        _NIX_READER_FACTORY.append(
            make_reader_factory(
                nix_extractor(path_root=str(_REPO_ROOT)),
                NIX_KIND_ELEMENTS,
            )
        )
    return _NIX_READER_FACTORY[0](source_node_tags)


register_readers({".nix": _nix_reader})

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
    )
