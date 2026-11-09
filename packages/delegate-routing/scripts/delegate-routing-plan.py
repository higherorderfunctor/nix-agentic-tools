"""Read registered budgets and print routing specifications; never launch delegates."""

import argparse
from datetime import datetime, timedelta, timezone
import fnmatch
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys

# Tier is a floor, never evidence of semantic fit, trial status or independence.
ROLE_TIERS = {
    "finder": {"strong", "frontier"},
    "first-check": {"strong", "frontier"},
    "investigator": {"small", "mid", "strong", "frontier"},
    "judge": {"strong", "frontier"},
    "mechanical": {"small", "mid", "strong", "frontier"},
    "second-check": {"strong", "frontier"},
    "writer": {"small", "mid", "strong", "frontier"},
}
READER_TIMEOUT = 10


def utc(value):
    if not isinstance(value, str):
        raise ValueError("reset/evaluation time must be a timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.utcoffset() is None:
        raise ValueError("reset/evaluation time must include a UTC offset")
    if result.utcoffset() != timedelta(0):
        raise ValueError("reset/evaluation time must be UTC")
    return result.astimezone(timezone.utc)


def window_pace(window, now, scoped):
    if not isinstance(window, dict):
        raise ValueError("window must be an object")
    remaining, seconds = window["remainingPercent"], window["windowSeconds"]
    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in (remaining, seconds)):
        raise ValueError("invalid remainingPercent/windowSeconds")
    if not 0 <= remaining <= 100 or seconds <= 0:
        raise ValueError("invalid remainingPercent/windowSeconds")
    used = window["usedPercent"]
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not math.isclose(used + remaining, 100):
        raise ValueError("invalid/inconsistent usedPercent")
    if window["status"] is not None and not isinstance(window["status"], str):
        raise ValueError("window status must be a string or null")
    if scoped and window["resetsAt"] is None and used == 0 and remaining == 100:
        return None  # The Reader reports an unused family allowance with no reset.
    if window["resetsAt"] is None:
        raise ValueError("unstarted null reset unresolved")
    left = (utc(window["resetsAt"]) - now).total_seconds()
    if not 0 < left <= seconds:
        raise ValueError("expired reset or reset beyond window duration")
    return (remaining / 100) / (left / seconds)


def measure(stream, now):
    """Validate the stream; measure pool windows separately from family limits."""
    decoder, documents, rest = json.JSONDecoder(), [], stream.strip()
    while rest:
        document, end = decoder.raw_decode(rest)
        documents.append(document)
        rest = rest[end:].strip()
    if len(documents) != 1:
        raise ValueError("expected one account; account-to-route association unknown")
    document = documents[0]
    if not isinstance(document, dict) or not isinstance(document.get("account"), dict):
        raise ValueError("missing account record")
    # Require the shared Reader envelope even for metadata not used in arithmetic.
    if not all(key in document["account"] for key in ("auth_index", "name", "plan")):
        raise ValueError("account requires auth_index, name and plan")
    for field in ("auth_index", "name", "plan"):
        if document["account"][field] is not None and not isinstance(document["account"][field], str):
            raise ValueError(f"account {field} must be a string or null")
    if not isinstance(document.get("pool"), str) or not document["pool"].strip():
        raise ValueError("pool must be a nonempty string")
    for field in ("balances", "bonuses"):
        if not isinstance(document.get(field), list):
            raise ValueError(f"{field} must be an array")
    windows = document["windows"]
    if not isinstance(windows, dict) or not windows:
        raise ValueError("missing windows")
    paces, shares, scoped, scoped_errors = [], [], {}, {}
    for name, window in windows.items():
        is_scoped = ":" in name
        try:
            pace = window_pace(window, now, is_scoped)
        except (KeyError, TypeError, ValueError) as error:
            if not is_scoped:
                raise
            scoped[name] = None
            scoped_errors[name] = str(error)
            continue
        if is_scoped:
            scoped[name] = pace
        else:
            paces.append(pace)
            shares.append(window["remainingPercent"] / 100)
    if not paces:
        raise ValueError("missing unscoped windows for pool pace/buffer")
    result = {"buffer": min(shares), "pace": min(paces), "status": "measured"}
    if scoped:
        result["scopedPaces"] = scoped
    if scoped_errors:
        result["scopedErrors"] = scoped_errors
    return result


