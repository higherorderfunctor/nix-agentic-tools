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
import time

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
READER_RETRY_DELAY = 2
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


def remaining_share(window):
    if not isinstance(window, dict):
        raise ValueError("window must be an object")
    remaining = window["remainingPercent"]
    if isinstance(remaining, bool) or not isinstance(remaining, (int, float)) or not math.isfinite(remaining) or not 0 <= remaining <= 100:
        raise ValueError("invalid remainingPercent")
    return remaining / 100


def window_pace(window, now):
    share = remaining_share(window)
    remaining, seconds = window["remainingPercent"], window["windowSeconds"]
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds <= 0:
        raise ValueError("invalid windowSeconds")
    used = window["usedPercent"]
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not math.isclose(used + remaining, 100):
        raise ValueError("invalid/inconsistent usedPercent")
    if window["status"] is not None and not isinstance(window["status"], str):
        raise ValueError("window status must be a string or null")
    if used == 0 and remaining == 100:
        return None
    if window["resetsAt"] is None:
        raise ValueError("unstarted null reset unresolved")
    try:
        left = (utc(window["resetsAt"]) - now).total_seconds()
    except ValueError:
        raise ValueError("invalid reset timestamp; time must be UTC") from None
    if not 0 < left <= seconds:
        raise ValueError("expired reset or reset beyond window duration")
    return share / (left / seconds)


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
    if not isinstance(windows, dict):
        raise ValueError("windows must be an object")
    paces, shares, scoped, scoped_errors, window_errors = [], [], {}, {}, {}
    usable, unknown_share = False, False
    for name, window in windows.items():
        is_scoped = ":" in name
        if not is_scoped:
            try:
                shares.append(remaining_share(window))
            except (KeyError, TypeError, ValueError):
                unknown_share = True
        try:
            pace = window_pace(window, now)
        except (KeyError, TypeError, ValueError) as error:
            if is_scoped:
                scoped[name] = None
            (scoped_errors if is_scoped else window_errors)[name] = str(error)
            continue
        if is_scoped:
            scoped[name] = pace
        else:
            usable = True
            if pace is not None:
                paces.append(pace)
    buffer = min(shares, default=None)
    measured = usable or buffer == 0
    if buffer == 0:
        pace = 0.0
    elif usable:
        pace = min(paces, default=1.0)
    else:
        pace = None
    if buffer != 0 and unknown_share:
        buffer = None
    status = "measured" if measured else "unmeasured"
    result = {"buffer": buffer, "pace": pace, "status": status}
    if not measured:
        result["reason"] = "no usable unscoped windows for pool pace/buffer"
    if scoped:
        result["scopedPaces"] = scoped
    if scoped_errors:
        result["scopedErrors"] = scoped_errors
    if window_errors:
        result["windowErrors"] = window_errors
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
                argv = [shell, "-euETo", "pipefail", "-c", "shopt -s inherit_errexit 2>/dev/null || :\n" + command]
                try:
                    proc = run(argv, capture_output=True, text=True, timeout=READER_TIMEOUT)
                except subprocess.TimeoutExpired:
                    proc = None
                if proc is None or proc.returncode:
                    time.sleep(READER_RETRY_DELAY)
                    proc = run(argv, capture_output=True, text=True, timeout=READER_TIMEOUT)
                if proc.returncode:
                    result = {"reason": f"Reader exited {proc.returncode}", "status": "unreachable"}
                else:
                    result = measure(proc.stdout, now)
            except subprocess.TimeoutExpired:
                result = {"reason": "Reader timed out", "status": "unreachable"}
            except OSError:
                result = {"reason": "Reader could not execute", "status": "unreachable"}
            except (KeyError, TypeError, ValueError):
                result = {"reason": "invalid Reader output", "status": "unreachable"}
            commands[command] = result
        results[reader["name"]] = result
    return results


def warning(message, *, failure=True):
    message = "".join(char if char.isprintable() else ascii(char)[1:-1] for char in message)
    report = "Report this failure to the user." if failure else "Report this to the user."
    return f"WARNING: {message}. {report}"


def pool_diagnostics(readers, pools):
    failures, warnings = {}, []
    for reader in sorted(readers, key=lambda reader: reader["name"]):
        name, command = reader["name"], reader["command"]
        pool = pools[name]
        if pool["status"] == "unreachable":
            failures.setdefault(command, []).append(name)
        for window, reason in sorted(pool.get("windowErrors", {}).items()):
            warnings.append(warning(f"{name}: window {window} pace dropped: {reason}"))
    for names in sorted(failures.values()):
        reason = pools[names[0]]["reason"]
        warnings.append(warning(f"Reader for {', '.join(names)} failed: {reason}"))
    return warnings


