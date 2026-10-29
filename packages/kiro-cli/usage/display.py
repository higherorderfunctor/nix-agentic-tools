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


def table(headers, rows, right=()):
    """Left-aligned columns; indexes in right are right-aligned (the exit summary's numbers)."""
    rows = [[value(cell) for cell in row] for row in rows]
    widths = [max([len(header), *(len(row[index]) for row in rows)])
              for index, header in enumerate(headers)]
    return "\n".join("  ".join(cell.rjust(width) if index in right else cell.ljust(width)
                               for index, (cell, width) in enumerate(zip(row, widths))).rstrip()
                     for row in [headers, *rows])