def run_reader(argv, **kwargs):
    # Timeout must reap the reader's shell children as well as the shell itself.
    timeout = kwargs.pop("timeout")
    with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def collect(readers, now, shell, run=run_reader):
    # Only this inventory reaches subprocess: candidate command guidance is data.
    commands, results = {}, {}
    for reader in readers:
        command = reader["command"]
        if command is None:
            result = {"reason": "no registered Reader", "status": "unmeasured"}
        elif command in commands:
            result = commands[command]
        else:
            try:
                proc = run([shell, "-euETo", "pipefail", "-c", "shopt -s inherit_errexit 2>/dev/null || :\n" + command], capture_output=True, text=True, timeout=READER_TIMEOUT)
                if proc.returncode:
                    raise ValueError(f"Reader exited {proc.returncode}")
                result = measure(proc.stdout, now)
            except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
                result = {"reason": str(error), "status": "unmeasured"}
            commands[command] = result
        results[reader["name"]] = result
    return results


def launch(route, context, qualification, requested):
    alternatives, exclusions = [], []
    for technique in route["techniques"]:
        name, node = technique["name"], technique["node"]
        reason = None
        if node["kind"] == "external" and context.get("nonInteractive") is not False:
            reason = "external delegate forbidden in headless context" if context.get("nonInteractive") is True else "non-interactive status unresolved for external delegate"
        evidence = [item for item in context["techniques"] if item["runtime"] == route["target"] and item["technique"] == name]
        model = technique["model"]
        evidence = [item for item in evidence if isinstance(item["model"], str) and not any(c in item["model"] for c in "*?[") and (fnmatch.fnmatchcase(item["model"], model["value"]) if model["isPattern"] else item["model"] == model["value"])]
        agent = technique["agent"]
        effort = requested if requested is not None else (agent["family"].get("defaultEffort") if agent else None)
        if reason is None and len(evidence) != 1:
            reason = "concrete model/available technique unresolved or ambiguous"
        if reason is None and (effort is None or effort not in evidence[0]["efforts"]):
            reason = "requested/default effort unresolved or unsupported"
        if reason:
            exclusions.append({"reason": reason, "technique": name})
            continue
        alternatives.append({
            "agent": agent,
            "effort": effort,
            "family": route["family"]["name"],
            "guidance": {key: node[key] for key in ("command", "modelArg", "notes")},
            "model": evidence[0]["model"],
            "qualification": qualification,
            "runtime": route["target"],
            "technique": name,
        })
    return alternatives, exclusions