def launch(route, context, qualification, requested, avoided, scale):
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
        resolved = requested if requested is not None else route["family"]["defaultEffort"]
        effort = resolved
        if reason is None and len(evidence) != 1:
            reason = "concrete model/available technique unresolved or ambiguous"
        if reason is None and evidence[0]["efforts"] == []:
            effort = None
        if reason is None and (
            (effort is None and evidence[0]["efforts"] != [])
            or (effort is not None and (effort not in scale or effort not in evidence[0]["efforts"]))
        ):
            reason = "requested/default effort unresolved or unsupported"
        if reason:
            exclusions.append({"reason": reason, "technique": name})
            continue
        if avoided and effort is not None:
            supported = [value for value in scale if value in evidence[0]["efforts"] and scale.index(value) > scale.index(resolved)]
            effort = next(iter(supported), resolved)
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
        if avoided:
            alternatives[-1]["fallback"] = {"kind": "avoided-family", "launchEffort": effort, "resolvedEffort": resolved}
    return alternatives, exclusions


def plan(manifest, context, roles, now, pools):
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
    family_names = set(manifest["familyNames"])
    for role in roles:
        request = context["roles"].get(role, {})
        if not isinstance(request, dict) or not isinstance(request.get("families", {}), dict) or not all(isinstance(value, dict) for value in request.get("families", {}).values()) or (request.get("effort") is not None and not isinstance(request["effort"], str)):
            raise ValueError(f"{role}: expected families evidence map and requested effort string/null")
        for field in ("avoid", "exclude"):
            values = request.get(field, [])
            if not isinstance(values, list) or not all(isinstance(value, str) and value in family_names for value in values):
                raise ValueError(f"{role}: {field} requires a list of exact configured family names")
    warnings = ["provider-vendor identity is provisional; fit/trial/maker independence are caller assessments"] + pool_diagnostics(manifest["readers"], pools)
    # A Reader scope matches an exact family name in that pool, not a model glob.
    # Include manual routes so warnings describe configuration, not availability.
    family_paces, invalid_families = {}, set()
    for name, pool in pools.items():
        families = {route["family"]["name"] for route in manifest["routes"] + manifest["manualRoutes"] if route["pool"] == name}
        for window, pace in pool.get("scopedPaces", {}).items():
            scope = window.split(":", 1)[1]
            error = pool.get("scopedErrors", {}).get(window)
            if error is not None:
                warnings.append(warning(f"{name}: scoped window {window} invalid; refusing its family: {error}"))
                invalid_families.add((name, scope))
            if scope not in families:
                warnings.append(warning(f"{name}: scoped window {window} matches no configured family"))
            elif pace is not None:
                key = (name, scope)
                family_paces[key] = min(family_paces.get(key, pool.get("pace") if pool.get("pace") is not None else pace), pace)
    if session is None:
        warnings.append("session pool unknown; buffer rule cannot be certified")
    elif pools[session]["status"] != "measured" or pools[session].get("buffer") is None:
        warnings.append("session buffer unknown; buffer rule cannot be certified")
    result = {"automaticRuntimes": manifest["runtimes"], "manualOnly": manifest["manualRoutes"], "pools": pools, "roles": {}, "runtime": manifest["runtime"], "sessionPool": session, "snapshot": now.isoformat(), "warnings": warnings}
    for role in roles:
        request = context["roles"].get(role, {})
        qualified = request.get("families", {})
        candidates, excluded = [], []
        for route in manifest["routes"]:
            family = route["family"]
            record = {"family": family["name"], "runtime": route["target"]}
            if family["name"] in request.get("exclude", []):
                excluded.append(record | {"reason": "excluded by caller"})
                continue
            avoided = family["name"] in request.get("avoid", [])
            qualification = qualified.get(family["name"], {})
            if family["tier"] not in ROLE_TIERS[role]:
                excluded.append(record | {"reason": "below role tier floor"})
                continue
            if not all(isinstance(qualification.get(key), str) and qualification[key].strip() for key in ("fit", "useFor", "avoidFor", "trial")):
                excluded.append(record | {"reason": "caller fit/useFor/avoidFor/trial evidence required"})
                continue
            alternatives, unresolved = launch(route, context, qualification, request.get("effort"), avoided, manifest["effortLevels"])
            excluded.extend(record | item for item in unresolved)
            if alternatives:
                if (route["pool"], family["name"]) in invalid_families:
                    excluded.append(record | {"reason": "model-scoped window invalid"})
                    continue
                pace = family_paces.get((route["pool"], family["name"]), pools.get(route["pool"], {}).get("pace"))
                candidates.append({"alternatives": alternatives[1:], "launch": alternatives[0], "pace": pace, "pool": route["pool"], "tier": family["tier"]})
        eligible = []
        for item in candidates:
            pool = pools.get(item["pool"], {})
            reason = None
            if pool.get("status") == "unreachable":
                reason = "Reader unreachable for this invocation"
            elif pool.get("buffer") == 0:
                reason = "pool exhausted"
            elif item["pace"] == 0:
                reason = "model-scoped window exhausted"
            elif session is not None and item["pool"] == session:
                if pool.get("status") != "measured" or pool.get("buffer") is None:
                    reason = "session buffer cannot be certified"
                elif pool["buffer"] <= 0.2:
                    reason = "session buffer must be strictly greater than 20%"
            if reason:
                excluded.append({"family": item["launch"]["family"], "reason": reason, "runtime": item["launch"]["runtime"]})
            else:
                eligible.append(item)
        measured = [item for item in eligible if pools.get(item["pool"], {}).get("status") == "measured"]
        session_behind = [item for item in measured if session is not None and item["pool"] == session and any(other["pace"] > item["pace"] for other in measured if other["pool"] != session)]
        selectable_measured = [item for item in measured if item not in session_behind]
        usable = []
        for item in eligible:
            reason = None
            partition_measured = [other for other in selectable_measured if ("fallback" in other["launch"]) == ("fallback" in item["launch"])]
            if item in session_behind:
                reason = "another fitting pool is ahead of session pace"
            elif partition_measured and item not in partition_measured:
                reason = "unmeasured pool excluded while measured candidates exist"
            if reason:
                excluded.append({"family": item["launch"]["family"], "reason": reason, "runtime": item["launch"]["runtime"]})
            else:
                item["budget"] = "measured" if item in measured else "fit-only; budget and session buffer unknown"
                usable.append(item)
        usable.sort(key=lambda item: ("fallback" in item["launch"], -(item["pace"] or 0), item["pool"] == session, item["launch"]["family"], item["launch"]["runtime"]))
        for item in usable:
            spec = item["launch"]
            item["line"] = " ".join(f"{key}={value}" for key, value in (("role", role), ("runtime", spec["runtime"]), ("family", spec["family"]), ("technique", spec["technique"]), ("model", spec["model"]), ("effort", spec["effort"])) if value is not None)
        if usable and "fallback" in usable[0]["launch"]:
            spec = usable[0]["launch"]
            effort = spec["effort"] if spec["effort"] is not None else "omitted intentionally"
            warnings.append(warning(f"{role}: no non-avoided candidate; using fallback {spec['family']} at effort {effort}", failure=False))
        result["roles"][role] = {"candidates": usable, "exclusions": excluded}
        if not usable:
            result["roles"][role]["error"] = "never step down a tier; report a loop failure."
    return result


