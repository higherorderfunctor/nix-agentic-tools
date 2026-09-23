#!/usr/bin/env python3
"""Render the capability tables in a surface reference as text or SVG.

The markdown is the single source of truth: both renderers read its GFM
tables, and neither SVG is ever edited by hand. Keeping a table and its
image in step takes two further mechanisms, because reading the markdown
is not on its own enough to guarantee it:

  - Table selection is by HEADER SIGNATURE, so a section whose header
    wording drifts stops matching the matrix and would otherwise vanish
    from the image with nothing said. `dominant` therefore reports every
    table it drops, and hard-fails when a dropped table carries the
    elected column count — read that function before widening it.
  - Nothing here can notice that a COMMITTED SVG predates the markdown.
    checks/references/kimchi-surface-diagrams.nix re-renders both and
    fails on any byte difference; that check, not this script, is what
    makes a stale image unmergeable.

  preview  wrapped box-drawn tables, for reading in a terminal
  svg      dark-theme SVG, sized for a 1080p display
"""

import argparse
import html
import re
import sys
from pathlib import Path

FONT = "ui-monospace, 'JetBrains Mono', 'DejaVu Sans Mono', Menlo, Consolas, monospace"
FONT_SIZE = 13.5
LINE_HEIGHT = 20.0
CHAR_W = FONT_SIZE * 0.6  # monospace advance width
PAD_X, PAD_Y = 12.0, 9.0
HEADER_H, GROUP_H = 34.0, 40.0
TITLE_Y, SUBTITLE_Y = 26, 44  # baselines of the two heading lines
TEXT_BASE = 15.0  # first baseline inside a padded row
GAP = 10.0  # breathing room between one table and the next

COLORS = {
    "bg": "#0b0e14",
    "panel": "#11151d",
    "group_bg": "#171c26",
    "rule": "#232a36",
    "group": "#8ab4f8",
    "capability": "#9ecbff",
    "body": "#b8c2cc",
    "muted": "#6b7684",
    "url": "#7ee7c7",
    "warn": "#f0a868",
    "title": "#e6edf3",
    "subtitle": "#6b7684",
}

# A cell whose text starts one of these is an endpoint, and is coloured as one
# across every wrapped line. Compound methods ("GET/POST") are real in the
# reference, so the verb group repeats.
VERB = r"(GET|POST|PUT|DELETE|PATCH)"
URL_RE = re.compile(rf"^{VERB}(/{VERB})*\s")
URL_PREFIXES = ("wss://", "ws://", "https://", "http://", "127.0.0.1", "localhost")


def split_row(line):
    """Split one GFM table row, honouring backslash-escaped pipes."""
    line = line.strip()
    line = line[1:] if line.startswith("|") else line
    line = line[:-1] if line.endswith("|") else line
    cells, cur, escaped = [], "", False
    for ch in line:
        if escaped:
            cur += ch
            escaped = False
        elif ch == "\\":
            cur += ch
            escaped = True
        elif ch == "|":
            cells.append(cur.strip())
            cur = ""
        else:
            cur += ch
    cells.append(cur.strip())
    return cells


def is_delimiter(cells):
    return bool(cells) and all(re.fullmatch(r":?-{2,}:?", c.strip()) for c in cells)


def parse_tables(text):
    """Yield (heading, header_cells, rows) for every GFM table in the text."""
    lines = text.split("\n")
    tables, heading, i = [], "", 0
    while i < len(lines):
        m = re.match(r"^#{2,4}\s+(.*)", lines[i])
        if m:
            heading = m.group(1).strip()
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines):
            if is_delimiter(split_row(lines[i + 1])):
                header, rows = split_row(lines[i]), []
                i += 2
                while i < len(lines) and lines[i].lstrip().startswith("|"):
                    rows.append(split_row(lines[i]))
                    i += 1
                tables.append((heading, header, rows))
                continue
        i += 1
    return tables


def clean(text):
    """Strip inline markdown so a cell measures and renders as plain text."""
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return text.replace("\\|", "|").replace("<br>", " ").strip()


def strip_citations(text):
    """Drop the source citations. They belong in the prose, not in a cell."""
    return re.sub(r"\s*\((?:src/|B\d+:L|section |note )[^()]*\)", "", text).strip()


