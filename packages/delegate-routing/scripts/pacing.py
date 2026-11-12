"""Pure ordinary-allowance preview over normalized Reader observations."""

import math


def rank(snapshot, policy=None):
    """Keep every supplied catalog route; no Reader, clock or selection calls."""
    policy = {} if policy is None else policy
    # Saved snapshots and manual library callers bypass the Nix option types.
    if not isinstance(policy, dict) or set(policy) - set(snapshot["pools"]):
        raise ValueError("invalid-pacing-pools")
    weights = {}
    for pool, value in policy.items():
        if not isinstance(value, dict) or set(value) - {"weight"}:
            raise ValueError("invalid-pacing-policy")
        weight = value.get("weight", 1)
        if isinstance(weight, bool) or not isinstance(weight, (int, float)) or not math.isfinite(weight) or weight <= 0:
            raise ValueError("invalid-pacing-weight")
        weights[pool] = weight
    now = snapshot["asOf"]
    entries, diagnostics = [], list(snapshot["diagnostics"])
    for route in sorted(snapshot["routes"], key=lambda r: (r["pool"], r["model"])):
        pool = route["pool"]
        limits = {item["id"]: item for item in snapshot["pools"][pool]["limits"]}
        # A saved route may not escape its registered canonical model scope.
        if set(route["limits"]) != {key for key, item in limits.items() if route["model"] in item["models"]}:
            raise ValueError("invalid-route-limit")
        drawn = [limits[key] for key in sorted(set(route["limits"])) if limits[key]["enforced"] is not False]
        paced, blocked, unknown = [], [], []
        stale = False
        for limit in drawn:
            identifier = limit["id"]
            reset = limit["naturalResetAt"]
            stale |= limit["status"] != "valid" or limit["observedAt"] is None or now - limit["observedAt"] > 3600
            stale |= reset is not None and reset <= now
            if limit["status"] in {"invalid", "missing"} or limit["enforced"] is None:
                unknown.append(identifier)
                continue
            if limit["remaining"] <= 1e-9:
                blocked.append((identifier, limit["gateOpensAt"] if limit["role"] == "gate" else reset))
            if limit["role"] == "pace":
                fraction = max(1e-6, (reset - now) / limit["windowSeconds"])
                paced.append((limit["remaining"] / limit["capacity"] / fraction, identifier))
        base, binding = min(paced, default=(None, None))
        pace, available = base, None
        if blocked:
            pace, binding = 0.0, min(key for key, _ in blocked)
            times = [time for _, time in blocked]
            if all(time is not None and time > now for time in times):
                available = max(times)
            else:
                diagnostics.append({"pool": pool, "model": route["model"], "reason": "unknown-return"})
        elif unknown or not paced:
            pace, binding = None, None
        if unknown or not paced:
            stale = True
            available = None
            # An unregistered allowance already has a pool-level missing-capture
            # diagnostic; keep that single cause instead of repeating it per model.
            if drawn or not any(item.get("pool") == pool and item["reason"] == "missing-capture" for item in snapshot["diagnostics"]):
                diagnostics.append({"pool": pool, "model": route["model"], "reason": "uncertain-allowance", "limits": unknown})
        state = "ready" if pace is not None and pace > 0 and not unknown else "out"
        if unknown:
            # A known blocker still proves zero; otherwise pace is unmeasured.
            pace = 0.0 if blocked else None
        entries.append({
            "available_at": available, "base_pace": None if unknown else base,
            "binding_limit": binding, "cost": None, "expiring": None,
            "headroom": 0.0 if blocked else None, "maker": route["maker"],
            "model": route["model"], "pace": pace, "pool": pool,
            "score": (pace or 0.0) * weights.get(pool, 1),
            "stale": stale, "usage_state": state,
        })
    # Only ready/out occur in this allowance preview; credit/reset states wait
    # for their observations and production consumer.
    entries.sort(key=lambda entry: (-entry["score"], entry["usage_state"] != "ready", entry["pool"], entry["model"]))
    return {**snapshot, "entries": entries, "diagnostics": diagnostics}
