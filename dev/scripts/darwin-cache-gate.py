#!/usr/bin/env python3
"""Check missing fixed outputs in Darwin CI and consumer build plans."""

import argparse
import json
import os
import platform
import re
import subprocess
import time
from pathlib import Path

STORE = "/nix/store/"
DRV = re.compile(r"/nix/store/[0-9a-z]{32}-[^\s]+\.drv")
BUILD_HEADER = re.compile(r"(?:this derivation|these (\d+) derivations) will be built:")


def planned_builds(log):
    """Read the 'will be built' block, never the following fetch block."""
    lines = iter(log.splitlines())
    builds = set()
    for line in lines:
        header = BUILD_HEADER.fullmatch(line)
        if header is None:
            if "will be built:" in line:
                raise ValueError(f"unexpected Nix dry-run header: {line}")
            continue
        if builds:
            raise ValueError("repeated Nix dry-run build block")
        for _ in range(int(header[1] or 1)):
            drv = next(lines, "").strip()
            if not DRV.fullmatch(drv) or drv in builds:
                raise ValueError(f"malformed Nix dry-run build block: {drv!r}")
            builds.add(drv)
    return builds


def required_outputs(roots, graph):
    """Find the outputs required by the existing Darwin build jobs."""
    pending = [(drv, tuple(graph[drv]["outputs"])) for drv in roots]
    reached = set()
    outputs = set()
    while pending:
        path, names = pending.pop()
        drv = graph[path]
        outputs.update((path, name) for name in names)
        if path not in reached:
            reached.add(path)
            pending.extend((STORE + dep, edge["outputs"]) for dep, edge in drv["inputs"]["drvs"].items())
    return outputs


def output_path(drv, name):
    # v4 encodes fixed outputs by hash, and carries their computed paths in env.
    path = drv["outputs"][name].get("path") or drv["env"].get(name)
    return STORE + path.removeprefix(STORE) if path else None


def classify(builds, graph, check_drvs, built_roots, built_graph):
    native_outputs = required_outputs(built_roots, built_graph)
    native_paths = {output_path(built_graph[drv], name) for drv, name in native_outputs} - {None}
    downloads, compilers = [], []
    for path in sorted(builds - check_drvs):
        drv = graph[path]
        attrs = drv.get("structuredAttrs") or {}
        if attrs.get("allowSubstitutes", drv["env"].get("allowSubstitutes")) in (False, "", "0", "false"):
            continue
        outputs = drv["outputs"]
        if all((path, name) in native_outputs or output_path(drv, name) in native_paths for name in outputs):
            continue
        # fetchurl sets preferLocalBuild; that is not a reason to exclude it.
        if all(output.get("hash") for output in outputs.values()):
            downloads.append(path)
        elif any(dep.endswith("-stdenv-darwin.drv") for dep in drv["inputs"]["drvs"]):
            compilers.append(path)
    return downloads, compilers


def capture_nix(*args, paths):
    return subprocess.run(
        ["nix", *args, "--stdin"], input="".join(f"{path}\n" for path in sorted(paths)),
        text=True, capture_output=True, check=True, env={**os.environ, "LC_ALL": "C"},
    )


def derivations(paths, *, recursive=False):
    if not paths:
        return {}
    args = ["derivation", "show"]
    if recursive:
        args.append("--recursive")
    data = json.loads(capture_nix(*args, paths=paths).stdout)
    if data["version"] != 4:
        raise ValueError(f"unsupported Nix derivation schema {data['version']}")
    return {STORE + path: drv for path, drv in data["derivations"].items()}


def build_plan(paths, options):
    result = capture_nix("build", "--dry-run", "--log-format", "raw", *options, paths=(f"{path}^*" for path in paths))
    return planned_builds(result.stderr)


def annotate(level, message):
    escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level}::{escaped}", flush=True)