def wrap(text, width):
    """Wrap to width, breaking over-long URL-ish tokens on path separators.

    A width below 1 is clamped rather than honoured. The inner loop below
    advances by slicing `part[width:]`, which at width 0 is the identity,
    so an unclamped 0 appends empty tokens forever instead of raising.
    Callers that take a width from the user range-check it as well; this
    clamp is the one that makes the loop itself incapable of hanging.
    """
    width = max(1, width)
    tokens = []
    for word in text.split():
        if len(word) <= width:
            tokens.append(word)
            continue
        cur = ""
        for part in re.split(r"(?<=/)", word):
            while len(part) > width:
                if cur:
                    tokens.append(cur)
                    cur = ""
                tokens.append(part[:width])
                part = part[width:]
            if len(cur) + len(part) <= width:
                cur += part
            else:
                tokens.append(cur)
                cur = part
        if cur:
            tokens.append(cur)
    lines, cur = [], ""
    for token in tokens:
        if not cur:
            cur = token
        elif len(cur) + 1 + len(token) <= width:
            cur += " " + token
        else:
            lines.append(cur)
            cur = token
    if cur:
        lines.append(cur)
    return lines or [""]


def cell(text):
    return strip_citations(clean(text))


def column_widths(header, rows, budget):
    """Natural widths when they fit the budget, else an even split grown by need."""
    n = len(header)
    natural = [
        max([len(cell(header[c]))] + [len(cell(r[c])) for r in rows if c < len(r)])
        for c in range(n)
    ]
    available = budget - (3 * n + 1)
    if sum(natural) <= available:
        return natural
    widths = [min(nat, max(6, available // n)) for nat in natural]
    slack = available - sum(widths)
    order = sorted(range(n), key=lambda c: natural[c] - widths[c], reverse=True)
    while slack > 0:
        grew = False
        for c in order:
            if widths[c] < natural[c] and slack > 0:
                widths[c] += 1
                slack -= 1
                grew = True
        if not grew:
            break
    return widths


def select(tables, cols):
    """Keep tables wide enough for the requested columns, projected to them."""
    out = []
    for heading, header, rows in tables:
        if cols and max(cols) >= len(header):
            continue
        pick = cols or list(range(len(header)))
        out.append(
            (
                heading,
                [header[i] for i in pick],
                [[(r[i] if i < len(r) else "") for i in pick] for r in rows],
            )
        )
    return out


def section(heading):
    """Drop a leading section number. The numbering belongs to the document."""
    return re.sub(r"^\d+(?:\.\d+)*\.?\s+", "", heading).strip()


def dominant(tables):
    """Keep only the table shape that recurs, dropping the one-off asides.

    A surface reference interleaves one matrix repeated once per section with
    a handful of unrelated tables (hosts, counts, vendored-SDK notes). They
    share no columns, so rendering them on one sheet produces a sheet with no
    columns. The repeated header is the matrix; everything else is prose.

    SELECTION IS BY HEADER SIGNATURE, AND THAT IS A TRAP WORTH NARRATING.
    An author who rewords one section's header — "What comes back" to "What
    is returned" — has not written a new kind of table, but the signature no
    longer matches and the whole section leaves the sheet. Measured on the
    Kimchi reference: that one edit took the render from 9 tables to 8 and
    the capabilities SVG from 37179 to 30638 bytes, silently dropping the
    entire Account/billing group, exit 0, empty stderr.

    The drift check cannot catch it either. Regenerating after the reword
    produces a committed/regenerated pair that agree with each other while
    both omit the section, so the guard has to live here:

      - every discarded table is named on stderr with its signature, so a
        silent drop is no longer possible;
      - a discarded table with the SAME COLUMN COUNT as the elected shape
        is a hard failure. A genuine aside differs in shape, not in one
        word of one header, so an equal column count is nearly always a
        wording typo. The Kimchi reference's 12 real asides have 2, 3 or 4
        columns against the matrix's 6, and none of them trips this.
    """
    signatures = [tuple(cell(c) for c in header) for _, header, _ in tables]
    if not signatures:
        return []
    shape = max(dict.fromkeys(signatures), key=signatures.count)
    kept, suspect = [], []
    for table, sig in zip(tables, signatures):
        if sig == shape:
            kept.append(table)
        elif len(sig) == len(shape):
            suspect.append((table[0], sig))
        else:
            print(
                f"skipped aside ({len(sig)} cols, matrix has {len(shape)}): "
                f"{table[0]} [{' | '.join(sig)}]",
                file=sys.stderr,
            )
    if suspect:
        report = "\n".join(
            f"  {heading}\n    has:      {' | '.join(sig)}" for heading, sig in suspect
        )
        raise SystemExit(
            f"{len(suspect)} table(s) have the matrix's {len(shape)} columns but a "
            "header that does not match it, so they would be dropped from the "
            "render without appearing anywhere:\n"
            f"{report}\n"
            f"    expected: {' | '.join(shape)}\n"
            "Reword the header back to the matrix's, or give the table a "
            "genuinely different column count if it is a one-off aside."
        )
    print(
        f"matrix: kept {len(kept)} of {len(tables)} tables "
        f"({len(shape)} columns: {' | '.join(shape)})",
        file=sys.stderr,
    )
    return kept


def keep_matching(tables, needle):
    """Keep rows containing the needle, and tables that still have rows."""
    if not needle:
        return tables
    needle = needle.lower()
    out = []
    for heading, header, rows in tables:
        hits = [r for r in rows if needle in " ".join(r).lower()]
        if hits:
            out.append((heading, header, hits))
    return out


def layout(tables, widths):
    """Clean and wrap every cell once, so both renderers measure the same text.

    A laid-out row is a list of (joined text, wrapped lines) pairs. The joined
    text is kept because colour is decided from the whole cell, never from an
    individual line.
    """
    out = []
    for heading, header, rows in tables:
        laid = []
        for row in rows:
            texts = [cell(row[c] if c < len(row) else "") for c in range(len(header))]
            laid.append([(t, wrap(t, widths[c])) for c, t in enumerate(texts)])
        out.append((section(heading), [cell(h) for h in header], laid))
    return out


def cell_color(index, text):
    """Pick a colour from the WHOLE cell, never from one wrapped line.

    Colour is a property of the cell. Deciding per line paints a URL's
    continuation and the tail of a multi-line "source change" in the body
    colour, which reads as two different kinds of value in one cell.
    """
    if index == 0:
        return COLORS["capability"]
    if text in ("", "-", "—"):
        return COLORS["muted"]
    if URL_RE.match(text) or text.startswith(URL_PREFIXES):
        return COLORS["url"]
    if text.startswith("source change"):
        return COLORS["warn"]
    return COLORS["body"]


def render_text(header, rows, widths):
    """Box-drawn table with wrapped cells, for reading a projection in a shell."""
    rule = lambda left, mid, right: (  # noqa: E731 - one shape, three corners
        left + mid.join("─" * (w + 2) for w in widths) + right
    )

    def band(cells):
        height = max(len(lines) for lines in cells)
        return [
            "│"
            + "│".join(
                " " + (lines[i] if i < len(lines) else "").ljust(w) + " "
                for lines, w in zip(cells, widths)
            )
            + "│"
            for i in range(height)
        ]

    out = [rule("┌", "┬", "┐")]
    out += band([wrap(h, w) for h, w in zip(header, widths)])
    out.append(rule("├", "┼", "┤"))
    for row in rows:
        out += band([lines for _, lines in row])
    out.append(rule("└", "┴", "┘"))
    return "\n".join(out)


def render_svg(tables, title, subtitle, widths):
    """Dark-theme SVG of every laid-out table, stacked under one title."""
    esc = html.escape
    xs, x = [], PAD_X
    for w in widths:
        xs.append(x)
        x += w * CHAR_W + 2 * PAD_X
    width = round(x)
    # Height is only known once every row has been laid out, so the open tag
    # is written last and prepended. Templating it and substituting into the
    # finished document would rewrite any cell that happens to contain the
    # placeholder, and the cells carry arbitrary prose from the markdown.
    out = [f'<rect width="100%" height="100%" fill="{COLORS["bg"]}"/>']
    out.append(
        f'<text x="{PAD_X:.1f}" y="{TITLE_Y}" fill="{COLORS["title"]}"'
        f' font-size="17" font-weight="600">{esc(title)}</text>'
    )
    y = float(TITLE_Y)
    if subtitle:
        out.append(
            f'<text x="{PAD_X:.1f}" y="{SUBTITLE_Y}" fill="{COLORS["subtitle"]}"'
            f' font-size="11.5">{esc(subtitle)}</text>'
        )
        y = float(SUBTITLE_Y)
    y += GAP

    for heading, header, rows in tables:
        out.append(
            f'<rect x="0" y="{y:.1f}" width="{width}" height="{GROUP_H:g}"'
            f' fill="{COLORS["group_bg"]}"/>'
        )
        out.append(
            f'<text x="{PAD_X:.1f}" y="{y + 26:.1f}" fill="{COLORS["group"]}"'
            f' font-size="14" font-weight="600">{esc(heading)}</text>'
        )
        y += GROUP_H

        out.append(
            f'<rect x="0" y="{y:.1f}" width="{width}" height="{HEADER_H:g}"'
            f' fill="{COLORS["panel"]}"/>'
        )
        out.append(
            f'<line x1="0" y1="{y + HEADER_H:.1f}" x2="{width}"'
            f' y2="{y + HEADER_H:.1f}" stroke="{COLORS["rule"]}" stroke-width="1"/>'
        )
        for c, label in enumerate(header):
            out.append(
                f'<text x="{xs[c]:.1f}" y="{y + 22:.1f}" fill="{COLORS["muted"]}"'
                f' font-size="11.5" font-weight="600" letter-spacing="0.6">'
                f"{esc(label.upper())}</text>"
            )
        y += HEADER_H

        for row in rows:
            out.append(
                f'<line x1="0" y1="{y:.1f}" x2="{width}" y2="{y:.1f}"'
                f' stroke="{COLORS["rule"]}" stroke-width="0.5"/>'
            )
            for c, (text, lines) in enumerate(row):
                fill = cell_color(c, text)
                weight = "500" if c == 0 else "400"
                for i, line in enumerate(lines):
                    if not line:
                        continue
                    out.append(
                        f'<text x="{xs[c]:.1f}"'
                        f' y="{y + PAD_Y + i * LINE_HEIGHT + TEXT_BASE:.1f}"'
                        f' fill="{fill}" font-weight="{weight}"'
                        f' xml:space="preserve">{esc(line)}</text>'
                    )
            y += 2 * PAD_Y + max(len(lines) for _, lines in row) * LINE_HEIGHT
        y += GAP

    out.append("</svg>")
    height = round(y + 2 * PAD_X)
    out.insert(
        0,
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}"'
        f' viewBox="0 0 {width} {height}" font-family="{FONT}"'
        f' font-size="{FONT_SIZE:g}">',
    )
    return "\n".join(out) + "\n"


def columns(spec):
    return [int(c) for c in spec.split(",") if c.strip() != ""] if spec else []


def prepare(args):
    """Shared front half: parse, keep the matrix, project, filter, lay out."""
    cols = columns(args.cols)
    tables = keep_matching(
        select(dominant(parse_tables(Path(args.markdown).read_text())), cols),
        getattr(args, "filter", None),
    )
    if not tables:
        raise SystemExit("no tables matched")
    return cols, tables


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    preview = sub.add_parser("preview", help="box-drawn tables on stdout")
    preview.add_argument("markdown")
    preview.add_argument("--width", type=int, default=160, help="total characters")
    preview.add_argument("--cols", default="", help="0-based column indices")
    preview.add_argument("--filter", default="", help="keep rows containing this")

    svg = sub.add_parser("svg", help="dark-theme SVG")
    svg.add_argument("markdown")
    svg.add_argument("out")
    svg.add_argument("--title", required=True)
    svg.add_argument("--subtitle", default="")
    svg.add_argument("--cols", default="", help="0-based column indices")
    svg.add_argument("--filter", default="", help="keep rows containing this")
    svg.add_argument("--width", type=int, default=200, help="fallback fit budget")
    svg.add_argument(
        "--widths",
        default="",
        # Fitting to a budget starves the one column that needs the room. In
        # the Kimchi reference, Endpoint's longest cell is 203 characters on
        # the strength of two outlier rows while Repoint's median is 14, so an
        # even split wraps every URL and leaves Repoint two thirds empty. The
        # committed widths come from each column's length DISTRIBUTION, which
        # is why they are not round numbers.
        help="explicit per-column character counts, e.g. 46,90,80",
    )

    args = parser.parse_args()
    cols, tables = prepare(args)

    if args.command == "preview":
        widths = column_widths(tables[0][1], tables[0][2], args.width)
        for heading, header, rows in layout(tables, widths):
            print(f"\n{heading}\n")
            print(render_text(header, rows, widths))
        return

    widths = columns(args.widths) or column_widths(
        tables[0][1], tables[0][2], args.width
    )
    if len(widths) != len(tables[0][1]):
        raise SystemExit(
            f"--widths needs {len(tables[0][1])} counts, got {len(widths)}"
        )
    # `wrap` clamps a non-positive width so it cannot hang, but silently
    # rendering a 1-character column is not what the caller asked for, and a
    # zero here is a typo in a comma list every time. Say so instead.
    if any(w < 1 for w in widths):
        raise SystemExit(f"--widths counts must each be >= 1, got {args.widths!r}")
    Path(args.out).write_text(
        render_svg(layout(tables, widths), args.title, args.subtitle, widths)
    )


if __name__ == "__main__":
    main()
