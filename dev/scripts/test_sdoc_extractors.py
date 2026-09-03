#!/usr/bin/env python3
# cspell:ignore attrpath attrset reqs sdoc uids
"""Contracts for dev/scripts/sdoc_extractors/ (the tree-sitter source extractor).

    strictdoc-grammar-extract dev/scripts/test_sdoc_extractors.py

THE INTERPRETER MATTERS. This must run on strictdoc's OWN venv -- the only one
in this repository that imports both `strictdoc` and `tree_sitter` -- which is
what the `strictdoc-grammar-extract` wrapper is. A plain `python3` fails on the
first import, and `devenv shell -- python3 -c "import strictdoc"` fails too.
That wrapper is also where `SDOC_TS_NIX_PARSER` is set, so no argument is
needed for the grammar.

EVERY NEGATIVE CONTRACT CARRIES ITS POSITIVE CONTROL. A checker that returns
"clean" unconditionally passes a suite of green assertions, so each rule that
is supposed to REJECT something is shown accepting the sound version first.
The ones worth naming, because each was a real defect during implementation:

* the module query capturing `source_code` rather than the lambda, which put
  `line_end` one past EOF and killed an export with a bare `error: 25`;
* a file-header comment that also sits above the first item being parsed
  TWICE, which rendered one requirement as two identical range pointers;
* `attr_identifier`, the node type the shipped grammar's own `locals.scm`
  spells and this grammar build does not have.

The repository files this reads are REAL, not fixtures, and the ids asserted
are the ones an operator would type into a File relation's `ID:` field.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sdoc_extractors.nix import (  # noqa: E402
    BINDING_QUERY,
    NIX_ELEMENT_QUERIES,
    NIX_KIND_ELEMENTS,
    NIX_PARSER_ENV,
    OPTION_QUERY,
    load_nix_language,
    make_nix_id_of,
    nix_extractor,
)
from sdoc_extractors import registry  # noqa: E402
from sdoc_extractors.register import (  # noqa: E402
    register_forward_descriptions,
    register_readers,
)
from sdoc_extractors.strictdoc_reader import (  # noqa: E402
    TreeSitterSourceReader,
    make_reader_factory,
)
from sdoc_extractors.tree_sitter_extractor import (  # noqa: E402
    ExtractorError,
    TreeSitterExtractor,
    find_item,
)

# The WRITE-TIME half of id validation. It lives in the one write path rather
# than here, so this suite reaches for it rather than restating the rule --
# the refusal an operator meets is the one under test.
from sdoc_model import SdocError, check_file_item  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURES = Path(__file__).resolve().parent / "sdoc_extractors" / "fixtures"

# THE SAME BYTES checks/strictdoc-nix-extractor.nix exports through strictdoc.
# One fixture, so the unit contracts and the rendered-page assertions cannot
# drift apart. `MODULE_PATH` is the path it is read UNDER, which is what the
# module item's identifier is; it matches the `PATH:`/`ID:` in
# fixtures/reqs.sdoc.fixture (named `.fixture` so the repository-rooted
# strictdoc project does not ingest it as a real document -- see
# checks/strictdoc-nix-extractor.nix).
MODULE_FIXTURE = (FIXTURES / "mod.nix").read_bytes()
MODULE_PATH = "src/mod.nix"

HELPER_FIXTURE = b"""{foo, bar}: {
  helper = foo.id bar;
}
"""

PASSED: list = []


def contract(name: str):
    def wrap(function):
        def run():
            function()
            PASSED.append(name)
            print(f"  ok  {name}")

        run.contract_name = name
        return run

    return wrap


def items_of(source: bytes, path: str = MODULE_PATH, **kwargs) -> list:
    return nix_extractor(**kwargs).extract(source, path)


def by_id(items: list, identifier: str):
    return find_item(items, identifier)


# ── the extractor core ───────────────────────────────────────────────────


@contract("three kinds are extracted, most specific first")
def test_kinds() -> None:
    items = items_of(MODULE_FIXTURE)
    kinds = {item.identifier: item.kind for item in items}
    assert kinds[MODULE_PATH] == "module", kinds
    assert kinds["options.services.foo.enable"] == "option", kinds
    assert kinds["options.services.foo.port"] == "option", kinds
    # POSITIVE CONTROL for the precedence rule: a binding that is NOT an
    # option must still be reported, as a binding.
    assert kinds["config.systemd.services.foo.script"] == "binding", kinds
    assert kinds["options.services.foo.port.type"] == "binding", kinds


@contract("declaration order decides precedence, and reversing it proves it")
def test_precedence_is_real() -> None:
    # The catch-all first: every option now reports as a binding. Without this
    # control, "option wins" is indistinguishable from "the option query never
    # fires at all".
    reversed_order = TreeSitterExtractor(
        language=load_nix_language(),
        element_queries={
            "binding": BINDING_QUERY,
            "option": OPTION_QUERY,
        },
        id_of=make_nix_id_of(),
    )
    kinds = {
        item.identifier: item.kind
        for item in reversed_order.extract(MODULE_FIXTURE, MODULE_PATH)
    }
    assert kinds["options.services.foo.enable"] == "binding", kinds
    # ... and the shipped order gives the opposite answer on the same bytes.
    shipped = {
        item.identifier: item.kind for item in items_of(MODULE_FIXTURE)
    }
    assert shipped["options.services.foo.enable"] == "option", shipped


@contract("a module item's line_end never runs past EOF")
def test_line_end_clamped() -> None:
    total = len(MODULE_FIXTURE.splitlines())
    module = by_id(items_of(MODULE_FIXTURE), MODULE_PATH)
    assert module is not None
    assert module.line_end <= total, (module.line_end, total)
    # POSITIVE CONTROL: it is not clamped to something uselessly small either
    # -- the module really does span to the last line.
    assert module.line_end == total, (module.line_end, total)


@contract("a lambda whose formals name no module argument is not a module")
def test_helper_is_not_a_module() -> None:
    kinds = {item.kind for item in items_of(HELPER_FIXTURE, "src/helper.nix")}
    assert "module" not in kinds, kinds
    # POSITIVE CONTROL: the same file still yields its binding.
    assert "binding" in kinds, kinds


@contract("a comment above the FIRST binding of a set is attached")
def test_first_binding_comment() -> None:
    items = items_of(MODULE_FIXTURE)
    enable = by_id(items, "options.services.foo.enable")
    assert enable is not None and enable.has_comment, enable
    assert "REQ-ENABLE" in enable.comment_text
    # The item's own line_begin excludes the comment; the marker line does not.
    assert enable.line_begin_with_comment < enable.line_begin, enable
    # NEGATIVE: a comment with a blank line under it documents something else.
    config = by_id(items, "config")
    assert config is not None and not config.has_comment, config


@contract("quoted Nix attributes keep their quotes in the identifier")
def test_quoted_attrpath() -> None:
    source = (REPO_ROOT / "dev/tasks/generate.nix").read_bytes()
    items = items_of(source, "dev/tasks/generate.nix")
    assert by_id(items, 'tasks."generate:devenv-yaml"') is not None
    assert by_id(items, 'tasks."build:all".exec') is not None
    # POSITIVE CONTROL for the negative below: an unquoted id resolves.
    assert by_id(items, "tasks") is not None
    # NEGATIVE: the quote-stripped spelling is NOT the id. A File relation
    # written that way would be dropped silently by strictdoc.
    assert by_id(items, "tasks.generate:devenv-yaml") is None


@contract("real repository files yield the ids the plans point at")
def test_repository_targets() -> None:
    cases = {
        "packages/strictdoc-grammar/modules/devenv/default.nix": [
            "config.processes.scribe",
            "config.processes.scribe.exec",
            "options.ai.strictdoc.enable",
        ],
        "packages/strictdoc-grammar/values.nix": ["governedBy"],
    }
    for relative, identifiers in cases.items():
        items = items_of((REPO_ROOT / relative).read_bytes(), relative)
        for identifier in identifiers:
            assert by_id(items, identifier) is not None, (relative, identifier)


@contract("a malformed query fails at CONSTRUCTION, naming the kind")
def test_bad_query_raises() -> None:
    # `attr_identifier` is the trap: the grammar's own locals.scm spells it and
    # this build has no such node type.
    try:
        TreeSitterExtractor(
            language=load_nix_language(),
            element_queries={
                "bogus": "(attrpath attr: (attr_identifier) @item.node)"
            },
        )
    except ExtractorError as error:
        assert "bogus" in str(error), error
    else:
        raise AssertionError("a query naming a nonexistent node type compiled")
    # POSITIVE CONTROL: the same shape with the REAL node type compiles.
    TreeSitterExtractor(
        language=load_nix_language(),
        element_queries={"ok": "(attrpath attr: (identifier) @item.node)"},
    )


@contract("a query with no @item.node capture is rejected")
def test_missing_item_capture() -> None:
    try:
        TreeSitterExtractor(
            language=load_nix_language(),
            element_queries={"nameless": "(binding) @something.else"},
        )
    except ExtractorError as error:
        assert "item.node" in str(error), error
    else:
        raise AssertionError("a query with no @item.node capture compiled")


@contract("a missing grammar fails loudly, naming the environment variable")
def test_missing_grammar() -> None:
    try:
        nix_extractor(parser_path="/nonexistent/parser")
    except ExtractorError as error:
        assert "/nonexistent/parser" in str(error), error
    else:
        raise AssertionError("a nonexistent parser path loaded")


# ── wrappers: one item, the outer one, with its comment ──────────────────
#
# THE MOTIVATING GRAMMAR IS NOT NIX. TypeScript wraps a `function_declaration`
# in an `export_statement`, so an honest query set matches one declaration
# twice at two different ranges, and the comment sits above the WRAPPER. No
# TypeScript grammar is delivered here -- mkExtract.nix ships tree-sitter-nix
# alone, and delivering a second grammar to prove a language-AGNOSTIC rule is
# a poor trade -- so the same SHAPE is built out of Nix:
# `alpha = with lib; 1;` puts a `with_expression` inside a `binding`, which is
# nested ranges with a keyword token in front of the inner node. That is
# structurally what `export function foo() {}` is.
#
# These queries are TEST-ONLY. Nothing in nix.py matches a `with_expression`,
# and nothing should: what is under test is the shared machinery, not the Nix
# item set.

WRAPPED_FIXTURE = b"""{
  # documents alpha
  alpha = with lib; 1;
  beta = 2;
}
"""

#: The inner node -- preceded by an `=` token, so its `prev_sibling` is
#: neither None nor a comment. This is the shape that used to yield no comment
#: at all, because the ascent only ran while `prev_sibling is None`.
INNER_QUERY = """
(binding
  attrpath: (attrpath) @item.name
  expression: (with_expression) @item.node)
