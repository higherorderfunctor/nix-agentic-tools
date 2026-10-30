"""Optional exit-summary look: SGR styles per element and a box border. Absent keys keep the plain summary."""

import json
import os
from pathlib import Path
import re
import sys


# Box glyphs per --summary-theme border: top-left, horizontal, top-right, vertical, left-T, right-T, bottom-left, bottom-right.
BORDERS = {
    "ascii": "+-+|++++",
    "double": "╔═╗║╠╣╚╝",
    "heavy": "┏━┓┃┣┫┗┛",
    "rounded": "╭─╮│├┤╰╯",
    "single": "┌─┐│├┤└┘",
}
COLOR_MODES = ("always", "auto", "never")
COLORS = ("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")  # SGR order: 30 + index
ATTRIBUTES = {"bold": 1, "dim": 2, "italic": 3, "reverse": 7, "underline": 4}
# Styles render_summary paints; DEFAULTS apply only when color is on, and a theme entry replaces one ("" clears it).
ELEMENTS = ("border", "cached", "credits", "estimate", "header", "headline", "label", "model", "muted", "number", "rule", "total", "warning")
DEFAULTS = {"estimate": "dim", "header": "bold", "headline": "bold", "muted": "dim", "total": "bold", "warning": "yellow"}
# Nerd Font glyphs for icons=true: U+F080 nf-fa-bar_chart before the headline, U+F071 nf-fa-warning replaces ⚠.
ICONS = {"headline": "\uf080 ", "warning": "\uf071 "}
PLAIN = {"border": None, "icons": {"headline": "", "warning": "⚠ "}, "styles": {}}
SGR = "\x1b[{}m"


def sgr(spec):
    """'bold on-blue #ff8800' → one SGR prefix; refuses any other token, e.g. 'blink', 'on-bold' or '#fff'."""
    codes = []
    for token in spec.split():
        background, name = (True, token[3:]) if token.startswith("on-") else (False, token)
        bright = name.startswith("bright-")
        if not background and name in ATTRIBUTES:
            codes.append(ATTRIBUTES[name])
        elif re.fullmatch(r"#[0-9a-fA-F]{6}", name):
            codes += [48 if background else 38, 2, *bytes.fromhex(name[1:])]
        elif name.removeprefix("bright-") in COLORS:
            codes.append(30 + 10 * background + 60 * bright + COLORS.index(name.removeprefix("bright-")))
        else:
            raise ValueError(f"unknown summary style token {token!r}")
    return SGR.format(";".join(map(str, codes))) if codes else ""


def load(path=None, stream=None, environ=os.environ):
    """The --summary-theme JSON resolved for stream; refuses unknown keys, enum values, elements and style tokens."""
    if not path:  # No --summary-theme: plain even on a TTY, so an install without a theme keeps its exact output.
        return PLAIN
    theme = json.loads(Path(path).read_text())
    if not isinstance(theme, dict) or theme.keys() - {"border", "color", "icons", "styles"}:
        raise ValueError(f"summary theme must be an object of border, color, icons and styles: {theme!r}")
    color, border = theme.get("color", "auto"), theme.get("border", "none")
    styles, icons = theme.get("styles", {}), theme.get("icons", False)
    # The str checks refuse unhashable JSON values such as {"border": []}, which would raise TypeError in the lookups.
    if (not isinstance(color, str) or color not in COLOR_MODES or not isinstance(border, str)
            or border != "none" and border not in BORDERS or not isinstance(icons, bool)):
        raise ValueError(f"summary theme needs color in {COLOR_MODES}, border none or in {tuple(BORDERS)}, and boolean icons")
    if not isinstance(styles, dict) or styles.keys() - set(ELEMENTS) or not all(isinstance(spec, str) for spec in styles.values()):
        raise ValueError(f"summary theme styles must map {', '.join(ELEMENTS)} to style strings: {styles!r}")
    painted = {element: sgr(spec) for element, spec in {**DEFAULTS, **styles}.items()}  # parse even when color is off
    on = color == "always" or color == "auto" and (stream or sys.stderr).isatty() and not environ.get("NO_COLOR")
    return {"border": BORDERS.get(border), "icons": ICONS if icons else PLAIN["icons"], "styles": painted if on else {}}


def painter(theme):
    """paint(elements, text): later elements override earlier ones; unstyled or empty text stays byte-identical."""
    def paint(elements, text):
        prefix = "".join(theme["styles"].get(element, "") for element in elements)
        return f"{prefix}{text}{SGR.format(0)}" if prefix and text else text
    return paint


def box(theme, plain, styled, rules):
    """Close styled lines in the theme border, padded from their plain twins; indexes in rules become T-junction lines."""
    corner, horizontal, corner_right, vertical, tee, tee_right, bottom, bottom_right = theme["border"]
    paint, width = painter(theme), max(map(len, plain))
    edge = lambda left, right: paint(("border",), left + horizontal * (width + 2) + right)
    side = paint(("border",), vertical)
    return [edge(corner, corner_right),
            *(edge(tee, tee_right) if index in rules else f"{side} {line}{' ' * (width - len(text))} {side}"
              for index, (text, line) in enumerate(zip(plain, styled))),
            edge(bottom, bottom_right)]
