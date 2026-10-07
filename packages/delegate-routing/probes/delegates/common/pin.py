"""Shared helpers for the delegate replay probes.

Every probe runs the package this repository pins, never whatever is on PATH.
`package(attr)` builds `.#ciPackages.<system>.<attr>` (or returns the store
path named by the matching override variable), `workdir(name)` returns the
scratch directory a probe writes into: `$PROBE_OUT` when set, otherwise a
fresh temporary directory.
"""

import os
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent

# attr -> environment variable that may name a prebuilt store path instead.
OVERRIDES = {
    "chatgpt-codex": "CODEX_PKG",
    "claude-code": "CLAUDE_PKG",
    "kimchi": "KIMCHI_PKG",
    "kimchi-workflows": "KIMCHI_WORKFLOWS_PKG",
    "kiro-cli.unwrapped": "KIRO_PKG",
}


def repo_root():
    return pathlib.Path(
        subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "--show-toplevel"], text=True).strip()
    )


def system():
    return subprocess.check_output(
        ["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"], text=True
    ).strip()


def package(attr):
    """Store path of the pinned package `attr` (built on demand)."""
    override = os.environ.get(OVERRIDES.get(attr, ""), "")
    if override:
        return pathlib.Path(override)
    ref = f"{repo_root()}#ciPackages.{system()}.{attr}"
    out = subprocess.check_output(["nix", "build", "--no-link", "--print-out-paths", ref], text=True)
    return pathlib.Path(out.split()[0])


def source(attr):
    """Store path of the pinned package's `src`."""
    ref = f"{repo_root()}#ciPackages.{system()}.{attr}.src"
    out = subprocess.check_output(["nix", "build", "--no-link", "--print-out-paths", ref], text=True)
    return pathlib.Path(out.split()[0])


def workdir(name):
    """Scratch directory for one probe run; never inside the repository."""
    base = os.environ.get("PROBE_OUT")
    if base:
        path = pathlib.Path(base) / name
        path.mkdir(parents=True, exist_ok=True)
        return path
    return pathlib.Path(tempfile.mkdtemp(prefix=f"delegate-probe-{name}-"))