"""

#: The whole binding: the OUTER range, and the one whose `prev_sibling` is the
#: comment.
OUTER_QUERY = "(binding attrpath: (attrpath) @item.name) @item.node"


def wrapped_extractor(element_queries) -> TreeSitterExtractor:
    return TreeSitterExtractor(
        language=load_nix_language(),
        element_queries=element_queries,
        # The DEFAULT id_of, not the Nix one: both patterns capture the same
        # `@item.name`, so both items answer to `alpha` and the containment
        # rule has something to collapse. `make_nix_id_of` walks parents from
        # the item node instead, which would give the two different ids.
        id_of=None,
    )


@contract("a wrapper and what it wraps collapse to ONE item, the outer one")
def test_wrapper_collapses_to_the_outer_item() -> None:
    items = wrapped_extractor(
        {"thing": OUTER_QUERY + "\n" + INNER_QUERY}
    ).extract(WRAPPED_FIXTURE, "src/wrapped.nix")
    alpha = [item for item in items if item.identifier == "alpha"]
    assert len(alpha) == 1, [(i.byte_begin, i.byte_end) for i in alpha]
    # The OUTER range: the whole binding, not the `with lib; 1` inside it.
    span = WRAPPED_FIXTURE[alpha[0].byte_begin : alpha[0].byte_end]
    assert span == b"alpha = with lib; 1;", span
    # ... and the outer item carries the comment, which is the whole reason to
    # prefer it over the inner one.
    assert alpha[0].has_comment, alpha[0]
    assert "documents alpha" in alpha[0].comment_text, alpha[0]


@contract("BOTH wrapper patterns really fire -- the collapse is not a miss")
def test_wrapper_collapse_is_not_a_missed_query() -> None:
    """POSITIVE CONTROL for the contract above.

    "one item" is exactly what a query set that never matched twice would also
    produce. Split the SAME two patterns across two kinds and the containment
    rule cannot apply -- same id, different kind -- so both matches are
    reported. Two here proves the collapse above collapsed something real.
    """
    items = wrapped_extractor(
        {"outer": OUTER_QUERY, "inner": INNER_QUERY}
    ).extract(WRAPPED_FIXTURE, "src/wrapped.nix")
    alpha = sorted(
        (item.kind, item.byte_begin)
        for item in items
        if item.identifier == "alpha"
    )
    assert [kind for kind, _ in alpha] == ["inner", "outer"], alpha
    assert alpha[0][1] > alpha[1][1], alpha  # the inner one starts later


@contract("a comment above a WRAPPER reaches the item inside it")
def test_comment_found_above_a_wrapper() -> None:
    items = wrapped_extractor({"inner": INNER_QUERY}).extract(
        WRAPPED_FIXTURE, "src/wrapped.nix"
    )
    assert len(items) == 1, items
    # The item is the INNER node -- it starts after `alpha = ` -- and the
    # comment is two levels up.
    assert items[0].has_comment, items[0]
    assert "documents alpha" in items[0].comment_text, items[0]
    assert items[0].line_begin_with_comment < items[0].line_begin, items[0]


@contract("the ascent does not steal a file-header comment for the first item")
def test_ascent_stops_at_the_braces() -> None:
    """NEGATIVE CONTROL for the ascent, and the reason a single-child wrapper
    is `child_count == 1` rather than `named_child_count == 1`.

    A Nix `attrset_expression` has ONE named child -- its `binding_set` --
    plus two braces. Ascending through anything with a single NAMED child
    walks out of the braces and hands the file's own header comment to the
    set's first binding, which then renders as a second identical marker for
    a comment that documents the file.
    """
    source = b"""# documents the file, not alpha
{
  alpha = 1;
}
"""
    plain = TreeSitterExtractor(
        language=load_nix_language(),
        element_queries={"binding": BINDING_QUERY},
        id_of=make_nix_id_of(),
    )
    items = plain.extract(source, "src/header.nix")
    assert [item.identifier for item in items] == ["alpha"], items
    assert not items[0].has_comment, items[0].comment_text
    # POSITIVE CONTROL: the same extractor DOES attach a comment that really
    # does sit directly above a binding, so the assertion above is not merely
    # "comments never attach".
    wrapped = plain.extract(WRAPPED_FIXTURE, "src/wrapped.nix")
    assert by_id(wrapped, "alpha").has_comment, wrapped


# ── the glob registry ────────────────────────────────────────────────────


@contract("globs decide what is parsed, and `*` never crosses a slash")
def test_registry_globs() -> None:
    assert registry.matching_glob("flake.nix", REPO_ROOT) == "**/*.nix"
    assert registry.matching_glob("a/b/c/mod.nix", REPO_ROOT) == "**/*.nix"
    # NEGATIVE: an uncovered extension is claimed by nothing.
    assert registry.matching_glob("dev/scripts/sdoc_cli.py", REPO_ROOT) is None
    # `*` is segment-local: `*.nix` must not swallow a directory separator,
    # which is exactly what `fnmatch.translate` would do here.
    assert registry.matches_glob("*.nix", "flake.nix")
    assert not registry.matches_glob("*.nix", "a/flake.nix")


@contract("an uncovered path raises UnsupportedPath naming the configured globs")
def test_registry_refuses_an_uncovered_path() -> None:
    try:
        registry.items_of(
            REPO_ROOT / "dev/scripts/sdoc_cli.py", path_root=REPO_ROOT
        )
    except registry.UnsupportedPath as error:
        assert "sdoc_cli.py" in str(error), error
        assert "**/*.nix" in str(error), error
    else:
        raise AssertionError("a .py file was parsed by the nix extractor")
    # POSITIVE CONTROL: a covered path in the same tree resolves.
    items = registry.items_of(FIXTURES / "mod.nix", path_root=REPO_ROOT)
    assert any(item.kind == "option" for item in items), items


@contract("the registry re-reads a file that changed under it")
def test_registry_cache_keys_on_the_stat() -> None:
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "mod.nix"
        target.write_bytes(b"{ alpha = 1; }\n")
        first = registry.items_of(target, path_root=directory)
        assert [item.identifier for item in first] == ["alpha"], first
        target.write_bytes(b"{ alpha = 1; beta = 2; }\n")
        second = registry.items_of(target, path_root=directory)
        assert [item.identifier for item in second] == ["alpha", "beta"], second


@contract("a near-miss id is answered with the ids it most likely meant")
def test_registry_suggests_nearest_ids() -> None:
    items = registry.items_of(FIXTURES / "mod.nix", path_root=REPO_ROOT)
    nearest = registry.nearest_ids(items, "options.services.foo.por")
    assert "options.services.foo.port" in nearest, nearest
    # NEGATIVE: an id resembling nothing suggests nothing, rather than padding
    # the message with the file's first few items.
    assert registry.nearest_ids(items, "zzzz.nothing.like.it") == []


# ── the write-time refusal ───────────────────────────────────────────────


@contract("a File relation whose ID names no item is refused at WRITE time")
def test_write_time_refusal() -> None:
    """`scribe relate --element function --id this.does.not.exist` used to
    write and exit 0. strictdoc drops an unresolvable forward id silently, so
    that is precisely the failure the corpus cannot show afterwards."""
    fixture = "dev/scripts/sdoc_extractors/fixtures/mod.nix"
    try:
        check_file_item(REPO_ROOT, fixture, "options.services.foo.ghost")
    except SdocError as error:
        assert "ghost" in str(error), error
        # The message has to be actionable, not merely a refusal.
        assert "options.services.foo.port" in str(error), error
    else:
        raise AssertionError("a ghost id was accepted")
    # POSITIVE CONTROL: the real id passes, so the refusal above is about THIS
    # id rather than about element-grained relations in general.
    check_file_item(REPO_ROOT, fixture, "options.services.foo.port")
    # NEGATIVE: a path no glob covers cannot carry an id at all, and the
    # message names the globs that do exist.
    try:
        check_file_item(REPO_ROOT, "dev/scripts/sdoc_cli.py", "main")
    except SdocError as error:
        assert "**/*.nix" in str(error), error
    else:
        raise AssertionError("an id on an uncovered path was accepted")


# ── the strictdoc adapter ────────────────────────────────────────────────


@contract("the reader emits LanguageItems whose description carries the kind")
def test_reader_descriptions() -> None:
    reader = make_reader_factory(nix_extractor(), NIX_KIND_ELEMENTS)(None)
    info = reader.read(MODULE_FIXTURE, MODULE_PATH)
    names = {item.display_name: item for item in info.functions}
    assert "options.services.foo.enable" in names, sorted(names)
    assert names[MODULE_PATH].sdoc_kind == "module"
    markers = info.ng_map_names_to_markers["options.services.foo.enable"]
    assert [marker.get_description() for marker in markers] == [
        "option options.services.foo.enable"
    ], markers


@contract("a header comment above the first item is parsed ONCE")
def test_header_comment_not_doubled() -> None:
    reader = make_reader_factory(nix_extractor(), NIX_KIND_ELEMENTS)(None)
    info = reader.read(MODULE_FIXTURE, MODULE_PATH)
    req_file = [
        marker for marker in info.markers if "REQ-FILE" in marker.reqs
    ]
    assert len(req_file) == 1, req_file
    # POSITIVE CONTROL: the file-scope marker is still THERE, and still file
    # scope -- deduplicating must not have dropped it.
    assert req_file[0].scope.value == "file", req_file[0]


@contract("ELEMENT stays closed to function and class")
def test_element_vocabulary_closed() -> None:
    assert TreeSitterSourceReader.supported_elements() == [
        "function",
        "class",
    ]
    try:
        TreeSitterSourceReader(
            None,
            extractor=nix_extractor(),
            kind_elements={"module": "module"},
        )
    except ValueError as error:
        assert "ELEMENT" in str(error), error
    else:
        raise AssertionError("a kind was accepted as an ELEMENT value")
    # POSITIVE CONTROL: the shipped map is accepted.
    TreeSitterSourceReader(
        None, extractor=nix_extractor(), kind_elements=NIX_KIND_ELEMENTS
    )


@contract("registration is idempotent and leaves other languages alone")
def test_registration() -> None:
    from strictdoc.backend.sdoc_source_code import reader_registry

    factory = make_reader_factory(nix_extractor(), NIX_KIND_ELEMENTS)
    register_readers({".nix": factory})
    installed = reader_registry.SourceCodeReaderRegistry.get_reader
    assert register_readers({".nix": factory}) is False
    assert reader_registry.SourceCodeReaderRegistry.get_reader is installed

    nix_reader = reader_registry.SourceCodeReaderRegistry.get_reader(
        "a.nix", None, None
    )
    assert isinstance(nix_reader, TreeSitterSourceReader), nix_reader
    # POSITIVE CONTROL: strictdoc's own routing is untouched.
    python_reader = reader_registry.SourceCodeReaderRegistry.get_reader(
        "a.py", None, None
    )
    assert type(python_reader).__name__ == (
        "SourceFileTraceabilityReader_Python"
    ), python_reader


@contract("a forward relation renders the kind, not `function name()`")
def test_forward_description() -> None:
    from strictdoc.backend.sdoc_source_code.models.language_item_marker import (
        RangeMarkerType,
    )
    from strictdoc.core.file_traceability_index import FileTraceabilityIndex

    register_forward_descriptions()
    assert register_forward_descriptions() is False

    reader = make_reader_factory(nix_extractor(), NIX_KIND_ELEMENTS)(None)
    info = reader.read(MODULE_FIXTURE, MODULE_PATH)
    port = next(
        item
        for item in info.functions
        if item.display_name == "options.services.foo.port"
    )
    marker = FileTraceabilityIndex.forward_marker_from_language_item(
        port, RangeMarkerType.FUNCTION, [], None
    )
    assert marker.get_description() == "option options.services.foo.port", (
        marker.get_description()
    )
    # POSITIVE CONTROL: an item with no kind keeps strictdoc's own label.
    del port.sdoc_kind
    plain = FileTraceabilityIndex.forward_marker_from_language_item(
        port, RangeMarkerType.FUNCTION, [], None
    )
    assert plain.get_description() == "function options.services.foo.port()", (
        plain.get_description()
    )


# ── the CLI ──────────────────────────────────────────────────────────────


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(Path(__file__).parent / "sdoc_extractors"), *args],
        capture_output=True,
        text=True,
        check=False,
    )


@contract("the CLI exits 1 on an id no item offers, and 0 on one that exists")
def test_cli_resolves_ids() -> None:
    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "mod.nix"
        target.write_bytes(MODULE_FIXTURE)
        good = run_cli(
            "--root", directory, "--id", "options.services.foo.port", str(target)
        )
        assert good.returncode == 0, (good.returncode, good.stderr)
        assert "option" in good.stdout, good.stdout
        ghost = run_cli(
            "--root", directory, "--id", "options.services.foo.ghost", str(target)
        )
        assert ghost.returncode == 1, (ghost.returncode, ghost.stdout)
        # The SAME sentence the write path refuses with, nearest ids included.
        assert "is not an item of" in ghost.stderr, ghost.stderr
        assert "options.services.foo.port" in ghost.stderr, ghost.stderr


@contract("the CLI routes a path through SOURCE_EXTRACTORS, not a default")
def test_cli_routes_by_path() -> None:
    """It used to carry `LANGUAGES = {"nix": ...}` and default `--language`
    to nix, so it PARSED A BASH SCRIPT WITH THE NIX GRAMMAR: listing one
    printed a fabricated item and exited 0, and `--id` on a real bash
    function answered "no such item ... would be dropped SILENTLY by
    strictdoc" for an id the write path accepts. The tool the refusal
    messages send you to was the one that was wrong."""
    script = REPO_ROOT / "lib/validate-at-stop.sh"
    listed = run_cli("--root", str(REPO_ROOT), "--json", str(script))
    assert listed.returncode == 0, (listed.returncode, listed.stderr)
    records = json.loads(listed.stdout)
    functions = {
        record["id"] for record in records if record["kind"] == "function"
    }
    assert {"get", "diff_quiet"} <= functions, sorted(functions)
    # POSITIVE CONTROL: the .nix row still routes to the Nix extractor, so
    # the assertion above is about ROUTING and not about one grammar winning.
    module = run_cli(
        "--root",
        str(REPO_ROOT),
        "--json",
        str(REPO_ROOT / "packages/strictdoc-grammar/modules/devenv/default.nix"),
    )
    assert module.returncode == 0, module.stderr
    kinds = {record["kind"] for record in json.loads(module.stdout)}
    assert "binding" in kinds, sorted(kinds)


@contract("the CLI and the write path agree about what a file offers")
def test_cli_agrees_with_the_write_path() -> None:
    """Two answers to "is this id an item of that file?" is the whole failure
    mode this table exists to prevent, and it is silent in the direction that
    matters: strictdoc drops an unresolvable forward id with exit 0."""
    script = "lib/validate-at-stop.sh"
    accepted = run_cli("--root", str(REPO_ROOT), "--id", "diff_quiet",
                       str(REPO_ROOT / script))
    assert accepted.returncode == 0, accepted.stderr
    check_file_item(REPO_ROOT, script, "diff_quiet")  # must not raise
    # ... and they refuse the same id, too.
    refused = run_cli("--root", str(REPO_ROOT), "--id", "diff_quiet_ghost",
                      str(REPO_ROOT / script))
    assert refused.returncode == 1, refused.stdout
    try:
        check_file_item(REPO_ROOT, script, "diff_quiet_ghost")
    except SdocError:
        pass
    else:
        raise AssertionError("the write path accepted an id the CLI refused")


@contract("an uncovered path is refused by the CLI rather than guessed at")
def test_cli_refuses_an_uncovered_path() -> None:
    result = run_cli(
        "--root", str(REPO_ROOT), str(REPO_ROOT / "dev/scripts/scribe_daemon.py")
    )
    assert result.returncode == 1, (result.returncode, result.stdout)
    assert "no source extractor covers" in result.stderr, result.stderr
    assert "**/*.nix" in result.stderr, result.stderr
    # POSITIVE CONTROL: --language is still an explicit way to probe one.
    forced = run_cli(
        "--root", str(REPO_ROOT), "--language", "nix",
        str(REPO_ROOT / "dev/scripts/scribe_daemon.py"),
    )
    assert forced.returncode == 0, forced.stderr


@contract("the refusal hint names a command that exists")
def test_hint_names_a_real_entry_point() -> None:
    """The hint reaches an operator from the write path AND the CI gate, and
    it used to read `sdoc-extract <path>` -- a command `command -v` does not
    find, because every scribe program is a SCRIPT run by strictdoc's venv
    and this one has no wrapper of its own."""
    assert (REPO_ROOT / registry.LIST_ENTRY_POINT).is_file(), registry.LIST_COMMAND
    message = registry.explain_missing_id(
        FIXTURES / "mod.nix", "nope", [], path_root=REPO_ROOT
    )
    assert registry.LIST_COMMAND in message, message
    assert "sdoc-extract " not in message, message


def main() -> int:
    contracts = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    print(f"{NIX_PARSER_ENV} contracts: {len(contracts)}")
    for check in contracts:
        check()
    print(f"{len(PASSED)} contract(s) passed")
    assert len(PASSED) == len(contracts)
    assert len(NIX_ELEMENT_QUERIES) == 3, NIX_ELEMENT_QUERIES
    return 0


if __name__ == "__main__":
    sys.exit(main())
