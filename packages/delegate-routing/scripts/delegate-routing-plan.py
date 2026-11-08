"""Read registered budgets and print routing specifications; never launch delegates."""

import argparse
from datetime import datetime, timedelta, timezone
import fnmatch
from graphlib import TopologicalSorter
import json
import math
import os
from pathlib import Path
import posixpath
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
    "planner": {"strong", "frontier"},
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


def measure(stream, now):
    """Reject partial/account-ambiguous streams and unresolved windows wholesale."""
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
    paces, shares = [], []
    for name, window in windows.items():
        if not isinstance(window, dict):
            raise ValueError("window must be an object")
        if ":" in name:
            raise ValueError("model-scoped window applicability unresolved")
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
        if window["resetsAt"] is None:
            raise ValueError("unstarted null reset unresolved")
        left = (utc(window["resetsAt"]) - now).total_seconds()
        if not 0 < left <= seconds:
            raise ValueError("expired reset or reset beyond window duration")
        paces.append((remaining / 100) / (left / seconds))
        shares.append(remaining / 100)
    return {"buffer": min(shares), "pace": min(paces), "status": "measured"}


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
                candidates.append({"alternatives": alternatives[1:], "launch": alternatives[0], "pool": route["pool"], "tier": family["tier"]})
        measured = [item for item in candidates if pools.get(item["pool"], {}).get("status") == "measured"]
        usable = []
        for item in candidates:
            pool = pools.get(item["pool"], {})
            reason = None
            if measured and item not in measured:
                reason = "unmeasured pool excluded while measured candidates exist"
            elif pool.get("buffer") == 0:
                reason = "pool exhausted"
            elif session is not None and item["pool"] == session and pool.get("status") == "measured":
                if pool.get("buffer", 0) <= 0.2:
                    reason = "session buffer must be strictly greater than 20%"
                elif any(pools[other["pool"]]["pace"] > pool["pace"] for other in measured if other["pool"] != session):
                    reason = "another fitting pool is ahead of session pace"
            if reason:
                excluded.append({"family": item["launch"]["family"], "reason": reason, "runtime": item["launch"]["runtime"]})
            else:
                item["pace"] = pool.get("pace")
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


