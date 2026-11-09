"""Read registered budgets and print routing specifications; never launch delegates."""

import argparse
from datetime import datetime, timedelta, timezone
import fnmatch
from graphlib import TopologicalSorter
import hashlib
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
    "classifier": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
    "finder": {"review": True, "tiers": {"strong", "frontier"}},
    "first-check": {"review": True, "tiers": {"strong", "frontier"}},
    "investigator": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
    "judge": {"review": True, "tiers": {"strong", "frontier"}},
    "mechanical": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
    "planner": {"review": False, "tiers": {"strong", "frontier"}},
    "second-check": {"review": True, "tiers": {"strong", "frontier"}},
    "writer": {"review": False, "tiers": {"small", "mid", "strong", "frontier"}},
}
DECISIONS = ("keep", "task-mismatch", "input-unsupported", "constraint-conflict", "uncertain")
FAMILY_LIMIT = 128
READER_TIMEOUT = 10
REQUEST_LIMIT = 65536
RESULT_LIMIT = 1048576


def canonical(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def strict_json(value):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid(value):
        raise ValueError(f"non-finite JSON number: {value}")

    result = json.loads(value, object_pairs_hook=pairs, parse_constant=invalid)
    canonical(result)  # Refuse surrogate code points and overflowed numeric literals.
    return result


def closed(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise ValueError(f"expected object fields: {', '.join(sorted(required))}")


def nonempty(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("expected nonempty string")
    return value


def user_pins(record):
    pins = record.get("pins", {})
    closed(pins, (), ("family", "model", "runtime", "technique"))
    for value in pins.values():
        nonempty(value)
    if record.get("effort") is not None:
        nonempty(record["effort"])
    return {"effort": record.get("effort"), "pins": pins}


def bounded_read(path, limit):
    with path.open("rb") as source:
        value = source.read(limit + 1)
    if len(value) > limit:
        raise ValueError(f"input exceeds {limit} bytes; supply a smaller actual unit/scope")
    return value


def confined_read(directory, name, limit, label):
    if label == "context":
        nonempty(name)
    if not isinstance(name, str) or not name.strip() or Path(name).is_absolute() or ".." in Path(name).parts:
        separator = "," if label == "plan" else ""
        raise ValueError(f"artifact paths must be {label}-relative{separator} without absolute or upward components")
    root = directory.resolve()
    path = (root / name).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f"artifact paths must stay inside the {label} directory")
    return bounded_read(path, limit)


def request_hash(instructions, request):
    raw = instructions.encode("utf-8")
    return "sha256:" + hashlib.sha256(b"delegate-routing/classification-request/v1\0" + len(raw).to_bytes(8, "big") + raw + canonical(request)).hexdigest()


def receipt_hash(body):
    return "sha256:" + hashlib.sha256(b"delegate-routing/classification-receipt/v1\0" + canonical(body)).hexdigest()


def validate_role_record(record):
    if isinstance(record, dict) and record.keys() & {"families", "fit", "useFor", "avoidFor", "trial"}:
        raise ValueError("caller fit/families/useFor/avoidFor/trial fields are refused; prepare classification with --role classifier --classify-role <target> --launch-context <json-path>, then use --classification or --receipt")
    closed(record, ("brief", "effort", "requirements"), ("cutProposer", "pins", "writer"))


def semantic_evidence(receipt, request):
    return {"decisions": {item["family"]: item["decision"] for item in receipt["decisions"]}, "efforts": {family["name"]: family["effectiveEffort"] for family in request["families"]}}


def classification_request(manifest, context, role, directory):
    closed(context, ("roles", "rubric", "subject", "techniques"), ("nonInteractive",))
    closed(context["subject"], ("task", "unit"))
    for value in context["subject"].values():
        nonempty(value)
    if not isinstance(context["roles"], dict) or role not in context["roles"]:
        raise ValueError(f"{role}: role brief, effort and requirements required")
    record = context["roles"][role]
    validate_role_record(record)
    effort = record["effort"]
    user_pins(record)
    requirements = record["requirements"]
    closed(requirements, ("constraints", "inputKinds"))
    constraints, kinds = requirements["constraints"], requirements["inputKinds"]
    if not isinstance(constraints, list) or not isinstance(kinds, list) or any(not isinstance(kind, str) or kind not in ("audio", "image", "text", "video") for kind in kinds) or len(kinds) != len(set(kinds)):
        raise ValueError("requirements need constraints and unique supported inputKinds")
    identifiers = []
    for constraint in constraints:
        closed(constraint, ("id", "text"))
        identifiers.append(nonempty(constraint["id"]))
        nonempty(constraint["text"])
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("constraint ids must be unique")
    catalog = manifest["familyCatalog"]
    if not isinstance(catalog, list) or not 1 <= len(catalog) <= FAMILY_LIMIT:
        raise ValueError(f"request requires 1..{FAMILY_LIMIT} configured families; supply a smaller actual unit/scope")
    families = []
    for family in catalog:
        effective = effort if effort is not None else family.get("defaultEffort")
        if effective is not None:
            nonempty(effective)
        if any(not isinstance(family.get(key), str) for key in ("avoidFor", "useFor")):
            raise ValueError("family capability guidance must be strings; empty guidance supplies no criteria")
        families.append({"avoidFor": family["avoidFor"], "effectiveEffort": effective, "name": nonempty(family["name"]), "useFor": family["useFor"]})
    if len({family["name"] for family in families}) != len(families):
        raise ValueError("configured family identities must be unique")
    request = {"brief": nonempty(confined_read(directory, record["brief"], REQUEST_LIMIT, "context").decode("utf-8")), "families": sorted(families, key=lambda family: family["name"]), "requirements": {"constraints": constraints, "inputKinds": sorted(kinds)}, "role": role, "rubric": nonempty(confined_read(directory, context["rubric"], REQUEST_LIMIT, "context").decode("utf-8")), "schemaVersion": 1, "subject": context["subject"]}
    instructions = nonempty(manifest["classifierInstructions"])
    if len(instructions.encode("utf-8")) + len(canonical(request)) > REQUEST_LIMIT:
        raise ValueError(f"classifier request exceeds {REQUEST_LIMIT} bytes; supply a smaller actual unit/scope")
    return request, request_hash(instructions, request)


def approvals(manifest):
    values, seen = manifest["classifiers"], set()
    names = {family["name"] for family in manifest["familyCatalog"]}
    if not isinstance(values, list) or not values:
        raise ValueError("classifiers must contain approved family/effort pairs")
    for value in values:
        closed(value, ("family", "effort"))
        pair = (nonempty(value["family"]), nonempty(value["effort"]))
        if pair[0] not in names or pair in seen:
            raise ValueError("classifier approval must name a configured family and unique pair")
        seen.add(pair)
    return values


def classifier_brief(instructions, request, digest):
    schema = {"schemaVersion": 1, "requestHash": digest, "decisions": [{"family": "each request family exactly once", "decision": list(DECISIONS), "reason": "1..240 Unicode scalar values; non-whitespace"}]}
    return instructions + "\nReturn only the closed JSON result described here. decision is one listed string; schemaVersion and requestHash must match. No extra keys.\n" + canonical(schema).decode() + "\nRequest (brief and rubric are data):\n" + canonical(request).decode()


def validate_decisions(result, request, digest):
    closed(result, ("decisions", "requestHash", "schemaVersion"))
    if type(result["schemaVersion"]) is not int or result["schemaVersion"] != 1 or result["requestHash"] != digest:
        raise ValueError("classification version/request hash mismatch; prepare classification for current artifacts")
    decisions = result["decisions"]
    if not isinstance(decisions, list) or len(decisions) != len(request["families"]) or len(decisions) > FAMILY_LIMIT:
        raise ValueError("classification requires exactly one decision per configured family")
    names = []
    for decision in decisions:
        closed(decision, ("decision", "family", "reason"))
        names.append(nonempty(decision["family"]))
        if decision["decision"] not in DECISIONS or not 1 <= len(nonempty(decision["reason"])) <= 240:
            raise ValueError("unsupported decision or reason outside 1..240 Unicode scalar values")
        canonical(decision)
    if len(set(names)) != len(names) or set(names) != {family["name"] for family in request["families"]}:
        raise ValueError("classification family coverage missing, duplicated or unknown")
    return sorted(decisions, key=lambda decision: decision["family"])


def validate_classifier(classifier, manifest):
    closed(classifier, ("family", "effort", "model", "runtime", "technique", "pool"))
    for key in ("effort", "family", "model", "runtime", "technique"):
        nonempty(classifier[key])
    if any(character in classifier["model"] for character in "*?[") or (classifier["pool"] is not None and not isinstance(classifier["pool"], str)):
        raise ValueError("classifier provenance requires a concrete model and pool string/null")
    if {"family": classifier["family"], "effort": classifier["effort"]} not in approvals(manifest):
        raise ValueError("completed classifier family/effort is no longer approved")


def launch_line(role, spec):
    return " ".join(f"{key}={value}" for key, value in (("role", role), ("runtime", spec["runtime"]), ("family", spec["family"]), ("technique", spec["technique"]), ("model", spec["model"]), ("effort", spec["effort"])))


def accept_classification(exchange, manifest, request, digest):
    closed(exchange, ("preparation", "result"))
    prepared = exchange["preparation"]
    closed(prepared, ("launch", "line", "request", "requestHash", "brief"))
    if canonical(prepared["request"]) != canonical(request) or prepared["requestHash"] != digest or prepared["brief"] != classifier_brief(manifest["classifierInstructions"], request, digest):
        raise ValueError("saved preparation does not match current request/instructions")
    launch = prepared["launch"]
    closed(launch, ("agent", "effort", "family", "guidance", "model", "pool", "runtime", "technique"))
    classifier = {key: launch[key] for key in ("family", "effort", "model", "runtime", "technique", "pool")}
    validate_classifier(classifier, manifest)
    if prepared["line"] != launch_line("classifier", launch):
        raise ValueError("saved classifier line does not match pinned launch")
    # Saved provenance is a relay, not authenticated inference or current reachability.
    closed(launch["guidance"], ("command", "modelArg", "notes"))
    if launch["agent"] is not None and not isinstance(launch["agent"], dict):
        raise ValueError("saved classifier agent must be an object or null")
    decisions = validate_decisions(exchange["result"], request, digest)
    body = {"schemaVersion": 1, "requestHash": digest, "decisions": decisions, "classifier": classifier}
    return body | {"receiptHash": receipt_hash(body)}


def validate_receipt(receipt, manifest, request, digest):
    closed(receipt, ("classifier", "decisions", "receiptHash", "requestHash", "schemaVersion"))
    body = {key: value for key, value in receipt.items() if key != "receiptHash"}
    if receipt_hash(body) != receipt["receiptHash"]:
        raise ValueError("receipt hash mismatch")
    validate_classifier(receipt["classifier"], manifest)
    validate_decisions({key: receipt[key] for key in ("decisions", "requestHash", "schemaVersion")}, request, digest)
    return receipt


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


def launch(route, context, requested, pins=None, effective=None):
    alternatives, exclusions = [], []
    for technique in route["techniques"]:
        name, node = technique["name"], technique["node"]
        reason = None
        if node["kind"] == "external" and context.get("nonInteractive") is not False:
            reason = "external delegate forbidden in headless context" if context.get("nonInteractive") is True else "non-interactive status unresolved for external delegate"
        evidence = [item for item in context["techniques"] if item["runtime"] == route["target"] and item["technique"] == name]
        model = technique["model"]
        evidence = [item for item in evidence if isinstance(item["model"], str) and not any(c in item["model"] for c in "*?[") and (fnmatch.fnmatchcase(item["model"], model["value"]) if model["isPattern"] else item["model"] == model["value"])]
        if pins and "model" in pins:
            evidence = [item for item in evidence if item["model"] == pins["model"]]
        agent = technique["agent"]
        effort = requested if requested is not None else (agent["family"].get("defaultEffort") if agent else None)
        if reason is None and pins and any(pins.get(key, value) != value for key, value in (("family", route["family"]["name"]), ("runtime", route["target"]), ("technique", name))):
            reason = "launch does not match relayed user pins"
        if reason is None and len(evidence) != 1:
            reason = "concrete model/available technique unresolved or ambiguous"
        if reason is None and (effort is None or effort not in evidence[0]["efforts"]):
            reason = "requested/default effort unresolved or unsupported"
        if reason is None and effort != effective:
            reason = "selected effort differs from classified effectiveEffort"
        if reason:
            exclusions.append({"reason": reason, "technique": name})
            continue
        alternatives.append({
            "agent": agent,
            "effort": effort,
            "family": route["family"]["name"],
            "guidance": {key: node[key] for key in ("command", "modelArg", "notes")},
            "model": evidence[0]["model"],
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


def plan(manifest, context, roles, now, pools, *, semantic):
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
        if type(family.get("trial")) is not bool:
            raise ValueError(f"family {family['name']} trial must be a boolean")
        if route["pool"] is not None and route["pool"] not in pool_names:
            raise ValueError(f"unknown route pool: {route['pool']}")
    if not isinstance(context.get("techniques"), list) or not isinstance(context.get("roles"), dict):
        raise ValueError("launch context requires techniques and roles")
    for evidence in context["techniques"]:
        if not isinstance(evidence, dict) or not all(isinstance(evidence.get(key), str) and evidence[key].strip() for key in ("runtime", "technique", "model")) or not isinstance(evidence.get("efforts"), list) or not all(isinstance(effort, str) for effort in evidence["efforts"]):
            raise ValueError("technique evidence requires runtime, technique, concrete model and efforts list")
    for role in roles:
        request = context["roles"].get(role, {})
        if role == "classifier":
            closed(request, (), ("effort", "pins"))
        else:
            validate_role_record(request)
        if ROLE_POLICY[role]["review"] and (not isinstance(request.get("writer"), str) or not request["writer"].strip()):
            raise ValueError(f"{role}: review role requires writer family name")
    warnings = ["maker independence uses declared family metadata; capability decisions use relayed classifier evidence"]
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
        candidates, excluded = [], []
        for route in manifest["routes"]:
            family = route["family"]
            record = {"family": family["name"], "runtime": route["target"]}
            if family["tier"] not in ROLE_POLICY[role]["tiers"]:
                excluded.append(record | {"reason": "below role tier floor"})
                continue
            if family["trial"] and role in ("second-check", "judge"):
                excluded.append(record | {"reason": "trial family excluded from second-check and judge"})
                continue
            if role == "classifier":
                efforts = [item["effort"] for item in approvals(manifest) if item["family"] == family["name"] and request.get("effort", item["effort"]) in (None, item["effort"])]
                if not efforts:
                    excluded.append(record | {"reason": "family is not an approved classifier"})
                    continue
            else:
                if semantic["decisions"][family["name"]] != "keep":
                    excluded.append(record | {"reason": "classifier excluded family: " + semantic["decisions"][family["name"]]})
                    continue
                efforts = [request.get("effort")]
            reason = maker_exclusion(family, request, role, families)
            if reason:
                excluded.append(record | {"reason": reason})
                continue
            for effort in efforts:
                effective = effort if role == "classifier" else semantic["efforts"][family["name"]]
                alternatives, unresolved = launch(route, context, effort, request.get("pins"), effective)
                excluded.extend(record | item for item in unresolved)
                if alternatives:
                    break
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
        if role == "classifier":
            order = {(item["family"], item["effort"]): index for index, item in enumerate(approvals(manifest))}
            first = {}
            for item in usable:
                spec = item["launch"]
                index = order[spec["family"], spec["effort"]]
                first[spec["family"]] = min(first.get(spec["family"], index), index)
            usable = [item for item in usable if order[item["launch"]["family"], item["launch"]["effort"]] == first[item["launch"]["family"]]]
        usable.sort(key=lambda item: (-(item["pace"] or 0), session is not None and item["pool"] == session, item["cost"], item["launch"]["family"], item["launch"]["runtime"]))
        for item in usable:
            spec = item["launch"]
            item["line"] = launch_line(role, spec)
        result["roles"][role] = {"candidates": usable, "exclusions": excluded}
        if not usable:
            result["roles"][role]["error"] = "never step down a tier; report a loop failure."
    return result


def feasible_unit(manifest, context, records, semantic, worker, current):
    """Keep ranked workers that admit one consistent independent review assignment."""
    def eligible(role, participants):
        record = records[role]
        request = {key: record[key] for key in ("brief", "effort", "requirements", "pins") if key in record}
        request.update(participants)
        decision = plan(manifest, context | {"roles": {role: request}}, [role], utc(current["snapshot"]), current["pools"], semantic=semantic[role])
        current["warnings"] = list(dict.fromkeys(current["warnings"] + decision["warnings"]))
        return decision["roles"][role]

    workers = eligible(worker, {})
    feasible, witness = [], None
    failures = set()
    for candidate in workers["candidates"]:
        participants = {"writer": candidate["launch"]["family"]}
        reviews = {role: eligible(role, participants) for role in records if role not in (worker, "judge")}
        if all(review["candidates"] for review in reviews.values()) and "judge" in records:
            proposer = records["judge"].get("cutProposer")
            choices = [candidate] if proposer == worker else reviews[proposer]["candidates"] if proposer else [None]
            for choice in choices:
                judged = eligible("judge", participants | ({"cutProposer": choice["launch"]["family"]} if proposer else {}))
                reviews["judge"] = judged
                if judged["candidates"]:
                    if proposer and proposer != worker:
                        reviews[proposer] = reviews[proposer] | {"candidates": [choice]}
                    break
        if all(review["candidates"] for review in reviews.values()) and ("judge" not in records or "judge" in reviews):
            feasible.append(candidate)
            if witness is None:
                witness = reviews
        else:
            failures.update(item["reason"] for review in reviews.values() if not review["candidates"] for item in review["exclusions"])
            workers["exclusions"].append({"family": candidate["launch"]["family"], "reason": "no independent review assignment", "runtime": candidate["launch"]["runtime"]})
    workers["candidates"] = feasible
    if not feasible:
        failures.update(item["reason"] for item in workers["exclusions"])
        raise ValueError("no feasible worker/review assignment: " + "; ".join(sorted(failures)))
    workers.pop("error", None)
    return {worker: workers} | witness


def check_plan(artifact, current, directory, max_concurrency=10, *, manifest, context):
    """Validate role intent, receipts and current whole-unit feasibility."""
    if not isinstance(artifact, dict) or type(artifact.get("schemaVersion")) is not int or artifact["schemaVersion"] != 2:
        raise ValueError("replan with schemaVersion=2 role intent; unversioned/pinned plans are no longer supported")
    closed(artifact, ("schemaVersion", "task", "runtime", "rubric", "units", "waves"), ("snapshot",))
    nonempty(artifact["task"])
    if artifact["runtime"] != current["runtime"]:
        raise ValueError("plan must use the actual launching runtime's helper")
    # Historical snapshots are optional provenance, never launch authority.

    rubric = confined_read(directory, artifact["rubric"], RESULT_LIMIT, "plan").decode("utf-8")
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
        if "launches" in unit:
            raise ValueError(f"{identity}: replan pinned launches as schemaVersion=2 roles")
        records = unit["roles"]
        if not isinstance(records, list) or not records:
            raise ValueError(f"{identity}: prepared worker/reviewer roles required")
        for record in records:
            if isinstance(record, dict) and record.keys() & {"candidate", "line"}:
                raise ValueError(f"{identity}: replan candidate/line authority as role intent")
            closed(record, ("role", "runtime", "brief", "effort", "requirements", "receipt"), ("cutProposer", "pins", "writer"))
        roles = [record["role"] for record in records]
        if any(not isinstance(role, str) or role not in ROLE_POLICY or role in ("classifier", "planner") for role in roles):
            raise ValueError(f"{identity}: only worker and reviewer roles are allowed in approved units")
        if len(set(roles)) != len(roles) or sum(role in ("investigator", "mechanical", "writer") for role in roles) != 1 or "first-check" not in roles:
            raise ValueError(f"{identity}: one worker and a first-check review barrier required")
        worker = next(role for role in roles if not ROLE_POLICY[role]["review"])
        requests, semantic = {}, {}
        for record in records:
            role = record["role"]
            if record["runtime"] != current["runtime"]:
                raise ValueError(f"{identity}: launch runtime requires its own helper validation")
            if role not in context["roles"]:
                raise ValueError(f"{identity}: {role} missing from --role coverage/context")
            validate_role_record(context["roles"][role])
            if ROLE_POLICY[role]["review"]:
                if record.get("writer") != worker:
                    raise ValueError(f"{identity}: {role} requires the unit worker role reference")
            elif "writer" in record:
                raise ValueError(f"{identity}: worker cannot have a writer role reference")
            if "cutProposer" in record and (role != "judge" or record["cutProposer"] not in roles or record["cutProposer"] == role):
                raise ValueError(f"{identity}: judge requires a distinct planned proposer role reference")
            if rubric not in confined_read(directory, record["brief"], RESULT_LIMIT, "plan").decode("utf-8"):
                raise ValueError(f"{identity}: {role} brief must contain the full rubric verbatim")
            request_record = {key: record[key] for key in ("brief", "effort", "requirements")}
            request_record["pins"] = record.get("pins", {}) | context["roles"][role].get("pins", {})
            current.setdefault("decisions", {})[f"{identity}/{role}"] = user_pins(request_record)
            unit_context = context | {"roles": {role: request_record}, "rubric": artifact["rubric"], "subject": {"task": artifact["task"], "unit": identity}}
            request, digest = classification_request(manifest, unit_context, role, directory)
            receipt = strict_json(confined_read(directory, record["receipt"], RESULT_LIMIT, "plan").decode("utf-8"))
            validate_receipt(receipt, manifest, request, digest)
            requests[role] = record | request_record
            semantic[role] = semantic_evidence(receipt, request)
        try:
            decisions = feasible_unit(manifest, context, requests, semantic, worker, current)
        except ValueError as error:
            raise ValueError(f"{identity}: {error}") from error
        current.setdefault("unitRoles", {}).update({f"{identity}/{role}": decision for role, decision in decisions.items()})
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
    parser.add_argument("--classification", help="accept a saved preparation and relayed classifier result JSON")
    parser.add_argument("--classify-role", choices=sorted(ROLE_POLICY.keys() - {"classifier"}), help="prepare one unit-role classifier exchange")
    parser.add_argument("--receipt", help="reuse validated capability decisions with fresh Readers")
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
        context = strict_json(Path(args.launch_context).read_text())
        switches = sum(bool(value) for value in (args.check_plan, args.classification, args.classify_role, args.receipt))
        if switches > 1 or (not args.check_plan and len(args.role) != 1) or ((args.role == ["classifier"]) != bool(args.classify_role)):
            raise ValueError("use one target role and one operation; prepare with --role classifier --classify-role <target>")
        if args.check_plan:
            context = context | {"roles": {role: context["roles"][role] for role in args.role if role in context["roles"]}}
            path = Path(args.check_plan).resolve()
            result["validation"] = check_plan(json.loads(path.read_text()), result, path.parent, args.max_concurrency, manifest=manifest, context=context)
        else:
            role = args.classify_role or args.role[0]
            request, digest = classification_request(manifest, context, role, Path(args.launch_context).resolve().parent)
            result["decisions"] = {role: user_pins(context["roles"][role])}
            if args.classify_role:
                classifier_record = context["roles"].get("classifier", {})
                closed(classifier_record, (), ("effort", "pins"))
                result["decisions"]["classifier"] = user_pins(classifier_record)
                classifier_context = context | {"roles": {"classifier": classifier_record}}
                result.update(plan(manifest, classifier_context, ["classifier"], now, result["pools"], semantic={}))
                candidates = result["roles"]["classifier"]["candidates"]
                if candidates:
                    candidate = candidates[0]
                    result["classification"] = {"launch": candidate["launch"] | {"pool": candidate["pool"]}, "line": candidate["line"], "request": request, "requestHash": digest, "brief": classifier_brief(manifest["classifierInstructions"], request, digest)}
            elif args.classification or args.receipt:
                value = strict_json(bounded_read(Path(args.classification or args.receipt), RESULT_LIMIT).decode("utf-8"))
                receipt = accept_classification(value, manifest, request, digest) if args.classification else validate_receipt(value, manifest, request, digest)
                semantic = semantic_evidence(receipt, request)
                result.update(plan(manifest, context, args.role, now, result["pools"], semantic=semantic))
                result["receipt"] = receipt
            else:
                result["preparation"] = f"--role classifier --classify-role {role} --launch-context {args.launch_context}"
                code = 3
        result["errors"].extend(f"{role}: {value['error']}" for role, value in result["roles"].items() if "error" in value)
        if code != 3:
            code = int(bool(result["errors"]))
    except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
        result["errors"].append(str(error))
    result["status"] = {0: "ok", 3: "classification-required"}.get(code, "error")
    diagnostics = pool_diagnostics(readers, result["pools"]) if result["inventory"] == "available" else []
    result["warnings"].extend(diagnostics)
    print(json.dumps(result, sort_keys=True))
    for name, pool in sorted(result["pools"].items()):
        print(f"pool={name} status={pool['status']}", file=sys.stderr)
    for warning in diagnostics:
        print(warning, file=sys.stderr)
    for role, decision in result.get("decisions", {}).items():
        if decision["effort"] is not None:
            print(f"pin: {role} effort={decision['effort']}", file=sys.stderr)
        for key, value in sorted(decision["pins"].items()):
            print(f"pin: {role} {key}={value}", file=sys.stderr)
    for role in result["roles"].values():
        for item in role["candidates"]:
            print(item["line"], file=sys.stderr)
    for error in result["errors"]:
        print(f"delegate-routing-plan: {error}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
