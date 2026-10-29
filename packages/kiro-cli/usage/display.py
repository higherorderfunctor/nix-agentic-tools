"""Plain text tables for offline usage inspection."""


def value(item):
    if item is None:
        return "—"
    if isinstance(item, int):
        return format(item, ",")
    if isinstance(item, float):
        return format(item, ",.12g")
    # Render non-ASCII text, controls, and backslashes as visible ASCII escapes.
    return str(item).encode("unicode_escape").decode("ascii")


RULE = ()  # A row that renders as dashes across the full table width.


def tables(blocks, right=()):
    """(headers, rows) blocks rendered with shared column widths so they line up; indexes in right are right-aligned."""
    blocks = [(headers, [row if row is RULE else [value(cell) for cell in row] for row in rows]) for headers, rows in blocks]
    cells = [row for headers, rows in blocks for row in [headers, *rows] if row is not RULE]
    widths = [max(len(row[index]) for row in cells) for index in range(len(cells[0]))]
    total = sum(widths) + 2 * (len(widths) - 1)
    return ["\n".join("-" * total if row is RULE else
                      "  ".join(cell.rjust(width) if index in right else cell.ljust(width)
                                for index, (cell, width) in enumerate(zip(row, widths))).rstrip()
                      for row in [headers, *rows])
            for headers, rows in blocks]


def table(headers, rows, right=()):
    """Left-aligned columns; indexes in right are right-aligned (the exit summary's numbers)."""
    return tables([(headers, rows)], right)[0]
