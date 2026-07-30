#!/usr/bin/env python3
"""Check a finished run against the correctness predicate.

The predicate, from the design: every seeded item reaches a terminal state
exactly once; every LATE-PROPOSED item is worked too (the property waves get by
accident and a drain must get on purpose); the run terminates with every item in
a legal state; and no item is worked twice.

TWO DELIBERATE DUPLICATIONS, because sharing the code would make the check
vacuous:

1. :func:`predict_items` re-derives the whole expected item forest from the
   profile without importing ``queue_init.expand_seed`` or ``queuelib.push``.
   A shared expander would predict exactly the tree a bug in it produced.
2. :func:`closed_form_sum` uses the Gauss closed form where ``queuelib``
   iterates the range. Two formulas that agree are evidence; one formula
   agreeing with itself is not.

Exit codes: 0 every check passed, 2 at least one violation, 1 error.
"""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import queuelib as q  # noqa: E402


def closed_form_sum(a, b):
    """Gauss, not iteration. See the module docstring."""
    return (a + b) * (b - a + 1) // 2


def predict_items(profile, cap):
    """Predict the full item forest: id -> {depth, parent, state, units, a, b}.

    Independently written. Mirrors nothing; derived from the profile's declared
    contract only:

    * a seeded item is ``<id_prefix><1-based index, 2 digits>`` at depth 0;
    * a proposer with ``chain: C`` mints one child per link, each named
      ``<parent>.c1`` (one push per parent in a clean run), each one deeper;
    * the link whose depth would exceed the cap is minted ``dead`` and mints
      nothing further.
    """
    prefix = profile["id_prefix"]
    predicted = {}
    for index, units in enumerate(profile["durations"], start=1):
        start = 10 * index
        predicted[f"{prefix}{index:02d}"] = {
            "a": start,
            "b": start + int(units) + 2,
            "depth": 0,
            "parent": None,
            "state": "done",
            "units": int(units),
        }
    for spec in profile.get("proposers", []):
        parent = f"{prefix}{int(spec['seed_index']):02d}"
        depth = 0
        remaining = int(spec.get("chain", 1))
        units = int(spec.get("duration_units", 1))
        while remaining > 0:
            child = f"{parent}.c1"
            depth += 1
            start = predicted[parent]["b"] + 100
            over_cap = depth > cap
            predicted[child] = {
                "a": start,
                "b": start + units + 2,
                "depth": depth,
                "parent": parent,
                "state": "dead" if over_cap else "done",
                "units": units,
            }
            if over_cap:
                break
            remaining -= 1
            parent = child
    return predicted


def claim_intervals(events, lease_ttl_sec):
    """Reconstruct one interval per (item, gen, owner) from the event log.

    Keyed on the OWNER as well as the generation on purpose. A non-atomic claim
    lets two owners write the same generation marker, so the marker file only
    remembers whichever wrote last -- the event log is the only lossless record
    of who believed they held it.

    An interval with no matching release ends at its lease expiry, clamped to
    the last observed event. That is what makes a legitimate expired-lease steal
    NOT register as an overlap: the steal can only happen after the expiry the
    previous interval already ended at.
    """
    last_event = max((event["at_epoch"] for event in events), default=0.0)
    intervals = {}
    for event in events:
        if event.get("kind") != "claim.acquired":
            continue
        key = (event["item"], event["gen"], event["owner"])
        intervals.setdefault(key, []).append({"start": event["at_epoch"], "end": None})
    for event in events:
        if event.get("kind") != "claim.released":
            continue
        key = (event["item"], event["gen"], event["owner"])
        for interval in intervals.get(key, []):
            if interval["end"] is None and interval["start"] <= event["at_epoch"]:
                interval["end"] = event["at_epoch"]
                break
    flat = []
    for (item, gen, owner), spans in intervals.items():
        for span in spans:
            end = span["end"]
            if end is None:
                end = min(span["start"] + float(lease_ttl_sec), max(last_event, span["start"]))
            flat.append(
                {"end": end, "gen": gen, "item": item, "owner": owner, "start": span["start"]}
            )
    flat.sort(key=lambda span: (span["item"], span["start"], span["gen"]))
    return flat


