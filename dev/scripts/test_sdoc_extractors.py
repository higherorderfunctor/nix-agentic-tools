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
        good = run_cli("--id", "options.services.foo.port", str(target))
        assert good.returncode == 0, (good.returncode, good.stderr)
        assert "option" in good.stdout, good.stdout
        ghost = run_cli("--id", "options.services.foo.ghost", str(target))
        assert ghost.returncode == 1, (ghost.returncode, ghost.stdout)
        assert "no such item" in ghost.stderr, ghost.stderr


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
