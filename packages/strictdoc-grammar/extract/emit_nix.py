"""Render Nix source text.

Shared by ``extract.py`` (which writes ``lib/faithful.nix``) and ``normalize.py``
(which writes ``lib/normalized.nix``). Neither generator hand-formats Nix: they
build values here and let this module render them, so the two generated files
have one canonical form and a drift diff stays readable.

Nothing in this module knows anything about StrictDoc. It is a renderer.

SCAFFOLD STUB — milestone 1, SLICE-GRAMMAR-FROM-NIX. Importing works; calling
does not.
"""

from __future__ import annotations

_TODO = "packages/strictdoc-grammar/extract/emit_nix.py: {0} is a scaffold stub"

# Header prepended to every generated file, so a reader who opens one without
# reading the barrel knows not to edit it.
GENERATED_HEADER = "# GENERATED FILE — DO NOT EDIT BY HAND.\n"


def render_string(value: str) -> str:
    """Render a Python string as a Nix string literal, escaping as needed."""
    raise NotImplementedError(_TODO.format("render_string"))


def render_value(value: object) -> str:
    """Render a Python value as Nix source (str, bool, int, None, list, dict)."""
    raise NotImplementedError(_TODO.format("render_value"))


def render_attrs(attrs: dict, indent: int = 0) -> str:
    """Render a mapping as a Nix attribute set, keys in a stable order."""
    raise NotImplementedError(_TODO.format("render_attrs"))


def render_file(body: object, arg_pattern: str) -> str:
    """Render a whole generated file: header, argument pattern, then ``body``."""
    raise NotImplementedError(_TODO.format("render_file"))
