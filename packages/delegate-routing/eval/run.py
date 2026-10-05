#!/usr/bin/env python3
"""Manual, account-free rendering and strict replay grading of routing plans.

All authenticated adapters are intentionally disabled. Enabling one requires
independent tool-suppression and terminal-capture evidence, not a CLI switch.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
from itertools import permutations
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile

from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MAX_BYTES = 2 * 1024 * 1024
SIZING = ("runtime", "family", "model", "effort", "technique")
WRAPPER = (
    "This is a routing simulation. The skill and scenario below describe a "
    "fictional session. Use only those facts. Return a plan for that session. "
    "Do not execute the task, invoke tools, probe accounts or launch delegates. "
    "Use the requested JSON structure. A technique listed in the scenario is "
    "available only in the simulation. List the usage observations you inspected "
    "and usageBefore for every planned delegate, including reviewers. Return exactly one JSON object, with "
    "no fences or surrounding commentary."
)


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    data = value if isinstance(value, bytes) else value.encode()
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_json(path, value):
    path.write_text(encode(value))


def strict_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def constant(value):
        raise ValueError(f"invalid JSON constant: {value}")

    if len(raw.encode()) > MAX_BYTES:
        raise ValueError("answer exceeds output cap")
    result = json.loads(raw, object_pairs_hook=unique, parse_constant=constant)
    if not isinstance(result, dict):
        raise ValueError("answer must be one JSON object")
    return result


def load_cases(path):
    if path:
        return json.loads(Path(path).read_text())
    result = subprocess.run(
        ["nix", "eval", "--json", ".#checks.x86_64-linux.delegate-routing-eval-structure.cases"],
        cwd=REPO, capture_output=True, text=True, timeout=300, check=False,
        env={**os.environ, "NIX_CONFIG": os.environ.get("NIX_CONFIG", "") + "\nmax-jobs = 1\ncores = 2\n"},
    )
    if result.returncode:
        raise ValueError(f"fixture evaluation failed: {result.stderr}")
    return json.loads(result.stdout)


def validate_fixtures(cases, schema):
    Draft202012Validator.check_schema(schema)
    if not isinstance(cases, list) or not cases:
        raise ValueError("fixtures must be a nonempty list")
    ids = set()
    required = {"id", "scenario", "inventory", "capabilities", "usage", "expected", "rendered"}
    expected_targets = {
        "decisionTuples": ("selection",), "effortSource": ("selection", "effortSource"),
        "owner": ("owner",), "partial": None, "pendingAssertions": None, "requiredLimitationCodes": ("limitations", "*", "code"),
        "reviewDecisionTuples": ("review", "delegates", "*", "model"),
        "reviewRoles": ("review", "delegates", "*", "role"),
        "reviewWorkflow": ("review", "workflow"), "shape": ("shape",),
        "stages": ("stages", "*", "id"), "status": ("status",),
        "usageInspections": ("usageInspections",),
    }
    def target_exists(node, path):
        if "$ref" in node:
            resolved = schema
            for segment in node["$ref"].removeprefix("#/").split("/"):
                resolved = resolved[segment]
            return target_exists(resolved, path)
        if not path:
            return True
        if path[0] == "*" and "items" in node:
            return target_exists(node["items"], path[1:])
        if path[0] in node.get("properties", {}):
            return target_exists(node["properties"][path[0]], path[1:])
        return any(target_exists(branch, path) for key in ("allOf", "anyOf", "oneOf") for branch in node.get(key, []))
    for target in [("selection", key) for key in SIZING] + [("stages", "*", key) for key in SIZING] + [("review", "delegates", "*", key) for key in SIZING]:
        if not target_exists(schema, target):
            raise ValueError(f"sizing targets missing schema path: {target}")
    for name, target in expected_targets.items():
        if target and not target_exists(schema, target):
            raise ValueError(f"expected field {name} targets missing schema path: {target}")
    def validate_usage(usage, label):
        if not isinstance(usage, dict):
            raise ValueError(f"{label}: usage must be an observation mapping")
        for oid, mock in usage.items():
            if not isinstance(mock, dict) or not isinstance(mock.get("stdout"), str) or type(mock.get("exitCode")) is not int:
                raise ValueError(f"{label}/{oid}: invalid mock stdout or exitCode")
            command = mock.get("command")
            if not 0 <= mock["exitCode"] <= 255 or not isinstance(command, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", command):
                raise ValueError(f"{label}/{oid}: invalid mock command or exit status")

    for case in cases:
        if not isinstance(case, dict) or not required <= case.keys():
            raise ValueError("case missing required fixture fields")
        cid = case["id"]
        if not isinstance(cid, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", cid) or cid in ids:
            raise ValueError(f"invalid or duplicate case id: {cid!r}")
        ids.add(cid)
        if not isinstance(case["rendered"].get("skill"), str) or not isinstance(case["rendered"].get("rules"), str):
            raise ValueError(f"{cid}: rendered skill/rules must be strings")
        if not case["rendered"]["skill"].strip():
            raise ValueError(f"{cid}: rendered skill must be nonempty")
        expected = case["expected"]
        if "partial" in expected and type(expected["partial"]) is not bool:
            raise ValueError(f"{cid}: partial must be a boolean")
        if "pendingAssertions" in expected:
            pending = expected["pendingAssertions"]
            if not isinstance(pending, list) or any(not isinstance(item, str) or not item.strip() for item in pending):
                raise ValueError(f"{cid}: pendingAssertions must be nonempty strings")
        if expected.get("partial"):
            if not expected.get("pendingAssertions") or expected.get("decisionTuples"):
                raise ValueError(f"{cid}: partial cases need pending assertions and no complete selection tuples")
        unknown = set(expected) - set(expected_targets)
        if unknown:
            raise ValueError(f"{cid}: unsupported expected fields: {sorted(unknown)}")
        for item in expected.get("decisionTuples", []):
            if not isinstance(item, list) or len(item) != 6:
                raise ValueError(f"{cid}: decision tuples need six fields")
        for wanted in expected.get("stages", []):
            if not isinstance(wanted, dict):
                raise ValueError(f"{cid}: expected stages must be objects")
            for key in wanted:
                if key not in {*SIZING, "id", "actor", "dependsOn"} or not target_exists(schema, ("stages", "*", key)):
                    raise ValueError(f"{cid}: unsupported expected stage field: {key}")
        validate_usage(case["usage"], cid)
        variants = case.get("usageVariants", [])
        if not isinstance(variants, list):
            raise ValueError(f"{cid}: usageVariants must be a list")
        for variant in variants:
            if not isinstance(variant, dict) or "id" not in variant or "usage" not in variant:
                raise ValueError(f"{cid}: usage variant needs id and usage")
            validate_usage(variant["usage"], f"{cid}/{variant['id']}")



def safe_output(path):
    path = path.expanduser().resolve()
    for parent in (path, *path.parents):
        if (parent / ".git").exists():
            raise ValueError("output must be outside every Git checkout")
    if path.exists() and any(path.iterdir()):
        raise ValueError(f"output directory must be empty: {path}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def execute_mocks(case, directory):
    bin_dir = directory / "bin"
    bin_dir.mkdir()
    observations = {}
    for index, (oid, mock) in enumerate(sorted(case["usage"].items())):
        command_name = mock["command"]
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", command_name):
            raise ValueError(f"mock command must be a simple executable name: {command_name!r}")
        script = bin_dir / command_name
        script.write_text(
            f"#!{sys.executable}\nimport sys\nsys.stdout.write({mock['stdout']!r})\nsys.exit({mock['exitCode']!r})\n"
        )
        script.chmod(0o700)
        result = subprocess.run([str(script)], cwd=directory, capture_output=True, timeout=10, check=False)
        script.chmod(0o600)
        observation = {
            **mock,
            "stdout": result.stdout.decode(),
            "exitCode": result.returncode,
            "observationId": oid,
            "executedArgv": [str(script)],
        }
        observations[oid] = observation
        (directory / f"mock-{index}.stdout").write_bytes(result.stdout)
        (directory / f"mock-{index}.stderr").write_bytes(result.stderr)
    return observations


def prompt_for(case, observations, schema):
    # Explicit projection prevents expected answers from reaching candidate input.
    facts = {key: case[key] for key in ("id", "scenario", "inventory", "capabilities", "configVariant", "proseCriteria") if key in case}
    return "\n\n".join([
        WRAPPER, "Always-on rules:\n" + case["rendered"]["rules"],
        "Skill:\n" + case["rendered"]["skill"], "Simulation facts:\n" + encode(facts),
        "Runner-executed usage observations:\n" + encode({oid: {key: value for key, value in observation.items() if key != "executedArgv"} for oid, observation in observations.items()}), "Answer schema:\n" + encode(schema),
    ])


def grade(case, raw, validator):
    errors = []
    try:
        answer = strict_json(raw)
        schema_errors = sorted(validator.iter_errors(answer), key=lambda error: str(list(error.path)))
        if schema_errors:
            return {
                "passed": False,
                "errors": [f"schema {list(error.path)}: {error.message}" for error in schema_errors],
                "selection": None,
            }
    except (ValueError, json.JSONDecodeError) as error:
        return {"passed": False, "errors": [f"parse: {error}"], "selection": None}

    def require(condition, message):
        if not condition:
            errors.append(message)

    expected = case["expected"]
    scenario = case["scenario"]
    caps = case["capabilities"]
    selection = answer["selection"]
    selected = [selection[key] for key in SIZING] + [answer["shape"]] if selection else None
    require(answer["caseId"] == case["id"], "caseId mismatch")
    if expected.get("decisionTuples"):
        require(selected in expected["decisionTuples"], "complete selection tuple is not allowed")
    for key in ("status", "shape", "owner"):
        if key in expected:
            require(answer[key] == expected[key], f"{key} mismatch")
    if "reviewWorkflow" in expected:
        require(answer["review"]["workflow"] == expected["reviewWorkflow"], "review workflow mismatch")
    if answer["shape"] in {"native_child", "native_workflow", "native_children", "external_cli_graph", "session_steps"}:
        require(answer["owner"] == "session", "host session must own completion for this shape")
    elif answer["shape"] == "external_root":
        require(answer["owner"] == "external-root", "external root must own completion")
    reviewers = answer["review"]["delegates"]
    if "reviewRoles" in expected:
        require(sorted(record["role"] for record in reviewers) == sorted(expected["reviewRoles"]), "review role/count mismatch")
    limitations = {item["code"] for item in answer["limitations"]}
    codes = expected.get("requiredLimitationCodes", [])
    require(set(codes) <= limitations, "required limitation missing")
    observations = set(case["usage"])
    require(set(answer["usageInspections"]) <= observations, "unknown usage inspection")
    require(set(expected.get("usageInspections", [])) <= set(answer["usageInspections"]), "required usage inspection missing")

    records = ([selection] if selection else []) + answer["stages"] + reviewers
    techniques = {(item["runtime"], item["name"]): item for item in caps.get("techniques", [])}
    inventory = {(item["runtime"], item["family"], item["model"]): item for item in case["inventory"]}
    for record in records:
        label = record.get("id", record.get("actor", "selection"))
        item = inventory.get(tuple(record[key] for key in ("runtime", "family", "model")))
        if item is None:
            item = next((candidate for candidate in case["inventory"] if candidate["runtime"] == record["runtime"] and candidate["family"] == record["family"] and candidate.get("alias") == record["model"]), None)
        require(item is not None, f"{label}: model/runtime/family absent from inventory")
        if item:
            require(record["effort"] in (item["efforts"] or [None]), f"{label}: effort absent from inventory")
            require((record["effort"] is None) == (record["effortSource"] == "not_applicable"), f"{label}: fixed effort source mismatch")
        require(record["effortSource"] != "unknown", f"{label}: unknown effort cannot pass")
        if record["technique"] == "inline":
            parent = selection if answer["shape"] == "external_root" else {"runtime": scenario["runtime"], "model": scenario.get("knownInheritedModel"), "effort": scenario.get("knownInheritedEffort")}
            require(parent is not None and all(record[key] == parent[key] for key in ("runtime", "model", "effort")), f"{label}: inline controls disagree with owning session/root")
            continue
        technique = techniques.get((record["runtime"], record["technique"]))
        require(technique is not None, f"{label}: unavailable technique")
        if not technique:
            continue
        external = technique["kind"] == "external"
        launched_mode = "headless" if external or answer["shape"] == "external_root" and record in answer["stages"] else scenario["mode"]
        require(launched_mode in technique["modes"], f"{label}: technique unavailable in mode")
        available = scenario["commandsOnPath"] if external else scenario["visibleTools"]
        external_child = answer["shape"] == "external_root" and record in answer["stages"] and caps.get("externalChildren") == "supported" and selection and record["runtime"] == selection["runtime"]
        require(record["technique"] in available or external_child, f"{label}: technique not visible/available")
        if not technique["pinsModel"]:
            require(record["model"] == scenario.get("knownInheritedModel"), f"{label}: model cannot be pinned and is not known inherited")
        if record["effort"] is not None and not technique["pinsEffort"]:
            require(record["effortSource"] == "known_inherited" and record["effort"] == scenario.get("knownInheritedEffort"), f"{label}: effort cannot be pinned and is not known inherited")
        elif record["effort"] is not None:
            require(record["effortSource"] == "explicit", f"{label}: pinned effort must be explicit")

    if selection and "effortSource" in expected:
        require(selection["effortSource"] == expected["effortSource"], "selection effort source mismatch")
    for reviewer in reviewers:
        require(set(reviewer["usageBefore"]) <= observations, "unknown review usage observation")
        if expected.get("reviewDecisionTuples"):
            require(any([reviewer[key] for key in SIZING] == item[:5] for item in expected["reviewDecisionTuples"]), "review delegate tuple not allowed")
        if case.get("configVariant") == "house-pool-drain":
            require(set(expected.get("usageInspections", [])) <= set(reviewer.get("usageBefore", [])), "review usage placement missing")
    stages = answer["stages"]
    ids = {stage["id"] for stage in stages}
    require(len(ids) == len(stages), "stage IDs must be distinct")
    graph = {stage["id"]: stage["dependsOn"] for stage in stages}
    for stage in stages:
        require(set(stage["dependsOn"]) <= ids and stage["id"] not in stage["dependsOn"], "invalid stage dependency")
        require(set(stage["usageBefore"]) <= observations, "unknown stage usage observation")
        required_usage = expected.get("usageInspections", []) if case.get("configVariant") == "house-pool-drain" else []
        if stage["technique"] != "inline":
            require(set(required_usage) <= set(stage["usageBefore"]), "delegate usage placement missing")
    visiting, visited = set(), set()
    def visit(node):
        if node in visiting:
            return False
        if node in visited:
            return True
        visiting.add(node)
        valid = all(visit(dep) for dep in graph.get(node, []) if dep in graph)
        visiting.remove(node)
        visited.add(node)
        return valid
    require(all(visit(node) for node in graph), "cyclic stage dependencies")
    if "stages" in expected:
        expected_stages = expected["stages"]
        require(len(stages) == len(expected_stages), "stage structure count mismatch")
        # IDs are illustrative. Match sizing, topology, and actor equality,
        # independent of the order a valid DAG was serialized in.
        def graph_matches(candidate):
            mapping = {wanted["id"]: got["id"] for wanted, got in zip(expected_stages, candidate)}
            actor_mapping = {}
            for wanted, got in zip(expected_stages, candidate):
                if not all(got[key] == wanted[key] for key in SIZING):
                    return False
                if set(got["dependsOn"]) != {mapping.get(dep) for dep in wanted["dependsOn"]}:
                    return False
                if actor_mapping.setdefault(wanted["actor"], got["actor"]) != got["actor"]:
                    return False
                if wanted["actor"] == expected.get("owner") and got["actor"] != answer["owner"]:
                    return False
            return len(set(actor_mapping.values())) == len(actor_mapping)
        # Fixtures are deliberately tiny; cap enumeration on malformed outputs.
        require(len(stages) == len(expected_stages) and len(stages) <= 7 and any(graph_matches(candidate) for candidate in permutations(stages)), "stage sizing/topology/ownership mismatch")
    actors = [record["actor"] for record in reviewers]
    require(len(set(actors)) == len(actors), "review actors must be distinct")
    writer_actors = {stage["actor"] for stage in stages if stage["actor"] not in actors}
    pdj = (
        expected.get("reviewWorkflow") == "Review: prosecute, defend, judge"
        and set(expected.get("reviewRoles", [])) == {"prosecutor", "defender", "judge"}
    )
    if pdj:
        require(len(stages) == 3 and {stage["actor"] for stage in stages} == set(actors), "PDJ requires exactly its three review actors as stages")
        require(selection is not None and any(all(stage[key] == selection[key] for key in SIZING) for stage in stages), "PDJ selection has no corresponding review stage")
        by_role = {reviewer["role"]: reviewer for reviewer in reviewers}
        role_stages = {
            role: next((stage for stage in stages if stage["actor"] == reviewer["actor"]), None)
            for role, reviewer in by_role.items()
        }
        if all(role_stages.get(role) is not None for role in ("prosecutor", "defender", "judge")):
            arguments = {role_stages[role]["id"] for role in ("prosecutor", "defender")}
            require(set(role_stages["judge"]["dependsOn"]) == arguments, "PDJ judge must depend directly on both arguments")
    elif selection and not expected.get("stages"):
        writer_stages = [stage for stage in stages if all(stage[key] == selection[key] for key in SIZING)]
        require(bool(writer_stages), "selection has no corresponding writer/owner stage")
        require(any(stage["actor"] not in actors for stage in writer_stages), "reviewer cannot own its reviewed writer stage")
        if answer["shape"] == "external_root":
            require(any(stage["actor"] == answer["owner"] for stage in writer_stages), "external root stage must be owned by its root")
        require(len(stages) == 1 + sum(stage["actor"] in actors for stage in stages), "single task has unrelated writer stages")
    if expected.get("reviewWorkflow") == "Review: one reviewer":
        for reviewer in reviewers:
            review_stages = [stage for stage in stages if stage["actor"] == reviewer["actor"]]
            require(len(review_stages) == 1, "reviewer must have exactly one stage")
            if len(review_stages) == 1:
                writer_ids = {stage["id"] for stage in stages if stage["actor"] not in actors}
                require(bool(writer_ids) and set(review_stages[0]["dependsOn"]) == writer_ids, "review stage must follow all writer stages")
    for reviewer in reviewers:
        for stage in stages:
            if stage["actor"] == reviewer["actor"]:
                require(all(stage[key] == reviewer[key] for key in SIZING), "review stage sizing disagrees with delegate")
    if answer["status"] == "planned":
        require(answer["owner"] in writer_actors | set(actors) | {"session", "external-root"}, "completion owner has no actor")
    if answer["shape"] == "external_root" and len(writer_actors) > 1:
        require(caps.get("externalChildren") == "supported", "external children lack supported capability evidence")
    if answer["shape"] == "external_cli_graph":
        require(caps.get("externalCoordination") == "supported", "external coordination unavailable")
    return {
        "passed": not errors,
        "errors": errors,
        "selection": selected,
        "prose": "pending: no authenticated judge",
        "pendingAssertions": expected.get("pendingAssertions", ["selection fallback"] if expected.get("partial") else []),
    }


def disabled_adapter(runtime):
    raise ValueError(f"UNSUPPORTED_SAFE_PLAN_MODE: {runtime} adapter is disabled; independently verified suppression and terminal capture are required")


def provenance(args, cases, schema):
    def git(*argv):
        result = subprocess.run(["git", *argv], cwd=REPO, capture_output=True, check=False)
        return result.stdout
    diff = git("diff", "HEAD")
    return {
        "startedAt": utc(), "repositoryCommit": git("rev-parse", "HEAD").decode().strip(),
        "dirtyPatchHash": digest(diff), "fixtureHash": digest(encode(cases)), "schemaHash": digest(encode(schema)),
        "rubricHash": digest((HERE / "rubric.md").read_bytes()) if (HERE / "rubric.md").exists() else None,
        "evaluator": {"runtime": args.runtime, "requestedModel": args.model, "requestedEffort": args.effort, "resolvedModel": "UNKNOWN", "resolvedEffort": "UNKNOWN", "version": "UNKNOWN", "executable": "UNKNOWN"},
        "adapters": "disabled: suppression and terminal capture unverified", "judge": "pending; no authenticated calls",
        "repeat": args.repeat, "seed": args.seed, "timeoutSeconds": 120, "outputCapBytes": MAX_BYTES,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--render-only", action="store_true")
    mode.add_argument("--grade-existing", type=Path, metavar="MANIFEST")
    mode.add_argument("--validate-fixtures", action="store_true")
    parser.add_argument("--fixtures", type=Path, help="exported cases JSON; otherwise evaluates the Nix check passthru")
    parser.add_argument("--case", action="append", default=[], help="case ID, repeatable; default all")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--runtime", choices=("claude", "codex", "kiro", "kimchi"))
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--out", type=Path, default=Path(tempfile.gettempdir()) / f"delegate-routing-eval-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{os.getpid()}")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if not (args.render_only or args.grade_existing or args.validate_fixtures):
        if not all((args.runtime, args.model, args.effort)):
            parser.error("live evaluation requires explicit --runtime --model --effort")
        disabled_adapter(args.runtime)
    schema = json.loads((HERE / "plan.schema.json").read_text())
    cases = load_cases(args.fixtures)
    validate_fixtures(cases, schema)
    if args.validate_fixtures:
        print(f"Validated schema and {len(cases)} fixtures; no account access.")
        return 0
    chosen = set(args.case) - {"all"}
    unknown = chosen - {case["id"] for case in cases}
    if unknown:
        parser.error(f"unknown cases: {sorted(unknown)}")
    cases = [case for case in cases if not chosen or case["id"] in chosen]
    out = safe_output(args.out)
    metadata = provenance(args, cases, schema)
    manifest = json.loads(args.grade_existing.read_text()) if args.grade_existing else None
    if manifest:
        evaluator = manifest.get("evaluator", {})
        if not evaluator.get("runtime") or not evaluator.get("version"):
            raise ValueError("grade manifest evaluator must declare runtime and version (UNKNOWN allowed)")
        metadata["evaluator"] = evaluator
        metadata["manifestHash"] = digest(args.grade_existing.read_bytes())
    write_json(out / "metadata.json", metadata)
    write_json(out / "schema.json", schema)
    write_json(out / "cases.json", cases)
    if (HERE / "rubric.md").exists():
        shutil.copyfile(HERE / "rubric.md", out / "rubric.md")
    schedule = [(case, trial) for case in cases for trial in range(1, args.repeat + 1)]
    random.Random(args.seed).shuffle(schedule)
    entries = {}
    if manifest:
        for entry in manifest["trials"]:
            key = (entry["caseId"], entry["trial"])
            if key in entries:
                raise ValueError(f"duplicate manifest trial: {key}")
            entries[key] = entry
    results = []
    validator = Draft202012Validator(schema)
    for case, trial in schedule:
        directory = out / f"{case['id']}-{trial}"
        directory.mkdir()
        variants = case.get("usageVariants", [])
        variant = variants[(trial - 1) % len(variants)] if variants else None
        if variant:
            case = {**case, "usage": variant["usage"]}
        observations = execute_mocks(case, directory)
        prompt = prompt_for(case, observations, schema)
        (directory / "prompt.txt").write_text(prompt)
        (directory / "skill.md").write_text(case["rendered"]["skill"])
        (directory / "rules.md").write_text(case["rendered"]["rules"])
        write_json(directory / "observations.json", observations)
        record = {
            "caseId": case["id"],
            "trial": trial,
            "promptHash": digest(prompt),
            "skillHash": digest(case["rendered"]["skill"]),
            "rulesHash": digest(case["rendered"]["rules"]),
            "caseHash": digest(encode(case)),
            "prose": "pending",
            "pendingAssertions": case["expected"].get("pendingAssertions", ["selection fallback"] if case["expected"].get("partial") else []),
            "partial": bool(case["expected"].get("partial")),
        }
        record["usageVariant"] = variant["id"] if variant else None
        if manifest:
            entry = entries.get((case["id"], trial))
            if not entry or entry.get("infrastructureError"):
                record["infrastructureError"] = entry.get("infrastructureError") if entry else "missing replay trial"
            else:
                filename = entry.get("answer", entry.get("path"))
                if not isinstance(filename, str):
                    record["infrastructureError"] = "manifest answer must be a file path"
                else:
                    base = args.grade_existing.parent.resolve()
                    source = (base / filename).resolve()
                    if Path(filename).is_absolute() or not source.is_relative_to(base):
                        raise ValueError("manifest answer paths must stay within the manifest directory")
                    try:
                        raw_bytes = source.read_bytes()
                        (directory / "answer.raw").write_bytes(raw_bytes)
                        record.update(grade(case, raw_bytes.decode(), validator))
                    except (OSError, UnicodeError) as error:
                        record["infrastructureError"] = str(error)
        else:
            record["renderOnly"] = True
        write_json(directory / "verdict.json", record)
        results.append(record)
    per_case = {}
    for case in cases:
        records = [item for item in results if item["caseId"] == case["id"]]
        behavioral = [item for item in records if "passed" in item]
        full = [item for item in behavioral if not item.get("partial")]
        partial = [item for item in behavioral if item.get("partial")]
        per_case[case["id"]] = {
            "endToEndDenominator": len(records),
            "completedTrials": len(behavioral),
            "completionRate": len(behavioral) / len(records),
            "fullChoiceDenominator": len(full),
            "fullChoicePasses": sum(item["passed"] for item in full),
            "exactPassRate": sum(item["passed"] for item in full) / len(full) if full else None,
            "partialChecksDenominator": len(partial),
            "partialChecksPasses": sum(item["passed"] for item in partial),
            "pendingSelection": bool(case["expected"].get("partial")),
            "scheduled": len(records),
            "infrastructureFailures": sum("infrastructureError" in item for item in records),
            "behavioralDenominator": len(behavioral),
            "deterministicPasses": sum(item["passed"] for item in behavioral),
            "selectionDistribution": dict(Counter(encode(item["selection"]).strip() for item in behavioral)),
            "pendingAssertions": case["expected"].get("pendingAssertions", ["selection fallback"] if case["expected"].get("partial") else []),
            "partial": bool(case["expected"].get("partial")),
            "prose": "pending; excluded from acceptance rate",
        }
    summary = {
        "mode": "grade-existing" if manifest else "render-only",
        "endedAt": utc(),
        "cases": per_case,
        "trials": results,
        "acceptanceRate": None,
        "acceptanceStatus": "pending prose judgment and policy approvals",
    }
    write_json(out / "summary.json", summary)
    lines = ["# Routing evaluation", "", "Prose judgment and pending policy assertions are excluded from acceptance. No authenticated calls were made.", "", "| Case | Deterministic passes / behavioral trials | Infrastructure failures | Pending assertions |", "| --- | --- | --- | --- |"]
    for cid, item in per_case.items():
        pending = str(item["pendingAssertions"]).replace("|", "\\|")
        lines.append(f"| {cid} | {item['deterministicPasses']} / {item['behavioralDenominator']} | {item['infrastructureFailures']} | {pending} |")
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"Saved {len(results)} trial artifacts to {out}")
    return int(any(item.get("infrastructureError") or item.get("passed") is False for item in results))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
