"""Extract OpenCode Go's model catalog and its per-plan monthly limits.

The catalog is JSON. Each entry is copied without `created` and `go`; its
`go.monthly_usage` maps every plan to the list-price dollars that empty that
plan's monthly pool, or is null for a model no plan meters.
"""

import json
import sys
from pathlib import Path

PLANS = {"go", "go-plus", "go-teams"}


def usage(model, go):
    """The model's limit per plan; an unknown shape is refused, never defaulted."""
    if not isinstance(go, dict) or "monthly_usage" not in go:
        raise ValueError(f"OpenCode Go catalog model {model} has no go.monthly_usage")
    limits = go["monthly_usage"]
    if limits is None:
        return dict.fromkeys(PLANS, "unlimited")
    if not isinstance(limits, dict) or set(limits) != PLANS:
        raise ValueError(f"OpenCode Go model {model} monthly usage plans changed: {limits}")
    for plan, value in limits.items():
        # bool is an int subclass; a flag is not a dollar amount.
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"OpenCode Go model {model} {plan} monthly usage is not a number: {value!r}")
    return limits


def extract(catalog):
    document = json.loads(catalog)
    if document.get("object") != "list" or not isinstance(document.get("data"), list):
        raise ValueError("OpenCode Go catalog is not a model list")
    models = {}
    monthly = {plan: {} for plan in PLANS}
    for entry in document["data"]:
        model = entry.get("id")
        if not isinstance(model, str) or not model or model in models:
            raise ValueError(f"OpenCode Go catalog id missing or duplicated: {model}")
        for plan, value in usage(model, entry.get("go")).items():
            monthly[plan][model] = value
        # `go` is read into monthlyLimits above and nowhere else.
        models[model] = {key: value for key, value in entry.items() if key not in {"created", "go"}}
    if not models:
        raise ValueError("OpenCode Go catalog is empty")
    return {"models": models, "monthlyLimits": monthly}


if __name__ == "__main__":
    (catalog,) = sys.argv[1:]
    print(json.dumps(extract(Path(catalog).read_text()), sort_keys=True))
