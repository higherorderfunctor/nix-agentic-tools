#!/usr/bin/env python3
# cspell:ignore attrpath sdoc
"""Contracts for the source-traceability flip: bash, injection, the null reader.

    strictdoc-grammar-extract dev/scripts/test_sdoc_flip.py

THE INTERPRETER MATTERS, for the same reason test_sdoc_extractors.py says so:
this is the only interpreter in the repository that imports both `strictdoc`
and `tree_sitter`, and it is where `SDOC_TS_BASH_PARSER` and
`SDOC_TS_NIX_PARSER` are set.

A SEPARATE FILE FROM test_sdoc_extractors.py on purpose. That one is the Nix
extractor's contract suite and is organized around its queries; this one is
about the three things the flip added -- a second language, a sub-grammar
injected into the first, and a registry replacement whose whole job is that
strictdoc's own readers are never reached.

EVERY NEGATIVE CONTRACT CARRIES ITS POSITIVE CONTROL, on the same reasoning:
"the null reader produced no items" is indistinguishable from "the extractor
is broken and produces no items anywhere" unless something in the same test
shows items being produced.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from sdoc_extractors import registry  # noqa: E402
from sdoc_extractors.bash import (  # noqa: E402
    BASH_ELEMENT_QUERIES,
    BASH_KIND_ELEMENTS,
    bash_extractor,
)
from sdoc_extractors.nix import (  # noqa: E402
    NIX_KIND_ELEMENTS,
    NIX_SHELL_HOST_NODE,
    nix_extractor,
)
from sdoc_extractors.strictdoc_reader import (  # noqa: E402
    NULL_ROUTE,
    ROUTING_STATS,
    GlobRoutingReader,
    NullSourceReader,
    make_reader_factory,
    reset_routing_stats,
)
from sdoc_extractors.tree_sitter_extractor import ExtractorError  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

#: A `writeShellApplication` in miniature: a shell function, a shell variable,
#: and an INTERPOLATION in the middle of the script. The interpolation is the
#: point -- `${pkgs.coreutils}/bin/cp` is Nix source sitting inside a bash
#: script, and a naive slice-and-reparse hands it to bash as garbage.
INJECTION_FIXTURE = b"""{pkgs}:
pkgs.writeShellApplication {
  name = "demo";
  text = ''
    threshold=3

    # Copy one file, loudly.
    copy_one() {
      ${pkgs.coreutils}/bin/cp "$1" "$2"
    }
  '';
}
"""

#: The same shell, standalone. Same names, so the two routes can be compared.
BASH_FIXTURE = b"""#!/usr/bin/env bash
threshold=3

