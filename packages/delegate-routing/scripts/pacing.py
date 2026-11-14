"""Pure allowance ranking for normalized offers; no capture or routing decisions."""

import math


def weights(policy, pools):
    # Reject misspelled pools, future policy fields and unusable caller weights here.
    if policy is None:
        return {}
    if not isinstance(policy, dict) or policy.keys() - pools.keys():
        raise ValueError("invalid-policy")
    result = {}
    for pool, settings in policy.items():
        if not isinstance(settings, dict) or settings.keys() - {"weight"}:
            raise ValueError("invalid-policy")
        weight = settings.get("weight", 1)
        if (isinstance(weight, bool) or not isinstance(weight, (int, float))
                or not math.isfinite(weight) or weight < 0):
            raise ValueError("invalid-weight")
        result[pool] = weight
    return result


def allowance(limits, resolved, now):
    # Consume normalized validity and enforcement; never repair or advance observations.
    paces = []
    unknown = not resolved
    blocked = False
    for limit in limits:
        remaining = limit["remaining"]
        if remaining == 0:
            # Independent measured zero survives unknown scope or malformed timing.
            blocked = True
            if limit["role"] == "pace":
                paces.append(0)
            continue
        if limit["status"] != "valid" or limit["enforced"] is not True or remaining is None:
            unknown = True
            continue
        if limit["role"] == "gate":
            # A positive valid rolling gate is open, even without a reset timestamp.
            continue
        reset = limit["naturalResetAt"]
        if reset is None or reset <= now:
            unknown = True
            continue
        pace = remaining / limit["capacity"] * limit["windowSeconds"] / (reset - now)
        if not math.isfinite(pace):
            unknown = True
            continue
        paces.append(pace)
    pace = 0 if 0 in paces else None if unknown or not paces else min(paces)
    ready = pace is not None and pace > 0 and not blocked and not unknown
    return pace, ready


def rank(snapshot, policy=None):
    """Retain the normalized snapshot and add explicitly applicable allowance entries."""
    pool_weights = weights(policy, snapshot["pools"])
    entries = []
    for offer in snapshot["routes"]:
        applicable = [
            (pool, evidence, [limit for limit in evidence["limits"] if offer["id"] in limit["models"]])
            for pool, evidence in sorted(snapshot["pools"].items())
        ]
        applicable = [item for item in applicable if item[2]]
        if not applicable:
            entries.append({**offer, "pace": None, "pool": None, "score": 0, "state": "out"})
        for pool, evidence, limits in applicable:
            pace, ready = allowance(limits, evidence["scopeResolved"], snapshot["asOf"])
            score = pace * pool_weights.get(pool, 1) if ready else 0
            if not math.isfinite(score):
                raise ValueError("invalid-weighted-score")
            entries.append({**offer, "pace": pace, "pool": pool, "score": score,
                            "state": "ready" if ready else "out"})
    entries.sort(key=lambda entry: (-entry["score"], entry["state"] != "ready",
                                  entry["pool"] or "", entry["model"], entry["id"], entry["maker"] or ""))
    return {**snapshot, "entries": entries}
