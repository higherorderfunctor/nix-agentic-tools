"""F2 fixtures transcribed from the design and F1, without protocol implementation."""

from copy import deepcopy
import importlib.util
from pathlib import Path

ABI_FIXTURE = Path(__file__).resolve().parents[1] / "abi/golden.py"
spec = importlib.util.spec_from_file_location("abi_golden", ABI_FIXTURE)
golden = importlib.util.module_from_spec(spec)
spec.loader.exec_module(golden)

BUDGETS = dict(maxBytes=4096, maxDepth=0, maxMemoryMiB=64, maxNodes=20, maxSeconds=5)
REQUEST = dict(domain="option-metadata", path=["services"], facet="declarations", **BUDGETS)
MANIFEST = {
    "manifestVersion": 1,
    "targets": {
        "host.workstation": {
            "adapter": "evalModules",
            "adapterVersion": "1",
            "argumentDescription": {"hash": "args-a", "moduleArgumentsRef": "module-args:a", "specialArgumentsRef": "special-args:a"},
            "evaluation": {"kind": "arguments", "reference": "arguments:a"},
            "fingerprint": {"evaluatorVersion": "eval-a", "libVersion": "lib-a", "modelVersion": "not-requested", "policyHash": "policy-a", "sourceSnapshotHash": "snapshot-a"},
            "inputIdentities": {"nixpkgs": "locked:nixpkgs-a"},
            "observationModes": ["metadata"],
            "requests": [REQUEST],
            "sourceRoots": [{"logicalName": "project", "path": "/work/project", "rootContentIdentity": "snapshot-a"}],
            "syntaxOnlyFallback": True,
            "system": "x86_64-linux",
        }
    },
}

I = {name: f"nixql:v1:{name}:1:x" for name in ("context", "diagnostic", "observation", "option", "request", "run", "target")}
BASE = [
    ["nx_runs", [I["run"], "schema", "extractor", "grammar", "not-requested", "snapshot-a"]],
    ["nx_targets", [I["target"], I["run"], "host.workstation", "evalModules", "x86_64-linux", "eval-a", "lib-a", "inputs-a", "policy-a", "complete"]],
    ["nx_contexts", [I["context"], I["target"], "root", "[]"]],
    ["nx_requests", [I["request"], I["target"], I["context"], "option-metadata", '["a.b"]', "isDefined", 0, 20, 4096, 5, 64]],
]


def result(state="complete", reason="", observation=None):
    facts = deepcopy(BASE)
    facts.append(["nx_request_results", [I["request"], state, reason, 0]])
    if observation is not None:
        facts.extend([
            ["nx_options", [I["option"], I["context"], '["a.b"]']],
            ["nx_observations", [I["observation"], I["request"], "option", I["option"], "pre-apply-metadata", observation]],
        ])
    return {"protocolVersion": 1, "facts": facts}


# Failed metadata work records no successful observation.
PARTIAL = result("partial", "metadata-projection-failed", "failed")

REFUSAL = result("unsupported", "text-field-too-large")
REFUSAL["facts"].extend([
    ["nx_diagnostics", [I["diagnostic"], I["run"], "text-field-too-large", "projection rejected; exact field omitted"]],
    ["nx_diagnostic_requests", [I["diagnostic"], I["request"]]],
])
PRE_TARGET = {"protocolVersion": 1, "facts": [
    deepcopy(BASE[0]),
    ["nx_phases", [I["run"], "target-discovery", "failed", "invalid-manifest"]],
    ["nx_diagnostics", [I["diagnostic"], I["run"], "invalid-manifest", "no target admitted"]],
]}