# Copy one file, loudly.
copy_one() {
  cp "$1" "$2"
}
"""

PASSED: list = []


def contract(name: str):
    def wrap(function):
        def run():
            function()
            PASSED.append(name)
            print(f"  ok  {name}")

        run.__name__ = function.__name__
        return run

    return wrap


def by_id(items: list, identifier: str):
    for item in items:
        if item.identifier == identifier:
            return item
    raise AssertionError(
        f"no item {identifier!r}; got {[i.identifier for i in items]}"
    )


# ── the bash extractor ───────────────────────────────────────────────────


@contract("bash names a function by its word and a top-level assignment by name")
def test_bash_kinds() -> None:
    items = bash_extractor().extract(BASH_FIXTURE, "src/demo.sh")
    kinds = {item.identifier: item.kind for item in items}
    assert kinds == {"threshold": "variable", "copy_one": "function"}, kinds
    # The comment directly above the function is attached to it, which is what
    # a backward `@relation(...)` in a shell script would ride on.
    assert by_id(items, "copy_one").has_comment, items


@contract("bash ignores an assignment that is not at the top level")
def test_bash_nested_assignment_ignored() -> None:
    nested = b"outer=1\nf() {\n  inner=2\n}\n"
    names = [item.identifier for item in bash_extractor().extract(nested, "s")]
    # POSITIVE CONTROL first: the top-level one IS found, so this is a
    # statement about nesting rather than about the query being dead.
    assert "outer" in names, names
    assert "inner" not in names, names


@contract("every bash kind maps onto strictdoc's closed ELEMENT vocabulary")
def test_bash_elements_closed() -> None:
    assert set(BASH_KIND_ELEMENTS) == set(BASH_ELEMENT_QUERIES)
    assert set(BASH_KIND_ELEMENTS.values()) <= {"function", "class"}
    # The Nix map has to carry the injected kinds too, or a reader raises.
    assert "shell-function" in NIX_KIND_ELEMENTS, NIX_KIND_ELEMENTS
    assert "shell-variable" in NIX_KIND_ELEMENTS, NIX_KIND_ELEMENTS


# ── the injection ────────────────────────────────────────────────────────


@contract("shell inside a Nix string is an item, qualified and kind-prefixed")
def test_injection_items() -> None:
    items = nix_extractor(path_root=str(REPO_ROOT)).extract(
        INJECTION_FIXTURE, "src/demo.nix"
    )
    injected = {
        item.identifier: item for item in items if item.kind.startswith("shell-")
    }
    assert set(injected) == {"text::copy_one", "text::threshold"}, injected
    assert injected["text::copy_one"].kind == "shell-function"
    assert injected["text::threshold"].kind == "shell-variable"
    # POSITIVE CONTROL: the Nix items are still there, so the injection is an
    # addition rather than a replacement.
    assert by_id(items, "text").kind == "binding", items


@contract("injected line numbers are absolute in the HOST file")
def test_injection_lines_are_absolute() -> None:
    items = nix_extractor(path_root=str(REPO_ROOT)).extract(
        INJECTION_FIXTURE, "src/demo.nix"
    )
    lines = INJECTION_FIXTURE.decode().splitlines()
    function = by_id(items, "text::copy_one")
    # The assertion is READ OFF THE FIXTURE rather than hardcoded, so editing
    # the fixture cannot leave a stale number passing.
    expected = lines.index("    copy_one() {") + 1
    assert function.line_begin == expected, (function, expected)
    assert lines[function.line_end - 1].strip() == "}", function
    # The comment is the bash one, at its own absolute line.
    assert function.comment_text.strip().startswith("# Copy one file"), function
    assert function.comment_line_begin == expected - 1, function


@contract("a Nix interpolation is not handed to the bash parser")
def test_injection_excludes_interpolation() -> None:
    items = nix_extractor(path_root=str(REPO_ROOT)).extract(
        INJECTION_FIXTURE, "src/demo.nix"
    )
    # `${pkgs.coreutils}` sits inside copy_one's body. If the interpolation
    # were in the parse, bash would see `${pkgs.coreutils}` as an expansion
    # spanning a `.`, and more importantly the ranges would shift -- the
    # function's end line is the check that they did not.
    function = by_id(items, "text::copy_one")
    assert function.line_end - function.line_begin == 2, function
    # POSITIVE CONTROL: the same shell, standalone, has the same span.
    standalone = by_id(
        bash_extractor().extract(BASH_FIXTURE, "src/demo.sh"), "copy_one"
    )
    assert (
        standalone.line_end - standalone.line_begin
        == function.line_end - function.line_begin
    ), (standalone, function)


@contract("an injection host node type that does not exist raises at construction")
def test_injection_host_must_exist() -> None:
    from sdoc_extractors.nix import NIX_ELEMENT_QUERIES, load_nix_language
    from sdoc_extractors.tree_sitter_extractor import (
        Injection,
        TreeSitterExtractor,
    )

    # POSITIVE CONTROL: the real host node type constructs fine.
    TreeSitterExtractor(
        language=load_nix_language(),
        element_queries=NIX_ELEMENT_QUERIES,
        injections={NIX_SHELL_HOST_NODE: Injection(extractor=bash_extractor())},
    )
    try:
        TreeSitterExtractor(
            language=load_nix_language(),
            element_queries=NIX_ELEMENT_QUERIES,
            injections={"no_such_node_type": bash_extractor()},
        )
    except ExtractorError as error:
        assert "no_such_node_type" in str(error), error
    else:
        raise AssertionError("an unknown host node type constructed silently")


@contract("inject_bash=False is the only way to get a Nix-only extractor")
def test_injection_is_on_by_default() -> None:
    plain = nix_extractor(path_root=str(REPO_ROOT), inject_bash=False)
    items = plain.extract(INJECTION_FIXTURE, "src/demo.nix")
    assert not [item for item in items if item.kind.startswith("shell-")], items
    # POSITIVE CONTROL: the default DOES inject, so the assertion above is
    # about the flag rather than about the fixture.
    assert [
        item
        for item in nix_extractor(path_root=str(REPO_ROOT)).extract(
            INJECTION_FIXTURE, "src/demo.nix"
        )
        if item.kind.startswith("shell-")
    ]


# ── the null reader and the glob routing ─────────────────────────────────


@contract("the null reader runs no parser but still fills file_stats")
def test_null_reader_shape() -> None:
    info = NullSourceReader().read(b"one\n\nthree\n", "README.md")
    assert info.functions == [], info.functions
    assert info.markers == [], info.markers
    # THE POINT of computing stats at all: a whole-file forward marker takes
    # its end line from here, and coverage indexes lines_info by line number.
    assert info.file_stats.lines_total == 3, info.file_stats
    assert info.file_stats.lines_info[2] is False, info.file_stats
    # A marker written in the file is NOT read, which is the documented cost.
    info = NullSourceReader().read(b"# @relation(REQ-1, scope=file)\n", "x.md")
    assert info.markers == [], info.markers


@contract("routing sends a matched path to its extractor and the rest to null")
def test_glob_routing() -> None:
    reset_routing_stats()
    routes = tuple(
        (glob, _factory_for(spec))
        for glob, spec in registry.SOURCE_EXTRACTORS.items()
    )
    reader = GlobRoutingReader(routes=routes, path_root=str(REPO_ROOT))
    nix_info = reader.read_from_file(str(REPO_ROOT / "flake.nix"))
    assert nix_info.functions, "flake.nix produced no items"
    md_info = reader.read_from_file(str(REPO_ROOT / "README.md"))
    assert md_info.functions == [], md_info.functions
    assert md_info.file_stats.lines_total > 0, md_info.file_stats
    # The counter is what a measured run asserts on, so assert on it here.
    assert ROUTING_STATS["**/*.nix"] == 1, dict(ROUTING_STATS)
    assert ROUTING_STATS[NULL_ROUTE] == 1, dict(ROUTING_STATS)
    reset_routing_stats()


@contract("an extensionless script is routed by its named path, not by sniffing")
def test_extensionless_routing() -> None:
    reset_routing_stats()
    routes = tuple(
        (glob, _factory_for(spec))
        for glob, spec in registry.SOURCE_EXTRACTORS.items()
    )
    reader = GlobRoutingReader(routes=routes, path_root=str(REPO_ROOT))
    target = REPO_ROOT / "docs" / "sdoc" / "board" / "serve"
    info = reader.read_from_file(str(target))
    assert info.functions, f"{target} produced no items"
    assert ROUTING_STATS["docs/sdoc/board/serve"] == 1, dict(ROUTING_STATS)
    # NEGATIVE CONTROL: an unlisted extensionless script with the SAME shebang
    # is NOT routed to bash. Sniffing would find it; a manifest does not, and
    # that is the documented, deliberate behavior.
    assert (
        registry.matching_glob("dev/scripts/some-unlisted-hook", REPO_ROOT)
        is None
    )
    reset_routing_stats()


@contract("the manifest covers every path the repository actually names")
def test_manifest_targets_exist() -> None:
    literals = [
        glob
        for glob in registry.SOURCE_EXTRACTORS
        if not any(character in glob for character in "*?")
    ]
    assert literals, registry.SOURCE_EXTRACTORS
    missing = [name for name in literals if not (REPO_ROOT / name).is_file()]
    assert not missing, f"manifest names files that do not exist: {missing}"


def _factory_for(spec):
    return make_reader_factory(
        registry.build(spec, path_root=str(REPO_ROOT)), spec.kind_elements
    )


def main() -> int:
    contracts = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    print(f"flip contracts: {len(contracts)}")
    for check in contracts:
        check()
    print(f"{len(PASSED)} contract(s) passed")
    assert len(PASSED) == len(contracts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
