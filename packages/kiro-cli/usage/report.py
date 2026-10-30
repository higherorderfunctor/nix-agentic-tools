"""Report captured usage at the current rates: every capture by local day and model, or named session trees, every run included, in the exit summary's look."""

import argparse
from contextlib import closing
from datetime import datetime
import json
from pathlib import Path
import sqlite3
import sys

import query
import summary_theme


def day(text):
    """A YYYY-MM-DD bound, normalized; refuses any other form, e.g. 2026-10 or 20261030."""
    return datetime.strptime(text, "%Y-%m-%d").date().isoformat()


def store_report(db, since=None, until=None):
    """Every capture, attributed or not, whose local start day falls within the inclusive bounds: total, days, models."""
    db.row_factory = sqlite3.Row
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='captures'").fetchone():
        raise ValueError("no capture source has initialized this database")
    bounded, bounds = query.window(since, until)
    captures, groups = query.aggregate(db, query.chosen_calls(bounded), bounds,
                                       {"days": (query.DAY.format("chosen"), ()), "models": (query.MODEL, ())})
    captures["days"] = [{"day": key, **source} for key, source in groups["days"].items()]
    captures["models"] = [{"requested_model": model, **source} for model, source in groups["models"].items()]
    return {"since": since, "until": until, "captures": captures}


def render(report, theme=summary_theme.PLAIN):
    """The store report in the exit summary's look: a day table and a model table, each with a Total row."""
    captures, since, until = report["captures"], report["since"], report["until"]
    days = [(source["day"], source) for source in captures["days"]]
    return query.summary_text("all captures" + (f" · {since or '…'} – {until or '…'}" if since or until else ""), captures,
                              [("Day", "label", days, True), ("Model", "model", query.by_credits(captures["models"]), True)], (), theme)


def main():
    zone = datetime.now().astimezone().tzname()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--json", action="store_true", help="write the store report, or the list of session reports, as JSON")
    parser.add_argument("--session", action="append", metavar="ID",
                        help="show this session tree, every run included, in the exit summary's look instead of the store report; repeat it for each root after a switch or fork")
    parser.add_argument("--since", type=day, metavar="YYYY-MM-DD", help=f"first day to include, in local time ({zone}); inclusive")
    parser.add_argument("--summary-theme", help="the exit summary's theme JSON; kiro-usage passes its configured one")
    parser.add_argument("--until", type=day, metavar="YYYY-MM-DD", help=f"last day to include, in local time ({zone}); inclusive")
    args = parser.parse_args()
    try:
        uri = args.db.resolve().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True)) as db:
            reports = ([query.query(db, session, "tree", args.since, args.until) for session in args.session] if args.session
                       else [store_report(db, args.since, args.until)])
            if args.json:
                print(json.dumps(reports if args.session else reports[0], indent=2, sort_keys=True))
            else:
                theme = summary_theme.load(args.summary_theme, sys.stdout)
                print("\n\n".join((query.render_summary if args.session else render)(report, theme=theme) for report in reports))
                print(query.calculator_text(reports))
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f"cannot query calibration database: {error}\n")


if __name__ == "__main__":
    main()
