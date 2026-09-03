# cspell:ignore dlopens sdoc
"""SOURCE_EXTRACTORS -- which files are PARSED, and by which extractor.

ONE TABLE, EVERY CONSUMER, AND THAT IS THE WHOLE POINT OF THIS MODULE.
There are three of them. `strictdoc_config.py` reads it to route strictdoc's
source reader; the write path (`dev/scripts/sdoc_model.py`) and the CI gate
(`dev/scripts/element-check.py`) read it to answer "is this id really an item
of that file?"; and `cli.py` -- the tool the refusal messages send an operator
to -- reads it to list what a file offers.

A second table is a second thing obliged to agree, and when they disagree the
failure is SILENT: strictdoc drops a forward `ID:` it cannot resolve with exit
0 and no marker, so a relation validated against one table and resolved
against another simply vanishes. MEASURED, and it is why this paragraph now
counts the consumers: `cli.py` kept its own `LANGUAGES = {"nix": ...}` with
`--language` defaulting to nix, so it parsed a bash script with the Nix
grammar and told the operator an id the write path ACCEPTS "would be dropped
SILENTLY by strictdoc". The checker that exists to catch a silent drop was
the thing lying.

── The ruling this implements (operator, 2026-09-02) ────────────────────────

    "i prefer, or rather, require unless there is reason surfaced its a bad
     requirement, that the generic parser be disabled. [...] i'd recommend
     even considering glob matchers (extensionless bash, don't read every
     file and detect). full manifest then filtered by extension, over just
     building the manifest from globs. glob not covered not in scope. i have
     no ambitions for generic matching at all."

So the key is a GLOB, not an extension: an extensionless shell script is the
motivating case, and matching on a suffix cannot express it.

── Globs decide what is PARSED, not what is INDEXED ─────────────────────────

This is the design decision the table's shape encodes, and getting it backwards
breaks whole-file relations. strictdoc's walk still visits every file (measured
0.3 s on this corpus), so a `.md` or `.js` file is still INDEXED and a
whole-file `File` relation to it still resolves. What a glob decides is whether
the file is PARSED: an unmatched file gets a null reader -- no items, no textX,
no cost -- rather than being dropped from the manifest. Filtering the WALK
instead would turn every whole-file relation to an unmatched path into a hard
error, because the File-relation resolver's predicate is "was indexed", not
"exists" (docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc).

That is also why the generic textX reader being disabled costs nothing: it was
77% of a cold export with the feature on (1303 files, grammar recompiled per
file) and it produced items nothing in this corpus names.

── Matching ────────────────────────────────────────────────────────────────

Globs are matched against a REPOSITORY-RELATIVE POSIX path. `**` matches zero
or more whole path segments; `*` and `?` never cross a `/`. Character classes
are NOT supported -- add them here if a real row ever needs one rather than
reaching for `fnmatch`, whose `*` crosses separators and would make
`*.nix` match `a/b.nix`.

Insertion order is precedence: the first glob that matches claims the file.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, Mapping, Optional, Sequence

from .bash import BASH_KIND_ELEMENTS, bash_extractor
from .nix import NIX_KIND_ELEMENTS, nix_extractor
from .tree_sitter_extractor import ExtractedItem, TreeSitterExtractor


#: The entry point that lists a file's items, and the command line that
#: reaches it. QUOTED IN REFUSAL MESSAGES, so it has to be a command that
#: exists: the hint used to read `sdoc-extract <path>`, and there is no
#: `sdoc-extract` on PATH -- `command -v` finds nothing and grepping the tree
#: for it finds only this string and the CLI's own `prog=`. Every scribe
#: program is a SCRIPT run by strictdoc's venv (mkScribe.nix carries the
#: interpreter, not the script), and this one has no wrapper of its own, so
#: the reachable invocation names the runner and the entry point.
LIST_ENTRY_POINT = "dev/scripts/sdoc_extractors/__main__.py"
LIST_COMMAND = f"strictdoc-grammar-extract {LIST_ENTRY_POINT}"


class UnsupportedPath(Exception):
    """No configured glob covers this path, so nothing parses it."""


@dataclass(frozen=True)
class SourceExtractor:
    """One row of the table: a language, how to build it, and its ELEMENTs.

    `build` is the per-language factory (`nix_extractor`), taking
    `parser_path` and `path_root` keywords and returning a
    `TreeSitterExtractor`. It is called LAZILY -- building one dlopens a
    grammar and compiles every query, which must not happen on an import.

    `kind_elements` maps this language's kind words onto strictdoc's closed
    ELEMENT vocabulary; the kind itself is not an ELEMENT value and travels
    to a reader through the item description instead.
    """

    language: str
    build: Callable[..., TreeSitterExtractor]
    kind_elements: Mapping[str, str]


NIX_SOURCE_EXTRACTOR = SourceExtractor(
    language="nix",
    build=nix_extractor,
    kind_elements=NIX_KIND_ELEMENTS,
)

BASH_SOURCE_EXTRACTOR = SourceExtractor(
    language="bash",
    build=bash_extractor,
    kind_elements=BASH_KIND_ELEMENTS,
)

#: glob -> extractor. THE table. A new language is one row here plus its
#: queries module; nothing in `tree_sitter_extractor.py` moves.
#:
#: EXTENSIONLESS SCRIPTS ARE NAMED, NOT SNIFFED. There are three of them and
#: they are listed by path, which is the operator's "glob not covered not in
#: scope" applied literally. Content detection would mean opening all ~1300
#: files in the tree to identify three; a glob that stops matching is a hole a
#: test can assert on, a shebang sniffer that stops matching is a silent
#: full-tree read.
#:
#: Nix rows also cover the shell EMBEDDED in them: `nix_extractor` injects the
#: bash one into every indented Nix string, so a `writeShellApplication`'s
#: functions are items of the `.nix` file with ids like
#: `text::sync_file` and the kind `shell-function`. See nix.py's header.
SOURCE_EXTRACTORS: dict[str, SourceExtractor] = {
    # Nix, with bash injected into its indented strings.
    "**/*.nix": NIX_SOURCE_EXTRACTOR,
    # Bash.
    "**/*.sh": BASH_SOURCE_EXTRACTOR,
    "checks/fixtures/claude-hooks/post-edit": BASH_SOURCE_EXTRACTOR,
    "checks/fixtures/claude-hooks/pre-edit": BASH_SOURCE_EXTRACTOR,
    "docs/sdoc/board/serve": BASH_SOURCE_EXTRACTOR,
}


# ── glob matching ────────────────────────────────────────────────────────


def _segment_regex(segment: str) -> str:
    out = []
    for character in segment:
        if character == "*":
            out.append("[^/]*")
        elif character == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(character))
    return "".join(out)


def _glob_regex(glob: str) -> re.Pattern:
    parts = glob.split("/")
    out = []
    for index, part in enumerate(parts):
        last = index == len(parts) - 1
        if part == "**":
            # Zero or more WHOLE segments. The trailing slash is consumed
            # here rather than emitted below, which is what lets `**/*.nix`
            # match a file at the root as well as one nested any depth down.
            out.append(".*" if last else "(?:[^/]+/)*")
            continue
        out.append(_segment_regex(part) + ("" if last else "/"))
    return re.compile("".join(out) + r"\Z")


_COMPILED: dict[str, re.Pattern] = {}


def matches_glob(glob: str, relative_path: str) -> bool:
    """Does this ONE glob claim this repository-relative path?"""
    pattern = _COMPILED.get(glob)
    if pattern is None:
        pattern = _COMPILED[glob] = _glob_regex(glob)
    return pattern.match(relative_path) is not None


def globs() -> tuple[str, ...]:
    """Every configured glob, in precedence order."""
    return tuple(SOURCE_EXTRACTORS)


def describe_globs() -> str:
    """The configured globs as an error message should name them."""
    return ", ".join(globs()) or "(none configured)"


def relative_to(path, path_root) -> str:
    """`path` as the globs see it: POSIX, relative to the root when it is under it.

    THE UNRESOLVED FORM IS TRIED FIRST, and that ordering is measured rather
    than tidy. A caller builds `root / value` out of a repository-relative
    VALUE, so the plain `relative_to` always succeeds and gives back exactly
    the `value` the corpus wrote. Resolving first breaks that whenever the
    tree contains symlinks -- a scratch corpus built as a symlink farm
    resolves each file back to its original checkout, lands outside the root,
    and falls through to an ABSOLUTE path, which `**/*.nix` cannot match
    (`**` matches whole segments, and a leading `/` makes the first one
    empty). Every `.nix` file then reports as covered by no extractor.
    Resolving stays as the SECOND attempt, for a caller that passes a real
    path from somewhere else.
    """
    candidate = Path(path)
    if path_root:
        root = Path(path_root)
        for base, target in (
            (root, candidate),
            (root.resolve(), candidate.resolve()),
        ):
            try:
                return PurePosixPath(target.relative_to(base)).as_posix()
            except ValueError:
                continue
    return PurePosixPath(candidate).as_posix()


def matching_glob(path, path_root=None) -> Optional[str]:
    """The first configured glob that claims this path, or None."""
    relative_path = relative_to(path, path_root)
    for glob in SOURCE_EXTRACTORS:
        if matches_glob(glob, relative_path):
            return glob
    return None


def extractor_for(path, path_root=None) -> Optional[SourceExtractor]:
    """The row that claims this path, or None when no glob covers it."""
    glob = matching_glob(path, path_root)
    return None if glob is None else SOURCE_EXTRACTORS[glob]


# ── building and running one, at most once each ──────────────────────────

#: (language, path_root, parser_path) -> extractor. Built lazily: a build
#: dlopens a grammar and compiles every query.
_BUILT: dict[tuple, TreeSitterExtractor] = {}

#: (resolved path, mtime_ns, size) -> items. Keyed on the STAT rather than on
#: the path alone, so a file edited between two calls in one process is
#: re-read. That is the adapter's case: the board holds a payload across
#: exports and a source file changes underneath it.
_ITEMS: dict[tuple, list[ExtractedItem]] = {}


def build(
    spec: SourceExtractor,
    *,
    path_root=None,
    parser_path: Optional[str] = None,
) -> TreeSitterExtractor:
    key = (spec.language, str(path_root or ""), parser_path or "")
    extractor = _BUILT.get(key)
    if extractor is None:
        extractor = _BUILT[key] = spec.build(
            parser_path=parser_path, path_root=str(path_root) if path_root else None
        )
    return extractor


def items_of(
    path,
    *,
    path_root=None,
    parser_path: Optional[str] = None,
) -> list[ExtractedItem]:
    """Every item the configured extractor finds in ONE file.

    Raises `UnsupportedPath` when no glob covers it -- which is a different
    answer from "covered, and it has no items", and the two must not be
    conflated: the first means an `ID:` naming this file can never resolve,
    the second means this particular id does not exist.
    """
    spec = extractor_for(path, path_root)
    if spec is None:
        raise UnsupportedPath(
            f"no source extractor covers {relative_to(path, path_root)!r} "
            f"(configured globs: {describe_globs()})"
        )
    resolved = Path(path).resolve()
    stat = resolved.stat()
    key = (str(resolved), stat.st_mtime_ns, stat.st_size)
    items = _ITEMS.get(key)
    if items is None:
        extractor = build(spec, path_root=path_root, parser_path=parser_path)
        items = _ITEMS[key] = extractor.extract(
            resolved.read_bytes(), str(path)
        )
    return items


def item_of(
    path,
    identifier: str,
    *,
    path_root=None,
    parser_path: Optional[str] = None,
) -> Optional[ExtractedItem]:
    """The item `identifier` names in `path`, or None. Raises UnsupportedPath."""
    for item in items_of(
        path, path_root=path_root, parser_path=parser_path
    ):
        if item.display_name == identifier:
            return item
    return None


def nearest_ids(
    items: Iterable[ExtractedItem], identifier: str, limit: int = 5
) -> list[str]:
    """The ids a mistyped one most likely meant.

    Prefix and substring matches FIRST, then difflib. A qualified id is a
    dotted path, and the common miss is a wrong last segment or a dropped
    quote -- both of which share a long prefix and neither of which difflib
    ranks reliably against a corpus of similarly-shaped strings.
    """
    names: list[str] = []
    for item in items:
        if item.display_name not in names:
            names.append(item.display_name)
    lowered = identifier.lower()
    ranked = [
        name
        for name in names
        if name.lower().startswith(lowered) or lowered in name.lower()
    ]
    if len(ranked) < limit:
        import difflib

        for name in difflib.get_close_matches(
            identifier, names, n=limit, cutoff=0.6
        ):
            if name not in ranked:
                ranked.append(name)
    return ranked[:limit]


def explain_missing_id(
    path,
    identifier: str,
    items: Sequence[ExtractedItem],
    *,
    path_root=None,
) -> str:
    """The refusal message for an id no item of `path` offers."""
    relative_path = relative_to(path, path_root)
    nearest = nearest_ids(items, identifier)
    hint = (
        f" Nearest: {', '.join(nearest)}."
        if nearest
        else " Nothing in that file resembles it."
    )
    return (
        f"{identifier!r} is not an item of {relative_path}"
        f" ({len(items)} item(s) offered).{hint}"
        f" List them with: {LIST_COMMAND} {relative_path}"
    )
