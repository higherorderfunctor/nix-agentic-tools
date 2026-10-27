"""Experimental credit-price diagnostic; never a tokenizer or cache-hit counter."""

import math

PROFILE = "opus-5.5-low-text1to5-context-v1"
EPSILON = 1e-6  # Numerical credit tolerance, not a statistical confidence interval.
CONTEXT_RANGE = (.87679994, 3.6423001)
ASSUMPTIONS = (
    "Initial ten-call calibration; not a percentile accuracy guarantee.",
    "Same model/effort, retained completed text-only responses of 1–5 characters.",
    "Context is reported percent; no context-window or token conversion.",
    "Credit discounts can reflect billing/routing; they do not prove cache hits.",
)


def preflight(facts):
    """Reject scalar mismatches before callers inspect retained event evidence."""
    checks = (
        (facts.get("model") == "claude-opus-5.5", "unsupported_model"),
        (facts.get("effort") == "low", "unsupported_effort"),
        (facts.get("complete") is True, "incomplete_capture"),
        (isinstance(facts.get("chars"), int) and not isinstance(facts.get("chars"), bool)
         and 1 <= facts["chars"] <= 5, "unsupported_output_length"),
    )
    for valid, reason in checks:
        if not valid:
            return {"classification": "excluded", "reason": reason}
    context, credits = facts.get("context"), facts.get("credits")
    for number, reason in ((context, "invalid_context"), (credits, "invalid_credits")):
        if not isinstance(number, (int, float)) or isinstance(number, bool) or not math.isfinite(number):
            return {"classification": "excluded", "reason": reason}
    if not CONTEXT_RANGE[0] <= context <= CONTEXT_RANGE[1]:
        return {"classification": "excluded", "reason": "context_outside_calibration"}
    return None


def classify(facts):
    refused = preflight(facts)
    if refused:
        return refused
    for key, reason in (("retained", "missing_retained_evidence"), ("terminal", "missing_or_ambiguous_terminal"),
                        ("text_only", "unproved_text_only_output"), ("no_reasoning_tools", "reasoning_or_tool_output")):
        if facts.get(key) is not True:
            return {"classification": "excluded", "reason": reason}
    context, credits = facts["context"], facts["credits"]
    baseline = (74 * context + .5034) / 603
    discounted = (20 * context + .5970) / 603
    if abs(credits - baseline) <= EPSILON:
        status = "baseline"
    elif discounted - EPSILON <= credits < baseline - EPSILON:
        status = "discount_like"
    else:
        status = "anomaly"
    score = (baseline - credits) / (baseline - discounted)
    return {"classification": status, "baseline_credits": baseline, "discounted_credits": discounted,
            "baseline_residual": credits - baseline, "discounted_residual": credits - discounted,
            "raw_discount_score": score if math.isfinite(score) else None,
            "score_overflow": not math.isfinite(score)}


def aggregate():
    return {"profile_id": PROFILE, "epsilon_credits": EPSILON, "assumptions": list(ASSUMPTIONS),
            "requests": 0, "eligible": 0, "baseline": 0, "discount_like": 0, "anomaly": 0,
            "excluded": 0, "percentage": None, "exclusion_reasons": {}, "diagnostics": []}


def add(report, result, capture_id):
    report["requests"] += 1
    status = result["classification"]
    report[status] += 1
    if status == "excluded":
        reason = result["reason"]
        report["exclusion_reasons"][reason] = report["exclusion_reasons"].get(reason, 0) + 1
    else:
        report["diagnostics"].append({"capture_id": capture_id, **result})
    report["eligible"] = report["baseline"] + report["discount_like"]
    report["percentage"] = (100 * report["discount_like"] / report["eligible"]
                            if report["eligible"] else None)
