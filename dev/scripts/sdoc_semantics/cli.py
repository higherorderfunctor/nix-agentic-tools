# cspell:ignore sdoc sgra mermaid argparse
"""`python -m sdoc_semantics [--json|--mermaid] [FIELD|TYPE]`.

The rendering is SHARED with `scribe semantics`, deliberately: two listings of
one model are two things obliged to agree, and the failure would be silent --
an operator reshaping a rung would see it in one place and not the other. The
scribe subcommand hands its own already-parsed grammar to `render`; nothing is
re-implemented there.

The grammar arrives as the `parse_sgra` dict. Nothing in this package imports
strictdoc, and nothing loads the corpus: which types carry a field is a
property of `docs/sdoc/grammar.sgra`, which is a file.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import SEMANTICS
from .engine import mermaid

# dev/scripts, so `scribe_grammar` resolves when this package is reached as a
# plain script path as well as with `-m`.
_SCRIPTS = str(Path(__file__).resolve().parent.parent)
if _SCRIPTS not in sys.path:
    sys.path.insert(0, _SCRIPTS)

from scribe_grammar import parse_sgra  # noqa: E402

#: Repository root as seen from dev/scripts/sdoc_semantics/cli.py.
REPO_ROOT = Path(__file__).resolve().parents[3]

GRAMMAR_RELATIVE = Path("docs") / "sdoc" / "grammar.sgra"


def load_grammar(root: Path) -> dict:
    return parse_sgra(root / GRAMMAR_RELATIVE)


def select(data: dict, selector: str | None) -> list[str]:
    """FIELD, or TYPE, or everything. Refuses anything else by name.

    A TYPE selector goes through `by_type`, which is the same reverse index
    the board reads, so `scribe semantics DECISION` and the board's inspector
    can never disagree about which machines a type has.
    """
    if not selector:
        return list(data["machines"])
    wanted = selector.upper()
    if wanted in data["machines"]:
        return [wanted]
    if wanted in data["by_type"]:
        return list(data["by_type"][wanted])
    raise SystemExit(
        f"no machine or node type named {selector!r}. "
        f"fields: {', '.join(data['machines'])}. "
        f"types: {', '.join(data['by_type'])}"
    )


def _move_flag(settled: bool) -> str:
    """OPEN shouts on purpose: an unsettled MOVE is a decision owed."""
    return "settled" if settled else "OPEN"


def _rule_flag(settled: bool) -> str:
    return "settled" if settled else "unsettled"


def render(data: dict, selector: str | None = None) -> str:
    """The readable listing. One block per machine, ladder order preserved."""
    lines: list[str] = []
    chosen = select(data, selector)
    if not chosen:
        return f"{selector}: no state field on this type\n"
    for field in chosen:
        entry = data["machines"][field]
        lines.append(f"{field}   [{data['schema']}]")
        lines.append(f"  on        {', '.join(entry['applies_to']) or '(no type)'}")
        lines.append(
            f"  initial   {entry['initial']}"
            f"        terminal   {', '.join(entry['terminal']) or '(none)'}"
        )
        lines.append("  states")
        width = max((len(state["name"]) for state in entry["states"]), default=0)
        for index, state in enumerate(entry["states"], start=1):
            note = state.get("note", "")
            lines.append(
                f"    {index}. {state['name']:<{width}}  {note}".rstrip()
            )
        lines.append("  transitions")
        trigger_width = max(
            (len(transition["trigger"]) for transition in entry["transitions"]),
            default=0,
        )
        for transition in entry["transitions"]:
            gates = ", ".join(transition["conditions"]) or "-"
            arrow = f"--{transition['trigger']}-->".ljust(trigger_width + 5)
            lines.append(
                f"    {transition['source']:<{width}} {arrow} "
                f"{transition['dest']:<{width}}  [{_move_flag(transition['settled'])}] "
                f"gates: {gates}"
            )
            if transition["rule_text"]:
                lines.append(f"        {transition['rule_text']}")
        lines.append("  rules")
        for rule in entry["rules"]:
            cites = f"  cites {', '.join(rule['cites'])}" if rule["cites"] else ""
            lines.append(
                f"    [{rule['kind']}/{_rule_flag(rule['settled'])}] {rule['id']}{cites}"
            )
            lines.append(f"        {rule['text']}")
        if entry["diagnostics"]:
            lines.append("  diagnostics")
            for message in entry["diagnostics"]:
                lines.append(f"    ! {message}")
        lines.append("")
    return "\n".join(lines) + "\n"


def render_mermaid(data: dict, selector: str | None = None) -> str:
    out: list[str] = []
    for field in select(data, selector):
        out.append(f"%% {field}")
        drawn = mermaid(SEMANTICS[field])
        out.append(drawn if drawn else "%% (diagram extra unavailable)")
        out.append("")
    return "\n".join(out) + "\n"


def build_payload(grammar: dict) -> dict:
    """Re-exported from the package root, which is where consumers reach it."""
    from . import build_payload as _build_payload

    return _build_payload(grammar)


def emit(
    data: dict,
    selector: str | None = None,
    *,
    as_json: bool = False,
    as_mermaid: bool = False,
) -> str:
    """ONE dispatch over the three output shapes.

    Both front ends call this -- `python -m sdoc_semantics` below and
    `scribe semantics` in dev/scripts/scribe_cmd.py. A second copy of this
    if-chain would be a second thing obliged to agree, and the disagreement
    would be silent: an operator reshaping a rung would see it rendered one
    way in the shell and another in the other shell.
    """
    if as_json:
        out = data
        if selector:
            chosen = select(data, selector)
            out = dict(
                data, machines={field: data["machines"][field] for field in chosen}
            )
        return json.dumps(out, indent=2) + "\n"
    if as_mermaid:
        return render_mermaid(data, selector)
    return render(data, selector)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="sdoc_semantics",
        description=(
            "the state-field lifecycles this repository claims, and the rules "
            "nobody has settled yet"
        ),
    )
    parser.add_argument(
        "selector",
        nargs="?",
        metavar="FIELD|TYPE",
        help="one state field (DEPTH) or one node type (DECISION); default all",
    )
    parser.add_argument("--root", help="repository root (default: derived)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="the sdoc-semantics/1 payload")
    output.add_argument("--mermaid", action="store_true", help="stateDiagram-v2 per machine")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve() if args.root else REPO_ROOT
    try:
        grammar = load_grammar(root)
    except OSError as exc:
        print(f"sdoc_semantics: {exc}", file=sys.stderr)
        return 1

    data = build_payload(grammar)
    try:
        sys.stdout.write(
            emit(data, args.selector, as_json=args.json, as_mermaid=args.mermaid)
        )
    except SystemExit as exc:
        if isinstance(exc.code, str):
            print(f"sdoc_semantics: {exc.code}", file=sys.stderr)
            return 1
        raise
    return 0