def verify_downloads(downloads, graph, options):
    selected = set(downloads)
    if not selected:
        return
    # Replan just the downloads. The larger plan can contain unrelated builds;
    # do not let realization silently compile a tool needed by a fetcher.
    extra = build_plan(selected, options) - selected
    if extra:
        ready = []
        for path in downloads:
            prerequisites = build_plan({path}, options) - selected
            if prerequisites:
                annotate("warning", f"Cannot check fixed output {path} without building:\n" + "\n".join(sorted(prerequisites)))
            else:
                ready.append(path)
        selected = set(ready)
    if not selected:
        return
    for path in sorted(selected):
        drv = graph[path]
        attrs = drv.get("structuredAttrs") or drv["env"]
        urls = attrs.get("urls") or attrs.get("url") or "(not declared by builder)"
        expected = ", ".join(output["hash"] for output in drv["outputs"].values())
        print(f"Verifying {path}\n  URLs: {urls}\n  Expected: {expected}", flush=True)
    subprocess.run(
        ["nix", "build", "--keep-going", "--print-build-logs", *options, "--stdin"],
        input="".join(f"{path}^*\n" for path in sorted(selected)), text=True, check=True,
    )


def scan(checks, roots, *, built_checks, dry_run):
    if not (checks and roots["packages"] and roots["runtime"]):
        raise ValueError("Darwin cache gate requires nonempty check, package and consumer roots")
    check_drvs = set(checks.values())
    package_drvs = set(roots["packages"].values())
    built_roots = package_drvs | {checks[name] for name in built_checks}
    all_roots = check_drvs | package_drvs | set(roots["runtime"].values())
    if not all(DRV.fullmatch(path) for path in all_roots):
        raise ValueError("Darwin cache gate root is not a store derivation")
    cache = roots["cache"]
    options = [
        "--no-link",
        "--option", "substituters", " ".join(["https://cache.nixos.org", *cache["extra-substituters"]]),
        "--option", "extra-substituters", "",
        "--option", "extra-trusted-public-keys", " ".join(cache["extra-trusted-public-keys"]),
        "--option", "builders", "",
        # Unlike ordinary CI builds, this gate must not compile a dependency
        # locally when a substitute download fails.
        "--option", "fallback", "false",
    ]
    print(f"Darwin cache gate: {len(checks)} checks, {len(roots['packages'])} packages, {len(roots['runtime'])} consumer roots", flush=True)
    builds = build_plan(all_roots, options)
    # This fixture-only writeText output is never built by evaluation or CI.
    # Its absence on a fresh runner means we cannot trust the parsed plan.
    if roots["runtime"]["home-services"] not in builds:
        raise ValueError("Nix dry-run plan did not report the uncached home-services probe")
    graph = derivations(builds)
    downloads, compilers = classify(builds, graph, check_drvs, built_roots, derivations(built_roots, recursive=True))
    print(f"{len(builds)} planned builds; {len(downloads)} fixed outputs to verify, {len(compilers)} compiler builds to report", flush=True)
    if compilers:
        annotate("warning", "Uncached Darwin compiler builds (not built by this gate):\n" + "\n".join(compilers))
    for path in downloads:
        print(f"Fixed-output candidate: {path}", flush=True)
    if not dry_run:
        verify_downloads(downloads, graph, options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checks", type=Path, help="JSON object from the existing Darwin check evaluation")
    parser.add_argument("--built-checks", nargs="+", default=(), help="checks already built by another Darwin job")
    parser.add_argument("--dry-run", action="store_true", help="report candidate downloads without realizing them")
    parser.add_argument("--roots", type=Path, help="reuse an evaluated ciDarwinCacheGate JSON object")
    args = parser.parse_args()
    if not args.dry_run and (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        parser.error("realization requires an Apple Silicon runner")
    started = time.monotonic()
    try:
        roots = json.loads(args.roots.read_text()) if args.roots else json.loads(subprocess.check_output(
            ["nix", "eval", "--json", ".#.ciDarwinCacheGate"], text=True,
        ))
        scan(json.loads(args.checks.read_text()), roots, built_checks=args.built_checks, dry_run=args.dry_run)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, end="", flush=True)
        raise SystemExit(error.returncode) from error
    finally:
        elapsed = f"Darwin cache gate wall time: {time.monotonic() - started:.1f} s"
        print(elapsed, flush=True)
        if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(summary).open("a") as handle:
                print(f"\n{elapsed}", file=handle)


if __name__ == "__main__":
    main()
