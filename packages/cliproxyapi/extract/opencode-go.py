"""Extract OpenCode Go's model catalog and its per-plan monthly limits.

The catalog is JSON and is copied. The Go page is served as MDX source: its
plan tabs are HTML blocks around slot bodies that CommonMark reads as indented
code, so each slot body is parsed again as Markdown and the tags are read with
an HTML parser. Limit rows carry display names; the page's own endpoint table
maps those names to model IDs exactly.
"""

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

from markdown_it import MarkdownIt

PLANS = {"go", "go-plus", "go-teams"}
# The MDX plan tab component; html.parser lowercases tag names.
TABS = "PlanTabs".lower()
# Plan tab groups on the page, classified before reading: an unknown group may
# hold limits this extractor would otherwise miss.
LIMIT_GROUPS = {"go-pricing"}
EXCLUDED_GROUPS = {"go-requests"}
# Documented models the Go catalog does not serve (measured 2026-10-30). Each
# entry must stay documented and absent from the catalog; either change fails.
DOCUMENTED_ONLY = {"mimo-v2.5", "mimo-v2.5-pro"}


class Tags(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.events = []
        self.feed(source)
        self.close()

    def handle_starttag(self, tag, attrs):
        self.events.append(("start", tag, dict(attrs)))

    def handle_endtag(self, tag):
        self.events.append(("end", tag, {}))


def tables(tokens):
    """Each table as (header cells, body rows), cells as inline tokens."""
    found = []
    rows = None
    for token in tokens:
        if token.type == "table_open":
            rows = []
        elif token.type == "table_close":
            found.append((rows[0], rows[1:]))
            rows = None
        elif rows is not None and token.type == "tr_open":
            rows.append([])
        elif rows is not None and token.type == "inline":
            rows[-1].append(token)
    return found


def column(header, name):
    labels = [cell.content for cell in header]
    if labels.count(name) != 1:
        raise ValueError(f"OpenCode Go table header changed shape: {labels}")
    return labels.index(name)


# The pinned limit cell forms, as inline tokens with empty text dropped: a
# bold amount, or bold Unlimited with the limited-time note. Anything else in
# the cell (a second amount, a footnote) is refused rather than ignored.
UNLIMITED_NOTE = [("html_inline", "<br />"), ("html_inline", "<small>"), ("text", "limited time"), ("html_inline", "</small>")]


def limit(cell):
    shape = [(child.type, child.content) for child in cell.children if child.type != "text" or child.content]
    if len(shape) < 3 or [kind for kind, _ in shape[:3]] != ["strong_open", "text", "strong_close"]:
        raise ValueError(f"OpenCode Go monthly limit cell changed shape: {cell.content}")
    # The strong span is already decoded to one string; no parser reads a
    # currency amount out of it.
    value, note = shape[1][1], shape[3:]
    if value == "Unlimited" and note == UNLIMITED_NOTE:
        return "unlimited"
    match = re.fullmatch(r"\$([0-9]+)(\.[0-9]+)?", value)
    if match is None or note:
        raise ValueError(f"OpenCode Go monthly limit cell changed shape: {cell.content}")
    return float(match[0][1:]) if match[2] else int(match[1])


def base_name(name):
    # A decoded cell string; a trailing parenthesized qualifier (a token band,
    # a peak window, a discount) splits one model across rows. Only one group
    # at the very end is stripped, so a name holding parentheses elsewhere
    # still has to match the endpoint table exactly.
    match = re.fullmatch(r"(.*?) \([^()]+\)", name)
    return match[1] if match else name


def extract(catalog, page):
    document = json.loads(catalog)
    if document.get("object") != "list" or not isinstance(document.get("data"), list):
        raise ValueError("OpenCode Go catalog is not a model list")
    models = {}
    for entry in document["data"]:
        model = entry.get("id")
        if not isinstance(model, str) or not model or model in models:
            raise ValueError(f"OpenCode Go catalog id missing or duplicated: {model}")
        models[model] = {key: value for key, value in entry.items() if key != "created"}
    if not models:
        raise ValueError("OpenCode Go catalog is empty")

    markdown = MarkdownIt("commonmark").enable("table")
    group = slot = None
    slots = {}
    for token in markdown.parse(page):
        if token.type == "html_block":
            for kind, tag, attrs in Tags(token.content).events:
                if kind == "start" and tag == TABS:
                    if group is not None:
                        raise ValueError("OpenCode Go plan tabs nest")
                    group = attrs.get("id")
                    if group not in LIMIT_GROUPS | EXCLUDED_GROUPS:
                        raise ValueError(f"unclassified OpenCode Go plan tab group: {group}")
                    if group in slots:
                        raise ValueError(f"duplicate OpenCode Go plan tab group: {group}")
                    slots[group] = {}
                elif kind == "start" and tag == "div" and "slot" in attrs:
                    if group is None or slot is not None:
                        raise ValueError("OpenCode Go plan slot outside its tab group")
                    slot = attrs["slot"]
                    if slot not in PLANS or slot in slots[group]:
                        raise ValueError(f"unknown or duplicate OpenCode Go plan: {slot}")
                    slots[group][slot] = []
                elif kind == "end" and tag == "div" and slot is not None:
                    slot = None
                elif kind == "end" and tag == TABS:
                    if group is None or slot is not None:
                        raise ValueError("OpenCode Go plan tabs closed out of order")
                    if set(slots[group]) != PLANS:
                        raise ValueError(f"OpenCode Go plan tab group {group} lacks a plan")
                    group = None
        elif slot is not None and group in LIMIT_GROUPS:
            # A slot body is indented, so CommonMark reads it as code; any
            # other token is content outside the parsed body.
            if token.type != "code_block":
                raise ValueError(f"OpenCode Go plan slot {slot} holds unparsed {token.type}")
            slots[group][slot].extend(tables(markdown.parse(token.content)))
    if group is not None:
        raise ValueError("OpenCode Go plan tabs never closed")
    if set(slots) != LIMIT_GROUPS | EXCLUDED_GROUPS:
        raise ValueError(f"OpenCode Go plan tab groups changed: {sorted(slots)}")

    names = {}
    for header, rows in tables(markdown.parse(page)):
        if [cell.content for cell in header[:2]] != ["Model", "Model ID"]:
            continue
        if names:
            raise ValueError("OpenCode Go page has more than one endpoint table")
        for row in rows:
            name, model = row[0].content, row[1].content
            if not name or name in names or model in names.values():
                raise ValueError(f"OpenCode Go endpoint table row missing or duplicated: {name}")
            names[name] = model
    if not names:
        raise ValueError("OpenCode Go endpoint table missing")
    documented = set(names.values())
    if not DOCUMENTED_ONLY <= documented - set(models):
        raise ValueError(f"stale documented-only OpenCode Go models: {sorted(DOCUMENTED_ONLY - (documented - set(models)))}")
    if not documented <= set(models) | DOCUMENTED_ONLY:
        raise ValueError(f"OpenCode Go documents models its catalog lacks: {sorted(documented - set(models) - DOCUMENTED_ONLY)}")

    monthly = {}
    for plan in sorted(PLANS):
        found = [table for group in LIMIT_GROUPS for table in slots[group][plan]]
        if len(found) != 1:
            raise ValueError(f"OpenCode Go plan {plan} needs exactly one limit table")
        header, rows = found[0]
        model_column, limit_column = column(header, "Model"), column(header, "Monthly limit")
        limits = {}
        for row in rows:
            name = base_name(row[model_column].content)
            if name not in names:
                raise ValueError(f"OpenCode Go limit row maps to no model ID: {row[model_column].content}")
            model, value = names[name], limit(row[limit_column])
            if model in DOCUMENTED_ONLY:
                continue
            if limits.setdefault(model, value) != value:
                raise ValueError(f"OpenCode Go model {model} has conflicting {plan} monthly limits")
        if set(limits) != set(models):
            raise ValueError(f"OpenCode Go {plan} limits do not cover the catalog: {sorted(set(models) ^ set(limits))}")
        monthly[plan] = limits
    return {"models": models, "monthlyLimits": monthly}


if __name__ == "__main__":
    catalog, page = (Path(path).read_text() for path in sys.argv[1:])
    print(json.dumps(extract(catalog, page), sort_keys=True))
