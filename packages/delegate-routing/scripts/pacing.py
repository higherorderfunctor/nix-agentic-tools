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
    paces, releases, stale, unknown = [], [], [], []
    for limit in limits:
        identifier, remaining = limit["id"], limit["remaining"]
        reset = limit["naturalResetAt"]
        valid = limit["status"] == "valid" and limit["enforced"] is True
        if limit["status"] == "stale":
            stale.append(identifier)
        if remaining == 0:
            # Independent zero survives bad timing, but cannot promise a return.
            release = limit["gateOpensAt"] if limit["role"] == "gate" else reset
            releases.append(release if valid and release is not None and release > now else None)
            if not valid or releases[-1] is None:
                unknown.append(identifier)
            if limit["role"] == "pace":
                paces.append((0, identifier))
            continue
        if not valid or remaining is None:
            unknown.append(identifier)
            continue
        if limit["role"] == "gate":
            # A positive valid rolling gate is open, even without a reset timestamp.
            continue
        if reset is None or reset <= now:
            unknown.append(identifier)
            continue
        pace = remaining / limit["capacity"] * limit["windowSeconds"] / (reset - now)
        if not math.isfinite(pace):
            unknown.append(identifier)
            continue
        paces.append((pace, identifier))
    binding = min(paces) if paces else None
    uncertain = not resolved or bool(unknown)
    pace = 0 if binding and binding[0] == 0 else None if uncertain or not binding else binding[0]
    ready = pace is not None and pace > 0 and not releases and not uncertain
    # All blockers must have known future releases; never advance an expired reset.
    available = now if ready else (
        max(releases) if releases and None not in releases and not uncertain else None
    )
    return dict(available_at=available, binding_limit=binding[1] if binding else None,
                evidence=dict(scope_resolved=resolved, stale_limits=sorted(stale), unknown_limits=sorted(unknown)),
                pace=pace, state="ready" if ready else "out")


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
            entries.append({**offer, **allowance([], False, snapshot["asOf"]), "pool": None, "score": 0})
        for pool, evidence, limits in applicable:
            result = allowance(limits, evidence["scopeResolved"], snapshot["asOf"])
            score = result["pace"] * pool_weights.get(pool, 1) if result["state"] == "ready" else 0
            if not math.isfinite(score):
                raise ValueError("invalid-weighted-score")
            entries.append({**offer, **result, "pool": pool, "score": score})
    entries.sort(key=lambda entry: (-entry["score"], entry["state"] != "ready",
                                  entry["pool"] or "", entry["model"], entry["id"],
                                  entry["maker"] is not None, entry["maker"] or ""))
    return {**snapshot, "entries": entries}
