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
import re
import shutil
import signal
import subprocess
import sys

# Tier is a floor, never evidence of semantic fit, trial status or independence.
ROLE_POLICY = {
    "finder": {"review": True, "tiers": {"strong", "frontier"}},
    "first-check": {"review": True, "tiers": {"strong", "frontier"}},
    "investigator": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
    "judge": {"review": True, "tiers": {"strong", "frontier"}},
    "mechanical": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
    "planner": {"review": False, "tiers": {"strong", "frontier"}},
    "second-check": {"review": True, "tiers": {"strong", "frontier"}},
    "writer": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
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
            except subprocess.TimeoutExpired:
                result = {"reason": "Reader timed out", "status": "unmeasured"}
            except OSError:
                result = {"reason": "Reader could not execute", "status": "unmeasured"}
            except (KeyError, TypeError, ValueError) as error:
                result = {"reason": str(error), "status": "unmeasured"}
            commands[command] = result
        results[reader["name"]] = result
    return results


def pool_diagnostics(readers, pools):
    failures, warnings = {}, []
    for reader in sorted(readers, key=lambda reader: reader["name"]):
        name, command = reader["name"], reader["command"]
        pool = pools[name]
        if pool["status"] == "unmeasured":
            # Missing registrations have no shared command to report together.
            key = ("pool", name) if command is None else ("command", command)
            failures.setdefault(key, []).append(name)
        for window in sorted(pool.get("scopedErrors", {})):
            warnings.append(f"WARNING: pool={name} scoped window {window} invalid; refusing its family.")
    for names in sorted(failures.values()):
        reason = pools[names[0]]["reason"]
        # Reader output and OS/timeout exceptions can contain credentials or commands.
        if reason not in {"no registered Reader", "Reader could not execute", "Reader shell must name an executable file", "Reader timed out"} and not re.fullmatch(r"Reader exited -?[0-9]{1,3}", reason):
            reason = "invalid Reader output"
        warnings.append(f"WARNING: Reader for {', '.join(names)} failed: {reason}. Report this failure to the user.")
    return warnings


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


def maker_key(value):
    # Direct JSON manifests also reach the helper without Nix option validation.
    return value.strip().lower() if isinstance(value, str) else None


def maker_exclusion(family, request, role, families):
    """Only declared makers can certify review independence, never providers."""
    if not ROLE_POLICY[role]["review"]:
        return None
    maker = maker_key(family.get("maker"))
    if not maker:
        return "candidate maker unknown; review independence unresolved"
    against = {"writer": request.get("writer")}
    if role == "judge" and "cutProposer" in request:
        against["cut proposer"] = request["cutProposer"]
    for label, name in against.items():
        other = maker_key(next((item.get("maker") for item in families if item["name"] == name), None))
        if not other:
            return f"{label} maker unknown; review independence unresolved"
        if maker == other:
            return f"same maker as {label}: {maker}"
    return None


def plan(manifest, context, roles, now, pools):
    for role in roles:
        if role not in ROLE_POLICY:
            raise ValueError(f"unknown role: {role}")
    pool_names = {reader["name"] for reader in manifest["readers"]}
    session = manifest["sessionPool"]
    if session is not None and session not in pool_names:
        raise ValueError(f"unknown session pool: {session}")
    for route in manifest["routes"] + manifest["manualRoutes"]:
        family = route["family"]
        if type(family.get("cost")) is not int or not 0 <= family["cost"] <= 5:
            raise ValueError(f"family {family['name']} cost must be an integer from 0 to 5")
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
        if ROLE_POLICY[role]["review"] and (not isinstance(request.get("writer"), str) or not request["writer"].strip()):
            raise ValueError(f"{role}: review role requires writer family name")
    warnings = ["maker independence uses declared family metadata; fit/trial remain caller assessments"]
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
    families = [route["family"] for route in manifest["routes"] + manifest["manualRoutes"]]
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
            if family["tier"] not in ROLE_POLICY[role]["tiers"]:
                excluded.append(record | {"reason": "below role tier floor"})
                continue
            if not all(isinstance(qualification.get(key), str) and qualification[key].strip() for key in ("fit", "useFor", "avoidFor", "trial")):
                excluded.append(record | {"reason": "caller fit/useFor/avoidFor/trial evidence required"})
                continue
            reason = maker_exclusion(family, request, role, families)
            if reason:
                excluded.append(record | {"reason": reason})
                continue
            alternatives, unresolved = launch(route, context, qualification, request.get("effort"))
            excluded.extend(record | item for item in unresolved)
            if alternatives:
                if (route["pool"], family["name"]) in invalid_families:
                    excluded.append(record | {"reason": "model-scoped window invalid"})
                    continue
                pace = family_paces.get((route["pool"], family["name"]), pools.get(route["pool"], {}).get("pace"))
                candidates.append({"alternatives": alternatives[1:], "cost": family["cost"], "launch": alternatives[0], "pace": pace, "pool": route["pool"], "tier": family["tier"]})
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
        usable.sort(key=lambda item: (-(item["pace"] or 0), session is not None and item["pool"] == session, item["cost"], item["launch"]["family"], item["launch"]["runtime"]))
        for item in usable:
            spec = item["launch"]
            item["line"] = " ".join(f"{key}={value}" for key, value in (("role", role), ("runtime", spec["runtime"]), ("family", spec["family"]), ("technique", spec["technique"]), ("model", spec["model"]), ("effort", spec["effort"])))
        result["roles"][role] = {"candidates": usable, "exclusions": excluded}
        if not usable:
            result["roles"][role]["error"] = "never step down a tier; report a loop failure."
    return result


def check_plan(artifact, current, directory, max_concurrency=10, *, manifest, context):
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
    families = [route["family"] for route in manifest["routes"] + manifest["manualRoutes"]]
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
        if "planner" in roles or not set(roles) <= ROLE_POLICY.keys():
            raise ValueError(f"{identity}: only worker and reviewer roles are allowed in approved units")
        if len(set(roles)) != len(roles) or sum(role in ("investigator", "mechanical", "writer") for role in roles) != 1 or "first-check" not in roles:
            raise ValueError(f"{identity}: one worker and a first-check review barrier required")
        worker = next(record["candidate"]["family"] for record in launches if record["role"] in ("investigator", "mechanical", "writer"))
        for record in launches:
            role = record["role"]
            if record["runtime"] != current["runtime"]:
                raise ValueError(f"{identity}: launch runtime requires its own helper validation")
            candidates = current["roles"].get(role, {}).get("candidates", [])
            if not any(record["candidate"] == candidate["launch"] and record["line"] == candidate["line"] for candidate in candidates):
                raise ValueError(f"{identity}: {role} candidate/line absent from current helper output")
            # A shared launch context cannot certify a different unit's worker.
            family = next(item for item in families if item["name"] == record["candidate"]["family"])
            request = context["roles"].get(role, {}) | {"writer": worker}
            reason = maker_exclusion(family, request, role, families)
            if reason:
                raise ValueError(f"{identity}: {role}: {reason}")
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
    # Recover collection inputs even when unrelated options or their values fail.
    values = {}
    for name in ("manifest", "now", "reader-shell"):
        parser = RoutingParser(add_help=False, allow_abbrev=False)
        parser.add_argument("--" + name)
        try:
            args, _ = parser.parse_known_args(argv)
            values[name] = getattr(args, name.replace("-", "_"))
        except ValueError:
            values[name] = None
    return values


def main():
    parser = RoutingParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--check-plan", help="validate saved JSON and prepared briefs against this invocation")
    parser.add_argument("--max-concurrency", type=int, choices=range(1, 11), default=10, help="explicit host/user cap, at most ten")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--reader-shell", required=True)
    parser.add_argument("--launch-context", required=True)
    parser.add_argument("--role", action="append", required=True, choices=sorted(ROLE_POLICY))
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
        if not isinstance(readers, list) or any(not isinstance(reader, dict) or not isinstance(reader.get("name"), str) or not reader["name"].strip() or "command" not in reader or (reader["command"] is not None and not isinstance(reader["command"], str)) for reader in readers):
            raise ValueError("inventory-unavailable: readers require names and command strings/null")
        if len({reader["name"] for reader in readers}) != len(readers):
            raise ValueError("inventory-unavailable: Reader registration names must be unique")
        result.update({key: manifest[key] for key in ("runtime", "sessionPool") if key in manifest})
        result.update({"automaticRuntimes": manifest.get("runtimes"), "inventory": "available", "manualOnly": manifest.get("manualRoutes")})
        shell = inputs["reader-shell"]
        # A missing or non-executable shell cannot read any known registration.
        shell_error = None
        if not shell or shutil.which(shell) is None:
            shell_error = "Reader shell must name an executable file"
            result["pools"] = {reader["name"]: {"reason": shell_error, "status": "unmeasured"} for reader in readers}
        else:
            result["pools"] = collect(readers, now, shell, run_reader)
        args = parser.parse_args(argv)
        if time_error is not None:
            raise time_error
        if shell_error is not None:
            raise ValueError(shell_error)
        context = json.loads(Path(args.launch_context).read_text())
        result.update(plan(manifest, context, args.role, now, result["pools"]))
        if args.check_plan:
            path = Path(args.check_plan).resolve()
            result["validation"] = check_plan(json.loads(path.read_text()), result, path.parent, args.max_concurrency, manifest=manifest, context=context)
        result["errors"].extend(f"{role}: {value['error']}" for role, value in result["roles"].items() if "error" in value)
        code = int(bool(result["errors"]))
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
        result["errors"].append(str(error))
    result["status"] = "ok" if code == 0 else "error"
    diagnostics = pool_diagnostics(readers, result["pools"]) if result["inventory"] == "available" else []
    result["warnings"].extend(diagnostics)
    print(json.dumps(result, sort_keys=True))
    for name, pool in sorted(result["pools"].items()):
        print(f"pool={name} status={pool['status']}", file=sys.stderr)
    for warning in diagnostics:
        print(warning, file=sys.stderr)
    for role in result["roles"].values():
        for item in role["candidates"]:
            print(item["line"], file=sys.stderr)
    for error in result["errors"]:
        print(f"delegate-routing-plan: {error}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
