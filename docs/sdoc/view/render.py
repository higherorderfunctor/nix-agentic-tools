#!/usr/bin/env python3
"""Embed one whiteboard-view/2 payload into the content-blind template.

    render.py payload.json template.html --out page.html --wrap page
    render.py payload.json template.html --out page.artifact.html --wrap artifact

The template carries a single ``/*DATA*/`` marker where the payload is spliced
in as a JavaScript literal, and a single ``<!--BODY-->`` marker between what
belongs in a document's head (title, font links, style) and what belongs in
its body (markup, script). Nothing else is touched: every word on the page
comes from the payload, and the template knows only the schema's shape.

``--wrap page`` writes a full standalone document (doctype, html, head with
the title and a viewport meta, body). ``--wrap artifact`` writes the fragment
the artifact host wraps itself: the template as it is, title first, no
doctype, html, head or body tags. Both come from the same bytes of template
and payload, so the two copies differ only in the wrapper.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCHEMA = "whiteboard-view/2"
MARKER = "/*DATA*/"
BODY_MARKER = "<!--BODY-->"
WRAPS = ("page", "artifact")


def fail(msg: str, code: int = 2) -> "NoReturn":  # noqa: F821 - documentation only
    print(f"render.py: {msg}", file=sys.stderr)
    sys.exit(code)


def embed(payload: dict, template: str) -> str:
    if payload.get("schema") != SCHEMA:
        fail(f"payload schema is {payload.get('schema')!r}; this renderer was built for {SCHEMA!r}")
    if template.count(MARKER) != 1:
        fail(f"template must contain exactly one {MARKER} marker, found {template.count(MARKER)}")
    literal = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    # A closing tag or a line separator inside the literal would end the script
    # block or break the JS parser; escape them without changing the JSON value.
    literal = (
        literal.replace("</", "<\\/")
        .replace(" ", "\\u2028")
        .replace(" ", "\\u2029")
    )
    return template.replace(MARKER, literal)


def wrap(fragment: str, mode: str) -> str:
    if mode == "artifact":
        return fragment
    if fragment.count(BODY_MARKER) != 1:
        fail(f"template must contain exactly one {BODY_MARKER} marker to be wrapped as a page")
    head, body = fragment.split(BODY_MARKER, 1)
    return (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\" />\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
        f"{head.strip()}\n</head>\n<body>\n{body.strip()}\n</body>\n</html>\n"
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("payload", type=Path, help="the wireline payload (JSON)")
    ap.add_argument("template", type=Path, help="the page template carrying a /*DATA*/ marker")
    ap.add_argument("--out", type=Path, required=True, help="where to write the page")
    ap.add_argument("--wrap", choices=WRAPS, default="artifact", help="page: a full document; artifact: the fragment the artifact host wraps (default)")
    args = ap.parse_args(argv)
    try:
        payload = json.loads(args.payload.read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        fail(f"cannot read payload {args.payload}: {err}")
    if not isinstance(payload, dict):
        fail("payload must be a JSON object")
    try:
        template = args.template.read_text(encoding="utf-8")
    except OSError as err:
        fail(f"cannot read template {args.template}: {err}")
    page = wrap(embed(payload, template), args.wrap)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(page, encoding="utf-8")
    print(f"{args.out}: {len(page)} bytes ({args.wrap})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
