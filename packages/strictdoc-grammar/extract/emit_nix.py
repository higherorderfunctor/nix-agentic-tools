# cspell:ignore keepends tofile
"""Render Nix source text.

Shared by ``extract.py`` (which writes ``lib/faithful.nix``) and ``normalize.py``
(which writes ``lib/normalized.nix``). Neither generator hand-formats Nix: they
build values here and let this module render them, so the two generated files
have one canonical form and a drift diff stays readable.

Nothing in this module knows anything about StrictDoc. It is a renderer.

The whole vocabulary is:

``Raw``
    Wraps verbatim Nix source. Needed because a generated surface is mostly
    *expressions* (``lib.types.strMatching "…"``, a reference to a sibling
    ``rec`` binding), not data, and there is no Python value that means "this
    identifier".
``render_string`` / ``render_value`` / ``render_attrs`` / ``render_list``
    Data to Nix, with ``dict`` keys emitted in sorted order so a regeneration
    diff shows only real change.
``render_binding`` / ``render_option``
    The two syntactic shapes a generated surface is made of. ``render_option``
    is here rather than in a caller because both generators emit ``mkOption``
    declarations and the module system's spelling of one is not StrictDoc
    knowledge.
``render_file``
    Header, argument pattern, optional ``let`` preamble, body.

Rendering is deterministic and stable across runs: no ``set`` iteration order,
no ``id()``, no timestamps. A caller that wants the result to survive
``treefmt`` unchanged should pass it through ``format_nix`` before writing.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import Iterable, Mapping, Sequence

# Header prepended to every generated file, so a reader who opens one without
# reading the barrel knows not to edit it.
GENERATED_HEADER = "# GENERATED FILE — DO NOT EDIT BY HAND.\n"

INDENT = "  "

# Nix keywords cannot appear as a bare attribute name.
_NIX_KEYWORDS = frozenset(
    {
        "assert",
        "else",
        "if",
        "in",
        "inherit",
        "let",
        "or",
        "rec",
        "then",
        "with",
    }
)

# The only escapes a Nix double-quoted string understands. Any other control
# character has no portable spelling, so it is refused rather than guessed at.
_STRING_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


class NixRenderError(Exception):
    """Raised when a Python value has no faithful Nix spelling."""


class Raw:
    """Verbatim Nix source, rendered without quoting or escaping.

    Use for expressions and identifiers. Everything that is *data* should go
    through ``render_value`` instead, so it is escaped.
    """

    __slots__ = ("src",)

    def __init__(self, src: str) -> None:
        if not isinstance(src, str):
            raise NixRenderError(f"Raw() takes source text, got {type(src).__name__}")
        self.src = src

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Raw({self.src!r})"


def is_identifier(name: str) -> bool:
    """Whether ``name`` can be a bare Nix attribute name."""
    if not name or name in _NIX_KEYWORDS:
        return False
    head, *tail = name
    if not (head.isascii() and (head.isalpha() or head == "_")):
        return False
    return all(c.isascii() and (c.isalnum() or c in "_'-") for c in tail)


def render_string(value: str) -> str:
    """Render a Python string as a Nix string literal, escaping as needed."""
    if not isinstance(value, str):
        raise NixRenderError(f"render_string() takes str, got {type(value).__name__}")
    out = ['"']
    for char in value:
        escape = _STRING_ESCAPES.get(char)
        if escape is not None:
            out.append(escape)
        elif char == "$":
            # Only `${` starts an interpolation, but escaping every `$` is
            # simpler to read back and means nothing about the neighbouring
            # character can change how this renders.
            out.append("\\$")
        elif ord(char) < 0x20 or ord(char) == 0x7F:
            raise NixRenderError(
                f"control character {ord(char):#04x} has no Nix string escape"
            )
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def render_key(name: str) -> str:
    """Render an attribute name, quoting it when it is not an identifier."""
    return name if is_identifier(name) else render_string(name)


def render_value(value: object, indent: int = 0) -> str:
    """Render a Python value as Nix source (Raw, str, bool, int, None, list, dict)."""
    if isinstance(value, Raw):
        return value.src
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, str):
        return render_string(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, Mapping):
        return render_attrs(value, indent)
    if isinstance(value, (list, tuple)):
        return render_list(value, indent)
    raise NixRenderError(f"no Nix spelling for {type(value).__name__}")


def render_list(items: Sequence[object], indent: int = 0) -> str:
    """Render a sequence as a Nix list, one element per line."""
    items = list(items)
    if not items:
        return "[]"
    pad = INDENT * (indent + 1)
    body = "\n".join(f"{pad}{render_value(item, indent + 1)}" for item in items)
    return "[\n" + body + "\n" + INDENT * indent + "]"


def render_attrs(attrs: Mapping[str, object], indent: int = 0) -> str:
    """Render a mapping as a Nix attribute set, keys in a stable order."""
    if not attrs:
        return "{}"
    pad = INDENT * (indent + 1)
    body = "\n".join(
        f"{pad}{render_binding(key, attrs[key], indent + 1)}"
        for key in sorted(attrs, key=str)
    )
    return "{\n" + body + "\n" + INDENT * indent + "}"


def render_binding(name: str, value: object, indent: int = 0) -> str:
    """Render one ``name = value;`` binding (no leading indentation)."""
    return f"{render_key(name)} = {render_value(value, indent)};"


_UNSET = object()


def render_option(
    type_expr: object,
    *,
    default: object = _UNSET,
    description: str | None = None,
    extra: Mapping[str, object] | None = None,
    indent: int = 0,
) -> Raw:
    """Render an ``mkOption { … }`` declaration as Raw source.

    ``type_expr`` is normally ``Raw``. ``default`` is omitted entirely unless
    given, so a mandatory option stays mandatory — passing ``None`` renders a
    real ``default = null;``.
    """
    fields: dict[str, object] = {"type": type_expr}
    if default is not _UNSET:
        fields["default"] = default
    if description is not None:
        fields["description"] = description
    if extra:
        fields.update(extra)
    return Raw("mkOption " + render_attrs(fields, indent))


def render_let(bindings: Sequence[tuple[str | None, object]], body: object) -> str:
    """Render ``let … in body``. Bindings keep the order given, not sorted.

    Order is the caller's because a ``let`` is read top to bottom as an
    argument, unlike an attribute set, which is a bag.

    A ``None`` name renders its value as a WHOLE binding line, semicolon and
    all. That is the only way to spell ``inherit (lib) mkOption;``, which has no
    ``name = value`` shape — and statix rejects the assignment form of it
    (``[04]`` assignment instead of inherit-from), so a generated ``let`` that
    re-binds a name from an argument has to be able to say it this way.
    """
    if not bindings:
        return render_value(body)
    lines = [
        f"{INDENT}{render_value(value, 1) if name is None else render_binding(name, value, 1)}"
        for name, value in bindings
    ]
    return "let\n" + "\n".join(lines) + "\nin\n" + render_value(body)


def render_file(
    body: object,
    arg_pattern: str,
    *,
    preamble: Sequence[tuple[str, object]] = (),
    header_comment: str = "",
) -> str:
    """Render a whole generated file: header, argument pattern, then ``body``.

    ``preamble`` becomes a ``let`` between the argument pattern and the body.
    ``header_comment`` is emitted verbatim under ``GENERATED_HEADER``; it is the
    caller's job to have commented it.
    """
    parts = [GENERATED_HEADER]
    if header_comment:
        parts.append(header_comment if header_comment.endswith("\n") else header_comment + "\n")
    parts.append(f"{arg_pattern}: ")
    parts.append(render_let(list(preamble), body))
    text = "".join(parts)
    return text if text.endswith("\n") else text + "\n"


def format_nix(text: str) -> str:
    """Run ``alejandra`` over ``text`` when it is on PATH, else pass it through.

    Generation has to be idempotent: this repository formats with alejandra, so
    an unformatted generated file would be rewritten by the next ``treefmt`` and
    then read as drift by the next ``--check``. Formatting here closes that loop.
    A missing formatter is a warning rather than an error, because the extractor
    is also runnable from the wrapper package, whose PATH carries only what the
    extraction itself needs.
    """
    exe = shutil.which("alejandra")
    if exe is None:
        print(
            "warning: alejandra not on PATH; generated Nix is left unformatted "
            "and `treefmt` will report a change",
            file=sys.stderr,
        )
        return text
    done = subprocess.run(
        [exe, "--quiet", "-"],
        input=text,
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        raise NixRenderError(
            f"alejandra rejected the generated source: {done.stderr.strip()}"
        )
    return done.stdout


def write_or_check(path: str, text: str, check: bool) -> int:
    """Write ``text`` to ``path``, or diff against it and report drift.

    Returns a process exit status: 0 clean, 1 drifted.
    """
    import difflib
    import pathlib

    target = pathlib.Path(path)
    if not check:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return 0
    current = target.read_text(encoding="utf-8") if target.exists() else ""
    if current == text:
        return 0
    diff: Iterable[str] = difflib.unified_diff(
        current.splitlines(keepends=True),
        text.splitlines(keepends=True),
        fromfile=f"{path} (committed)",
        tofile=f"{path} (regenerated)",
    )
    sys.stdout.writelines(diff)
    return 1
