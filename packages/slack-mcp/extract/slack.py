"""Capture the Slack MCP server's endpoint and its tool-to-scope table."""

import argparse
import json
import re
from pathlib import Path

URL_SHAPE = re.compile(r"https://[a-z0-9.-]+/\S*")
SCOPE_SHAPE = re.compile(r"[a-z]+:[a-z.]+")
# One `[`scope`](url)` link, optionally qualified ("for public channels").
SCOPE_LINK = r"\[`([^`]+)`\]\(https://[^)\s]+\)(?: for [^,\[\]`]+)?"
SCOPE_LINE = re.compile(rf"{SCOPE_LINK}(?:, {SCOPE_LINK})*")
# Any scope link, wherever it sits; used to refuse one outside the table.
ANY_SCOPE_LINK = re.compile(r"\[`[^`]+`\]\(")
# The scope table must name the scopes the baseline read tools need.
REQUIRED_SCOPES = {"channels:history", "search:read.public"}
MIN_TOOLS = 10
# The callout heading that follows the last scope row.
TABLE_END = "Consider using PKCE"


def section(document, heading):
    # A section runs to the next heading or thematic break.
    bodies = re.findall(
        rf"(?ms)^{re.escape(heading)}(?: \{{#[^}}]*\}})?\n(.*?)(?=^#{{1,6}} |^\* \* \*$|\Z)",
        document,
    )
    if len(bodies) != 1:
        raise ValueError(f"expected exactly one section {heading!r}")
    return bodies[0]


def endpoint(document):
    blocks = re.findall(
        r"(?ms)^```[^\n]*\n(.*?)^```", section(document, "## Transport protocol and endpoint")
    )
    if len(blocks) != 1:
        raise ValueError("expected exactly one fenced block under the transport section")
    url = blocks[0].strip()
    if not URL_SHAPE.fullmatch(url):
        raise ValueError(f"transport endpoint {url!r} is not one https url")
    return url


def tools(document):
    # The table renders as alternating paragraphs: a tool name, then its scopes.
    lines = [
        line.strip()
        for line in section(
            document, "### OAuth scopes needed on user token for different tools"
        ).splitlines()
        if line.strip()
    ]
    if lines[:2] != ["Tool", "Scopes needed"]:
        raise ValueError("missing the Tool / Scopes needed table header")
    # The callout after the last row closes the table; rows are name/scope pairs.
    if lines.count(TABLE_END) != 1:
        raise ValueError(f"expected exactly one {TABLE_END!r} line closing the tool table")
    end = lines.index(TABLE_END)
    rows, after = lines[2:end], lines[end:]
    if len(rows) % 2:
        raise ValueError(f"incomplete tool row before {TABLE_END!r}: {rows[-1]!r}")
    stray = [line for line in after if ANY_SCOPE_LINK.search(line)]
    if stray:
        raise ValueError(f"scope link outside the tool table: {stray[0]!r}")
    table = {}
    for name, scopes in zip(rows[::2], rows[1::2]):
        if ANY_SCOPE_LINK.search(name) or not SCOPE_LINE.fullmatch(scopes):
            raise ValueError(f"tool {name!r} is not followed by one scope line")
        if name in table:
            raise ValueError(f"duplicate tool {name!r}")
        found = sorted(set(re.findall(r"\[`([^`]+)`\]", scopes)))
        malformed = [scope for scope in found if not SCOPE_SHAPE.fullmatch(scope)]
        if malformed:
            raise ValueError(f"tool {name!r} has malformed scopes {malformed}")
        table[name] = found
    if len(table) < MIN_TOOLS:
        raise ValueError(f"expected at least {MIN_TOOLS} tools, found {len(table)}")
    missing = REQUIRED_SCOPES - {scope for scopes in table.values() for scope in scopes}
    if missing:
        raise ValueError(f"missing required scopes {sorted(missing)}")
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        document = args.source.read_text(encoding="utf-8")
        result = {"tools": tools(document), "url": endpoint(document)}
    except (OSError, ValueError) as error:
        parser.exit(1, f"slack-mcp-extract: {error}\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
