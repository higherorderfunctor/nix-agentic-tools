#!/usr/bin/env python3
"""Embed one whiteboard-view/1 payload into the content-blind template.

    render.py payload.json template.html --out page.html

The template carries a single ``/*DATA*/`` marker where the payload is spliced
in as a JavaScript literal. Nothing else is touched: every word on the page
comes from the payload, and the template knows only the schema's shape.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCHEMA = "whiteboard-view/1"
MARKER = "/*DATA*/"


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


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("payload", type=Path, help="the wireline payload (JSON)")
    ap.add_argument("template", type=Path, help="the page template carrying a /*DATA*/ marker")
    ap.add_argument("--out", type=Path, required=True, help="where to write the page")
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
    page = embed(payload, template)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(page, encoding="utf-8")
    print(f"{args.out}: {len(page)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