def check_plan(artifact, current, directory, max_concurrency=10):
    """Check saved launch choices against a fresh decision, never a plan allowlist."""
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

    directory = directory.resolve()

    def read_artifact(path):
        # Rubric and brief paths cannot escape through components or symlinks.
        if not isinstance(path, str) or not path.strip() or Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError("artifact paths must be plan-relative, without absolute or upward components")
        resolved = (directory / path).resolve()
        if not resolved.is_relative_to(directory):
            raise ValueError("artifact paths must stay inside the plan directory")
        return resolved.read_bytes()

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
            # Empty/partial snapshots cannot prove the launches and bound budgets
            # were captured, even when the fresh helper still allows the launch.
            saved_role = snapshot["roles"].get(role)
            if not isinstance(saved_role, dict) or not isinstance(saved_role.get("candidates"), list):
                raise ValueError(f"saved helper snapshot requires {role} candidates")
            saved_candidates = saved_role["candidates"]
            for candidate in saved_candidates:
                if not isinstance(candidate, dict) or not isinstance(candidate.get("launch"), dict) or not isinstance(candidate.get("line"), str) or "pool" not in candidate:
                    raise ValueError("saved helper snapshot requires complete candidates")
                pool = candidate["pool"]
                if pool is not None and (not isinstance(pool, str) or not isinstance(snapshot["pools"].get(pool), dict)):
                    raise ValueError("saved helper snapshot requires candidate-bound pools")
            if not any(record["candidate"] == candidate["launch"] and record["line"] == candidate["line"] for candidate in saved_candidates):
                raise ValueError(f"saved helper snapshot lacks {role} candidate/line")
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
        if len(wave) > max_concurrency:
            raise ValueError(f"wave must contain 1..{max_concurrency} concurrent units")
        seen.update(wave)
    if seen != set(indexed):
        raise ValueError("each known unit must appear in exactly one wave")
    return {"status": "valid", "task": artifact["task"], "units": len(units), "waves": len(waves)}


class RoutingParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def collection_arguments(argv):
    # Recover Reader inputs when unrelated request options or values are invalid.
    values = {}
    for name in ("manifest", "now", "reader-shell"):
        parser = RoutingParser(add_help=False)
        parser.add_argument("--" + name)
        try:
            args, _ = parser.parse_known_args(argv)
            values[name] = getattr(args, name.replace("-", "_"))
        except ValueError:
            values[name] = None
    return values


def main():
    parser = RoutingParser(description=__doc__)
    parser.add_argument("--check-plan", help="validate saved JSON and prepared briefs against this invocation")
    parser.add_argument("--max-concurrency", type=int, choices=range(1, 11), default=10, help="explicit host/user cap, at most ten")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--reader-shell", required=True)
    parser.add_argument("--launch-context", required=True)
    parser.add_argument("--role", action="append", required=True, choices=sorted(ROLE_TIERS))
    parser.add_argument("--now", help="fixed UTC evaluation time for offline fixtures")
    argv = sys.argv[1:]
    if "--help" in argv or "-h" in argv:
        parser.print_help()
        return 0
    inputs = collection_arguments(argv)
    now = datetime.now(timezone.utc)
    time_error = None
    if inputs["now"] is not None:
        try:
            now = utc(inputs["now"])
        except ValueError as error:
            time_error = error
    result = {"errors": [], "inventory": "inventory-unavailable", "pools": {}, "roles": {}, "snapshot": now.isoformat(), "status": "error", "warnings": []}
    code = 2
    try:
        if inputs["manifest"] is None:
            raise ValueError("inventory-unavailable: manifest path could not be recovered")
        manifest = json.loads(Path(inputs["manifest"]).read_text())
        readers = manifest["readers"]
        # Direct JSON manifests must identify every registration before collection.
        if not isinstance(readers, list) or any(not isinstance(reader, dict) or not isinstance(reader.get("name"), str) or not reader["name"].strip() or "command" not in reader or (reader["command"] is not None and not isinstance(reader["command"], str)) for reader in readers):
            raise ValueError("inventory-unavailable: readers require names and command strings/null")
        if len({reader["name"] for reader in readers}) != len(readers):
            raise ValueError("inventory-unavailable: Reader registration names must be unique")
        result.update({key: manifest[key] for key in ("runtime", "sessionPool") if key in manifest})
        result.update({"automaticRuntimes": manifest.get("runtimes"), "inventory": "available", "manualOnly": manifest.get("manualRoutes")})
        result["pools"] = collect(readers, now, inputs["reader-shell"] or "", run_reader)
        result["warnings"] = pool_diagnostics(readers, result["pools"])
        args = parser.parse_args(argv)
        if time_error is not None:
            raise time_error
        context = json.loads(Path(args.launch_context).read_text())
        result.update(plan(manifest, context, args.role, now, result["pools"]))
        result["errors"].extend(f"{role}: {value['error']}" for role, value in result["roles"].items() if "error" in value)
        if args.check_plan:
            path = Path(args.check_plan).resolve()
            result["validation"] = check_plan(json.loads(path.read_text()), result, path.parent, args.max_concurrency)
        code = int(bool(result["errors"]))
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
        result["errors"].append(str(error))
    result["status"] = "ok" if code == 0 else "error"
    print(json.dumps(result, sort_keys=True))
    for message in result["warnings"]:
        if message.startswith("WARNING:"):
            print(message, file=sys.stderr)
    for role, value in result["roles"].items():
        for item in value["candidates"]:
            print(item["line"], file=sys.stderr)
        if "error" in value:
            print(f"delegate-routing-plan: {role}: {value['error']}", file=sys.stderr)
    if code == 2:
        print(f"delegate-routing-plan: {result['errors'][-1]}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