def main(argv=None):  # noqa: C901 - a checklist reads better flat than split
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument(
        "--no-expect-set",
        action="store_true",
        help=(
            "skip the exact predicted-item-set comparison. Needed only for runs "
            "with deliberate failures or kills, where a retried parent may push "
            "a second child."
        ),
    )
    parser.add_argument(
        "--allow-not-drained",
        action="store_true",
        help="skip the drained-flag check (for mid-run inspection)",
    )
    args = parser.parse_args(argv)

    root = Path(args.root)
    config = q.load_config(root)
    cap = int(config["max_lineage_depth"])
    profile_path = Path(config["profile_path"])
    profile = q.read_json(profile_path)
    if profile is None:
        raise q.QueueError(f"cannot re-read the profile at {profile_path}")

    items = {item["id"]: item for item in q.list_items(root)}
    events = q.read_events(root)
    status = q.read_json(q.status_path(root))
    checks = []
    violations = []

    def check(name, ok, detail=""):
        checks.append({"detail": detail, "name": name, "ok": bool(ok)})
        if not ok:
            violations.append({"detail": detail, "name": name})

    # 0. Denominator. Every check below is vacuous without it.
    check(
        "denominator-nonzero",
        len(items) > 0 and len(events) > 0,
        f"{len(items)} item(s), {len(events)} event(s)",
    )
    if not items:
        print(json.dumps({"checks": checks, "ok": False, "violations": violations}, indent=2, sort_keys=True))
        return q.EXIT_VIOLATION

    # 1. The item set is exactly what the profile predicts.
    predicted = predict_items(profile, cap)
    if not args.no_expect_set:
        missing = sorted(set(predicted) - set(items))
        extra = sorted(set(items) - set(predicted))
        check(
            "item-set-matches-prediction",
            not missing and not extra,
            f"missing={missing} extra={extra} predicted={len(predicted)}",
        )
        late = sorted(name for name, spec in predicted.items() if spec["depth"] > 0)
        worked_late = sorted(
            name
            for name in late
            if name in items and items[name].get("state") == predicted[name]["state"]
        )
        check(
            "late-proposed-items-worked",
            bool(late) and worked_late == late,
            f"{len(worked_late)}/{len(late)} late-proposed items in the predicted state",
        )
        # The prediction covers the payload and the depth, not just the id set.
        # Without this, `queue_push` could derive every child's range wrongly and
        # the run would still verify, because the answers would agree with the
        # wrong payloads.
        mismatched = []
        for name, spec in sorted(predicted.items()):
            item = items.get(name)
            if item is None:
                continue
            actual = (
                int(item["payload"]["a"]),
                int(item["payload"]["b"]),
                int(item["duration_units"]),
                int(item.get("lineage_depth", 0)),
            )
            wanted = (spec["a"], spec["b"], spec["units"], spec["depth"])
            if actual != wanted:
                mismatched.append(f"{name}: {actual} != predicted {wanted}")
        check(
            "payload-and-depth-match-prediction",
            not mismatched,
            f"{mismatched}",
        )

    # 2. Every item is terminal, and a dead item says why. The DERIVED state is
    #    what is checked: a still-held lease or an un-admitted proposal is not
    #    terminal even though the item file's own `state` field can look benign.
    non_terminal = sorted(
        name
        for name, item in items.items()
        if q.view_state(root, item) not in q.TERMINAL_STATES
    )
    check("all-items-terminal", not non_terminal, f"non-terminal={non_terminal}")
    unexplained = sorted(
        name
        for name, item in items.items()
        if item.get("state") == "dead" and not item.get("dead_letter_reason")
    )
    check("dead-items-carry-a-reason", not unexplained, f"unexplained={unexplained}")

    # 3. Answers. Recomputed from the payload with the other formula, so a
    #    dropped item cannot pass by having copied its own `expected` field.
    wrong_answer = []
    missing_result = []
    stale_expected = []
    for name, item in items.items():
        payload = item["payload"]
        truth = closed_form_sum(int(payload["a"]), int(payload["b"]))
        if item.get("expected") != truth:
            stale_expected.append(f"{name}: expected={item.get('expected')} truth={truth}")
        if item.get("state") == "dead":
            continue
        result = q.read_json(q.result_path(root, name))
        if result is None:
            missing_result.append(name)
            continue
        if result.get("answer") != truth or item.get("answer") != truth:
            wrong_answer.append(
                f"{name}: result={result.get('answer')} item={item.get('answer')} truth={truth}"
            )
    check("item-expected-field-is-correct", not stale_expected, f"{stale_expected}")
    check("every-worked-item-has-a-result", not missing_result, f"missing={missing_result}")
    check("every-answer-is-correct", not wrong_answer, f"{wrong_answer}")

    # 4. Lineage. Depth is derived, so it must agree with the parent chain.
    bad_lineage = []
    over_cap_alive = []
    for name, item in items.items():
        parent_id = item.get("derived_from")
        depth = int(item.get("lineage_depth", 0))
        if parent_id is None:
            if depth != 0:
                bad_lineage.append(f"{name}: depth={depth} with no parent")
            continue
        parent = items.get(parent_id)
        if parent is None:
            bad_lineage.append(f"{name}: parent {parent_id} does not exist")
        elif depth != int(parent.get("lineage_depth", 0)) + 1:
            bad_lineage.append(
                f"{name}: depth={depth} but parent {parent_id} is at "
                f"{parent.get('lineage_depth')}"
            )
        if depth > cap and item.get("state") != "dead":
            over_cap_alive.append(f"{name}: depth={depth} cap={cap} state={item['state']}")
    check("lineage-depth-is-parent-plus-one", not bad_lineage, f"{bad_lineage}")
    check("over-cap-items-are-dead-lettered", not over_cap_alive, f"{over_cap_alive}")

    # 5. Double-claim detection. Three independent signals, all reported so a
    #    control run cannot be credited with a signature it did not fire.
    per_item_gen = {}
    for event in events:
        if event.get("kind") == "claim.acquired":
            key = (event["item"], event["gen"])
            per_item_gen.setdefault(key, []).append(event["owner"])
    multi = sorted(
        f"{item}#{gen} claimed by {sorted(owners)}"
        for (item, gen), owners in per_item_gen.items()
        if len(owners) > 1
    )
    check("one-acquire-per-item-generation", not multi, f"{multi}")

    intervals = claim_intervals(events, config["lease_ttl_sec"])
    overlaps = []
    by_item = {}
    for span in intervals:
        by_item.setdefault(span["item"], []).append(span)
    for item_id, spans in by_item.items():
        for i in range(len(spans)):
            for j in range(i + 1, len(spans)):
                left, right = spans[i], spans[j]
                if left["start"] < right["end"] and right["start"] < left["end"]:
                    overlaps.append(
                        f"{item_id}: gen{left['gen']}/{left['owner']} overlaps "
                        f"gen{right['gen']}/{right['owner']}"
                    )
    check("no-overlapping-claim-intervals", not overlaps, f"{overlaps}")

    kinds = {}
    for event in events:
        kinds[event.get("kind")] = kinds.get(event.get("kind"), 0) + 1
    check(
        "no-double-completion-events",
        not kinds.get("item.double_completion"),
        f"{kinds.get('item.double_completion', 0)} event(s)",
    )
    check(
        "no-claim-owner-mismatch-events",
        not kinds.get("claim.owner_mismatch"),
        f"{kinds.get('claim.owner_mismatch', 0)} event(s)",
    )

    # 6. Termination. The flag has to be published, not merely true in spirit.
    if not args.allow_not_drained:
        check(
            "status-file-reports-drained",
            isinstance(status, dict) and status.get("drained") is True,
            f"status={None if status is None else status.get('drained')}",
        )

    report = {
        "checks": sorted(checks, key=lambda entry: entry["name"]),
        "counts": {
            "dead": sum(1 for i in items.values() if i.get("state") == "dead"),
            "done": sum(1 for i in items.values() if i.get("state") == "done"),
            "events": len(events),
            "items": len(items),
            "predicted": len(predicted),
        },
        "event_kinds": dict(sorted(kinds.items())),
        "ok": not violations,
        "profile": config.get("profile"),
        "root": str(root),
        "violations": sorted(violations, key=lambda entry: entry["name"]),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return q.EXIT_OK if not violations else q.EXIT_VIOLATION


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_verify", main))
