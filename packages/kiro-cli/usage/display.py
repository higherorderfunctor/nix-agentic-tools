"""Plain text tables for offline usage inspection."""


def value(item):
    if item is None:
        return "—"
    if isinstance(item, int):
        return format(item, ",")
    if isinstance(item, float):
        return format(item, ",.12g")
    # Render non-ASCII text, controls, and backslashes as visible ASCII escapes; query's error cells keep their ±.
    return "".join(char if char == "±" else char.encode("unicode_escape").decode("ascii") for char in str(item))


RULE = ()  # A row that renders as dashes across the full table width.


def plain(block, row, column, text):
    return text


def tables(blocks, right=(), paint=plain):
    """(headers, rows) blocks rendered with shared column widths so they line up; indexes in right are right-aligned.
    render_summary's paint(block, row, column, text) styles each cell before padding (row 0 is headers; column None a RULE)."""
    blocks = [(headers, [row if row is RULE else [value(cell) for cell in row] for row in rows]) for headers, rows in blocks]
    cells = [row for headers, rows in blocks for row in [headers, *rows] if row is not RULE]
    widths = [max(len(row[index]) for row in cells) for index in range(len(cells[0]))]
    total = sum(widths) + 2 * (len(widths) - 1)
    def cell(block, row, column, text):  # Pad from the plain text, so escape sequences never count toward width.
        gap = " " * (widths[column] - len(text))
        return gap + paint(block, row, column, text) if column in right else paint(block, row, column, text) + gap
    return ["\n".join(paint(block, number, None, "-" * total) if row is RULE else
                      "  ".join(cell(block, number, column, text) for column, text in enumerate(row)).rstrip()
                      for number, row in enumerate([headers, *rows]))
            for block, (headers, rows) in enumerate(blocks)]


def table(headers, rows, right=()):
    """Left-aligned columns; indexes in right are right-aligned (the exit summary's numbers)."""
    return tables([(headers, rows)], right)[0]
