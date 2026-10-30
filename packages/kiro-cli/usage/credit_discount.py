"""Experimental credit-price fits: a discount diagnostic and ~token/cache estimates; never exact counters."""

import json
import math
from pathlib import Path

PROFILE = "opus-5.5-low-text1to5-context-v1"
EPSILON = 1e-6  # Numerical credit tolerance, not a statistical confidence interval.
CONTEXT_RANGE = (.87679994, 3.6423001)
ASSUMPTIONS = (
    "Initial ten-call calibration; not a percentile accuracy guarantee.",
    "Same model/effort, retained completed text-only responses of 1–5 characters.",
    "Context is reported percent; no context-window or token conversion.",
    "Credit discounts can reflect billing/routing; they do not prove cache hits.",
)
PROFILE_MODEL = "claude-opus-5.5"
# The profile's curves: credits*SCALE = slope*context% + intercept, for full cache misses and full hits. Frozen
# with PROFILE; rates.json's entry for PROFILE_MODEL started from them, and refits there leave the profile alone.
SCALE, MISS, HIT = 603, (74, .5034), (20, .5970)
MODELS_PATH, RATES_PATH = (Path(__file__).with_name(name) for name in ("models.json", "rates.json"))
FACTS = json.loads(MODELS_PATH.read_text())  # `calibration.py models` snapshots kiro-cli chat --list-models.
ROUTERS = {"auto"}  # Listed, but routes to an unknown real model, so its context% has no fixed window.
WINDOWS = {model: facts["context_window_tokens"] for model, facts in FACTS["models"].items() if model not in ROUTERS}
RATES = json.loads(RATES_PATH.read_text())  # Fitted credits per token and per call; `calibration.py fit --write`.
CHARS_PER_TOKEN = 4  # estimate()'s output chars per token for a model without a fitted chars_per_token


def finite(number):
    return isinstance(number, (int, float)) and not isinstance(number, bool) and math.isfinite(number)


def count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def preflight(facts):
    """Reject scalar mismatches before callers inspect retained event evidence."""
    checks = (
        (facts.get("model") == PROFILE_MODEL, "unsupported_model"),
        (facts.get("effort") == "low", "unsupported_effort"),
        (facts.get("complete") is True, "incomplete_capture"),
        (count(facts.get("chars")) and 1 <= facts["chars"] <= 5, "unsupported_output_length"),
    )
    for valid, reason in checks:
        if not valid:
            return {"classification": "excluded", "reason": reason}
    context, credits = facts.get("context"), facts.get("credits")
    for number, reason in ((context, "invalid_context"), (credits, "invalid_credits")):
        if not finite(number):
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
    baseline = (MISS[0] * context + MISS[1]) / SCALE
    discounted = (HIT[0] * context + HIT[1]) / SCALE
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


def price(rates, input, output, cached):
    """Credits for one call: the fixed cost, uncached input at the miss rate, cached input (at most the input, so a
    whole-input hit is a full hit) at the hit rate, output."""
    cached = min(cached, input)
    return (rates["fixed_per_call"] + rates["miss_input"] * (input - cached) + rates["hit_input"] * cached
            + rates["output"] * output)


def estimate(model, context, credits, chars, output=None, input=None, ratio=None):
    """~Tokens for one call: total from context% and window, output ~chars/chars_per_token, cached from credits.

    Rates are the model's fitted credits per miss/hit input token and output token, plus a fixed cost per call.
    Exact output/input of the same call replace their guesses, so cached never exceeds exact input.
    Unknown parts are None: no window means nothing; no fitted rates, credits or output means no cache split.
    """
    window = WINDOWS.get(model)
    if window is None or not finite(context) or context < 0:
        return None
    total = round(context / 100 * window)  # includes output tokens once
    rates = RATES.get(model, {})
    if not count(output):
        # ratio overrides the fitted chars_per_token (`calibration.py fit --write`) while calibration.fit fits its own.
        output = min(round(chars / (ratio or rates.get("chars_per_token", CHARS_PER_TOKEN))), total) if count(chars) else None
    if not count(input):
        input = max(total - output, 0) if output is not None else None
    result = {"total_tokens": total, "input_tokens": input, "output_tokens": output, "cache_read_tokens": None}
    if input is not None and output is not None and rates and finite(credits):
        cached = (price(rates, input, output, 0) - credits) / (rates["miss_input"] - rates["hit_input"])
        result["cache_read_tokens"] = round(min(max(cached, 0), input))
    return result