def plan(manifest, context, roles, now, shell, run=run_reader):
    for role in roles:
        if role not in ROLE_TIERS:
            raise ValueError(f"unknown role: {role}")
    pool_names = {reader["name"] for reader in manifest["readers"]}
    session = manifest["sessionPool"]
    if session is not None and session not in pool_names:
        raise ValueError(f"unknown session pool: {session}")
    for route in manifest["routes"] + manifest["manualRoutes"]:
        if route["pool"] is not None and route["pool"] not in pool_names:
            raise ValueError(f"unknown route pool: {route['pool']}")
    if not isinstance(context.get("techniques"), list) or not isinstance(context.get("roles"), dict):
        raise ValueError("launch context requires techniques and roles")
    for evidence in context["techniques"]:
        if not isinstance(evidence, dict) or not all(isinstance(evidence.get(key), str) and evidence[key].strip() for key in ("runtime", "technique", "model")) or not isinstance(evidence.get("efforts"), list) or not all(isinstance(effort, str) for effort in evidence["efforts"]):
            raise ValueError("technique evidence requires runtime, technique, concrete model and efforts list")
    for role in roles:
        request = context["roles"].get(role, {})
        if not isinstance(request, dict) or not isinstance(request.get("families", {}), dict) or not all(isinstance(value, dict) for value in request.get("families", {}).values()) or (request.get("effort") is not None and not isinstance(request["effort"], str)):
            raise ValueError(f"{role}: expected families evidence map and requested effort string/null")
    pools = collect(manifest["readers"], now, shell, run)
    warnings = ["provider-vendor identity is provisional; fit/trial/maker independence are caller assessments"]
    # A Reader scope matches an exact family name in that pool, not a model glob.
    # Include manual routes so warnings describe configuration, not availability.
    family_paces, invalid_families = {}, set()
    for name, pool in pools.items():
        families = {route["family"]["name"] for route in manifest["routes"] + manifest["manualRoutes"] if route["pool"] == name}
        for window, pace in pool.get("scopedPaces", {}).items():
            scope = window.split(":", 1)[1]
            error = pool.get("scopedErrors", {}).get(window)
            if error is not None:
                warnings.append(f"{name}: scoped window {window} invalid; refusing its family: {error}")
                invalid_families.add((name, scope))
            if scope not in families:
                warnings.append(f"{name}: scoped window {window} matches no configured family")
            elif pace is not None:
                key = (name, scope)
                family_paces[key] = min(family_paces.get(key, pool["pace"]), pace)
    if session is None:
        warnings.append("session pool unknown; buffer rule cannot be certified")
    elif pools[session]["status"] != "measured":
        warnings.append("session budget unmeasured; buffer rule cannot be certified")
    result = {"automaticRuntimes": manifest["runtimes"], "manualOnly": manifest["manualRoutes"], "pools": pools, "roles": {}, "runtime": manifest["runtime"], "sessionPool": session, "snapshot": now.isoformat(), "warnings": warnings}
    for role in roles:
        request = context["roles"].get(role, {})
        qualified = request.get("families", {})
        candidates, excluded = [], []
        for route in manifest["routes"]:
            family = route["family"]
            record = {"family": family["name"], "runtime": route["target"]}
            qualification = qualified.get(family["name"], {})
            if family["tier"] not in ROLE_TIERS[role]:
                excluded.append(record | {"reason": "below role tier floor"})
                continue
            if not all(isinstance(qualification.get(key), str) and qualification[key].strip() for key in ("fit", "useFor", "avoidFor", "trial")):
                excluded.append(record | {"reason": "caller fit/useFor/avoidFor/trial evidence required"})
                continue
            alternatives, unresolved = launch(route, context, qualification, request.get("effort"))
            excluded.extend(record | item for item in unresolved)
            if alternatives:
                if (route["pool"], family["name"]) in invalid_families:
                    excluded.append(record | {"reason": "model-scoped window invalid"})
                    continue
                pace = family_paces.get((route["pool"], family["name"]), pools.get(route["pool"], {}).get("pace"))
                candidates.append({"alternatives": alternatives[1:], "launch": alternatives[0], "pace": pace, "pool": route["pool"], "tier": family["tier"]})
        measured = [item for item in candidates if pools.get(item["pool"], {}).get("status") == "measured"]
        usable = []
        for item in candidates:
            pool = pools.get(item["pool"], {})
            reason = None
            if measured and item not in measured:
                reason = "unmeasured pool excluded while measured candidates exist"
            elif pool.get("buffer") == 0:
                reason = "pool exhausted"
            elif item["pace"] == 0:
                reason = "model-scoped window exhausted"
            elif session is not None and item["pool"] == session and pool.get("status") == "measured":
                if pool.get("buffer", 0) <= 0.2:
                    reason = "session buffer must be strictly greater than 20%"
                elif any(other["pace"] > item["pace"] for other in measured if other["pool"] != session):
                    reason = "another fitting pool is ahead of session pace"
            if reason:
                excluded.append({"family": item["launch"]["family"], "reason": reason, "runtime": item["launch"]["runtime"]})
            else:
                item["budget"] = "measured" if measured else "fit-only; budget and session buffer unknown"
                usable.append(item)
        usable.sort(key=lambda item: (-(item["pace"] or 0), item["pool"] != session, item["launch"]["family"], item["launch"]["runtime"]))
        for item in usable:
            spec = item["launch"]
            item["line"] = " ".join(f"{key}={value}" for key, value in (("role", role), ("runtime", spec["runtime"]), ("family", spec["family"]), ("technique", spec["technique"]), ("model", spec["model"]), ("effort", spec["effort"])))
        result["roles"][role] = {"candidates": usable, "exclusions": excluded}
        if not usable:
            result["roles"][role]["error"] = "never step down a tier; report a loop failure."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--reader-shell", required=True)
    parser.add_argument("--launch-context", required=True)
    parser.add_argument("--role", action="append", required=True, choices=sorted(ROLE_TIERS))
    parser.add_argument("--now", help="fixed UTC evaluation time for offline fixtures")
    args = parser.parse_args()
    try:
        result = plan(json.loads(Path(args.manifest).read_text()), json.loads(Path(args.launch_context).read_text()), args.role, utc(args.now) if args.now else datetime.now(timezone.utc), args.reader_shell)
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(2, f"delegate-routing-plan: {error}\n")
    print(json.dumps(result, sort_keys=True))
    for role in args.role:
        for item in result["roles"][role]["candidates"]:
            print(item["line"], file=sys.stderr)
        if "error" in result["roles"][role]:
            print(result["roles"][role]["error"], file=sys.stderr)
    return int(any("error" in result["roles"][role] for role in args.role))


if __name__ == "__main__":
    sys.exit(main())
