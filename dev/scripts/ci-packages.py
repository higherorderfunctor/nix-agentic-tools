#!/usr/bin/env python3
"""Partition native package validation and reject incomplete build results."""

import argparse
import json
import re
from pathlib import Path


# Generated documents are checked by `test`. Patched Kiro has dedicated native
# jobs without cache uploads; it must never enter the public build cache.
EXCLUDED = {
    "instructions-agents",
    "instructions-claude",
    "instructions-copilot",
    "instructions-kiro",
    "kiro-cli-workflows",
    "repo-contributing",
    "repo-readme",
}


def partition(names, index, count):
    if not isinstance(names, list) or not names or len(names) != len(set(names)):
        raise ValueError("package enumeration must be a nonempty unique list")
    if any(not re.fullmatch(r"[a-zA-Z0-9_+-]+", name) for name in names):
        raise ValueError("unexpected package attribute name")
    if not 0 <= index < count:
        raise ValueError("invalid shard index/count")
    universe = sorted(set(names) - EXCLUDED)
    selected = universe[index::count]
    if not selected:
        raise ValueError("empty package shard")
    return {"count": count, "index": index, "packages": selected, "universe": universe}


def result_rows(results):
    if isinstance(results, dict):
        results = results.get("results")
    if not isinstance(results, list) or not results:
        raise ValueError("missing nix-fast-build results")
    if any(not isinstance(row, dict) for row in results):
        raise ValueError("malformed nix-fast-build result")
    return results


def validate_result_coverage(packages, results):
    if not isinstance(packages, list) or not packages or len(packages) != len(set(packages)):
        raise ValueError("expected package enumeration must be a nonempty unique list")
    results = result_rows(results)
    evaluations = [row for row in results if row.get("type") == "EVAL"]
    if any(not isinstance(row.get("attr"), str) or not isinstance(row.get("success"), bool) or row.get("skipped") for row in evaluations):
        raise ValueError("malformed nix-fast-build evaluation result")
    names = [row["attr"] for row in evaluations]
    if sorted(names) != sorted(packages):
        raise ValueError("evaluated package set differs from the expected package set")

    builds = [row for row in results if row.get("type") == "BUILD"]
    if any(not isinstance(row.get("attr"), str) for row in builds):
        raise ValueError("malformed nix-fast-build build result")
    built = {row["attr"] for row in builds}
    built_drvs = {row["drvPath"] for row in builds if row.get("drvPath")}
    # nix-fast-build may omit drvPath from BUILD rows. Recover it from the
    # corresponding EVAL row so aliases of the same derivation still count.
    built_drvs.update(
        row["drvPath"] for row in evaluations if row["attr"] in built and row.get("drvPath")
    )
    for row in evaluations:
        if row["success"] and row.get("cacheStatus") not in {"cached", "local"} and row["attr"] not in built and row.get("drvPath") not in built_drvs:
            raise ValueError(f"package was neither built nor cached: {row['attr']}")
    return results


def validate_results(plan, results):
    results = validate_result_coverage(plan["packages"], results)
    if any(row.get("success") is not True or row.get("skipped") or row.get("error") for row in results):
        raise ValueError("failed or skipped nix-fast-build result")


def validate_coverage(plans, count):
    if len(plans) != count or sorted(p["index"] for p in plans) != list(range(count)):
        raise ValueError("missing or duplicate shard receipts")
    universe = plans[0]["universe"]
    for plan in plans:
        expected = partition(universe, plan["index"], count)
        if plan != expected:
            raise ValueError("shards disagree on package enumeration or assignment")
    selected = [name for plan in plans for name in plan["packages"]]
    if sorted(selected) != universe:
        raise ValueError("package coverage is incomplete or duplicated")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("names", type=Path)
    plan.add_argument("index", type=int)
    plan.add_argument("count", type=int)
    plan.add_argument("output", type=Path)
    verify = sub.add_parser("verify")
    verify.add_argument("plan", type=Path)
    verify.add_argument("results", type=Path)
    update_verify = sub.add_parser("update-verify")
    update_verify.add_argument("packages", type=Path)
    update_verify.add_argument("results", type=Path)
    coverage = sub.add_parser("coverage")
    coverage.add_argument("directory", type=Path)
    coverage.add_argument("count", type=int)
    args = parser.parse_args()
    if args.command == "plan":
        data = partition(json.loads(args.names.read_text()), args.index, args.count)
        args.output.write_text(json.dumps(data, indent=2) + "\n")
        names = " ".join(json.dumps(name) for name in data["packages"])
        print(f"packages: builtins.listToAttrs (map (name: {{ inherit name; value = packages.${{name}}; }}) [ {names} ])")
    elif args.command == "verify":
        validate_results(json.loads(args.plan.read_text()), json.loads(args.results.read_text()))
    elif args.command == "update-verify":
        validate_result_coverage(json.loads(args.packages.read_text()), json.loads(args.results.read_text()))
    else:
        validate_coverage([json.loads(p.read_text()) for p in args.directory.glob("*/receipt.json")], args.count)


if __name__ == "__main__":
    main()