def check_plan(artifact, current, directory, max_concurrency=10):
    """Check saved launch choices against a fresh decision, never a plan allowlist."""
    if not 1 <= max_concurrency <= 10:
        raise ValueError("concurrency cap must be between 1 and 10")
    if not isinstance(artifact.get("task"), str) or not artifact["task"].strip():
        raise ValueError("plan requires task identity")
    if artifact["runtime"] != current["runtime"]:
        raise ValueError("plan must use the actual launching runtime's helper")
    # The saved snapshot is provenance, not authority for current pace or routes.
    snapshot = artifact["snapshot"]
    snapshot_types = {"automaticRuntimes": list, "manualOnly": list, "pools": dict, "roles": dict, "runtime": str, "sessionPool": (str, type(None)), "snapshot": str, "warnings": list}
    if not isinstance(snapshot, dict) or any(field not in snapshot or not isinstance(snapshot[field], kind) for field, kind in snapshot_types.items()):
        raise ValueError("saved helper snapshot must be a complete helper snapshot")
    utc(snapshot["snapshot"])
    if snapshot["runtime"] != artifact["runtime"]:
        raise ValueError("saved helper snapshot requires matching runtime")

    def read_artifact(path):
        # Rubric and brief artifacts cannot name absolute or upward paths.
        if not isinstance(path, str) or not path.strip() or Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError("artifact paths must be plan-relative, without absolute or upward components")
        return (directory / path).read_bytes()

    rubric = read_artifact(artifact["rubric"])
    if not rubric.strip():
        raise ValueError("saved rubric must not be empty")
    units = artifact["units"]
    if not isinstance(units, list) or not units:
        raise ValueError("plan requires units")
    indexed = {}
    for unit in units:
        identity = unit["id"]
        if not isinstance(identity, str) or not identity.strip() or identity in indexed:
            raise ValueError("unit ids must be nonempty and unique")
        indexed[identity] = unit
        for field in ("audience", "goal"):
            if not isinstance(unit[field], str) or not unit[field].strip():
                raise ValueError(f"{identity}: {field} required")
        for field in ("command", "wrongImplementation"):
            if not isinstance(unit["verification"][field], str) or not unit["verification"][field].strip():
                raise ValueError(f"{identity}: verification {field} required")
        for field in ("checks", "dependencies", "docs", "files"):
            if not isinstance(unit[field], list) or not all(isinstance(value, str) and value.strip() for value in unit[field]):
                raise ValueError(f"{identity}: {field} must be a path/id list")
        if not unit["files"] or not unit["size"]:
            raise ValueError(f"{identity}: file ownership and per-kind size required")
        if not set(unit["docs"] + unit["checks"]) <= set(unit["files"]):
            raise ValueError(f"{identity}: associated docs/checks need writer ownership")
        for path in unit["files"]:
            if path.startswith("/") or posixpath.normpath(path) in (".", "..") or posixpath.normpath(path).startswith("../"):
                raise ValueError(f"{identity}: writer files must be repository-relative")
        for counts in unit["size"].values():
            if not isinstance(counts, dict) or set(counts) != {"added", "removed"} or any(type(value) is not int or value < 0 for value in counts.values()):
                raise ValueError(f"{identity}: size needs nonnegative added/removed counts per kind")
        launches = unit["launches"]
        if not isinstance(launches, list) or not launches:
            raise ValueError(f"{identity}: prepared worker/reviewer launches required")
        roles = [record["role"] for record in launches]
        if "planner" in roles or not set(roles) <= ROLE_TIERS.keys():
            raise ValueError(f"{identity}: only worker and reviewer roles are allowed in approved units")
        if len(set(roles)) != len(roles) or sum(role in ("investigator", "mechanical", "writer") for role in roles) != 1 or "first-check" not in roles:
            raise ValueError(f"{identity}: one worker and a first-check review barrier required")
        for record in launches:
            role = record["role"]
            if record["runtime"] != current["runtime"]:
                raise ValueError(f"{identity}: launch runtime requires its own helper validation")
            candidates = current["roles"].get(role, {}).get("candidates", [])
            if not any(record["candidate"] == candidate["launch"] and record["line"] == candidate["line"] for candidate in candidates):
                raise ValueError(f"{identity}: {role} candidate/line absent from current helper output")
            if rubric not in read_artifact(record["brief"]):
                raise ValueError(f"{identity}: {role} brief must contain the full rubric verbatim")
    for identity, unit in indexed.items():
        if any(dependency not in indexed for dependency in unit["dependencies"]):
            raise ValueError(f"{identity}: unknown dependency")
    # CycleError is a ValueError; report the graph's involved unit ids to callers.
    tuple(TopologicalSorter({identity: unit["dependencies"] for identity, unit in indexed.items()}).static_order())
    waves, seen = artifact["waves"], set()
    if not isinstance(waves, list) or not waves:
        raise ValueError("plan requires launch waves")
    for wave in waves:
        if not isinstance(wave, list) or not wave:
            raise ValueError("wave must contain unit ids")
        owners = set()
        for identity in wave:
            if identity not in indexed or identity in seen or wave.count(identity) != 1:
                raise ValueError("each known unit must appear in exactly one wave")
            unit = indexed[identity]
            if not set(unit["dependencies"]) <= seen:
                raise ValueError(f"{identity}: dependencies require an earlier reviewed/committed wave")
            files = {posixpath.normpath(path) for path in unit["files"]}
            if owners & files:
                raise ValueError(f"{identity}: overlapping same-wave writer files")
            owners.update(files)
        if sum(len(indexed[identity]["launches"]) for identity in wave) > max_concurrency:
            raise ValueError(f"wave must contain 1..{max_concurrency} delegates across all unit launches")
        seen.update(wave)
    if seen != set(indexed):
        raise ValueError("each known unit must appear in exactly one wave")
    return {"status": "valid", "task": artifact["task"], "units": len(units), "waves": len(waves)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-plan", help="validate saved JSON and prepared briefs against this invocation")
    parser.add_argument("--max-concurrency", type=int, default=10, help="explicit host/user cap, at most ten")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--reader-shell", required=True)
    parser.add_argument("--launch-context", required=True)
    parser.add_argument("--role", action="append", required=True, choices=sorted(ROLE_TIERS))
    parser.add_argument("--now", help="fixed UTC evaluation time for offline fixtures")
    args = parser.parse_args()
    try:
        result = plan(json.loads(Path(args.manifest).read_text()), json.loads(Path(args.launch_context).read_text()), args.role, utc(args.now) if args.now else datetime.now(timezone.utc), args.reader_shell)
        if args.check_plan:
            path = Path(args.check_plan).resolve()
            result["validation"] = check_plan(json.loads(path.read_text()), result, path.parent, args.max_concurrency)
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
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
