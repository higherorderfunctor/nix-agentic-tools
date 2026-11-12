"""Independent reference for ordinary allowance ranking.

Recomputes active limits, cutoffs and rank with its own arithmetic: native
amount per second divided by sustainable capacity per second, a different
expression from scripts/pacing.py. Pool weights always apply. No production
imports; grants, credits and costs are deliberately absent.
"""


def rank(snapshot, policy=None):
    answer = []
    notes = list(snapshot["diagnostics"])
    instant = snapshot["asOf"]
    for route in sorted(snapshot["routes"], key=lambda r: (r["pool"], r["model"])):
        rows = [row for row in snapshot["pools"][route["pool"]]["limits"]
                if row["id"] in route["limits"] and row["enforced"] is not False]
        uncertain = sorted(row["id"] for row in rows
                           if row["enforced"] is None or row["status"] in ("missing", "invalid"))
        known = [row for row in rows if row["id"] not in uncertain]
        closed = sorted((row for row in known if row["remaining"] <= 1e-9), key=lambda row: row["id"])
        rates = {}
        for row in known:
            if row["role"] == "pace":
                horizon = max(row["windowSeconds"] / 1000000, row["naturalResetAt"] - instant)
                rates[row["id"]] = (row["remaining"] / horizon) / (row["capacity"] / row["windowSeconds"])
        lowest = sorted(rates, key=lambda key: (rates[key], key))
        binding = lowest[0] if lowest else None
        base = rates.get(binding)
        value = base
        returns = [row["gateOpensAt"] if row["role"] == "gate" else row["naturalResetAt"] for row in closed]
        available = None
        if closed:
            value, binding = 0.0, closed[0]["id"]
            if all(time is not None and time > instant for time in returns):
                available = max(returns)
            else:
                notes.append({"pool": route["pool"], "model": route["model"], "reason": "unknown-return"})
        elif uncertain:
            value, binding = None, None
        if uncertain or not rates:
            available = None
            missing_pools = {note["pool"] for note in snapshot["diagnostics"] if note["reason"] == "missing-capture"}
            if rows or route["pool"] not in missing_pools:
                notes.append({"pool": route["pool"], "model": route["model"], "reason": "uncertain-allowance", "limits": uncertain})
        stale = bool(uncertain or not rates) or any(
            row["status"] != "valid" or row["observedAt"] is None or instant - row["observedAt"] > 3600
            or (row["naturalResetAt"] is not None and row["naturalResetAt"] <= instant) for row in rows)
        answer.append({
            "available_at": available, "base_pace": None if uncertain else base,
            "binding_limit": binding, "cost": None, "expiring": None,
            "headroom": 0.0 if closed else None, "maker": route["maker"],
            "model": route["model"], "pace": value, "pool": route["pool"],
            "score": (value or 0) * (policy or {}).get(route["pool"], {}).get("weight", 1),
            "stale": stale, "usage_state": "ready" if value and not uncertain else "out",
        })
    answer.sort(key=lambda row: (-row["score"], {"ready": 0, "out": 3}[row["usage_state"]], row["pool"], row["model"]))
    return dict(snapshot, diagnostics=notes, entries=answer)
