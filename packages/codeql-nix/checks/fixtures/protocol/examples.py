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
            "fingerprint": {"evaluatorVersion": "eval-a", "libVersion": "lib-a", "modelVersion": "model-a", "policyHash": "policy-a", "sourceSnapshotHash": "snapshot-a"},
            "inputIdentities": {"nixpkgs": "locked:nixpkgs-a"},
            "observationModes": ["metadata"],
            "requests": [REQUEST],
            "reusable": True,
            "sourceRoots": [{"logicalName": "project", "path": "/work/project", "rootContentIdentity": "snapshot-a"}],
            "syntaxOnlyFallback": True,
            "system": "x86_64-linux",
        }
    },
}

I = {name: f"nixql:v1:{name}:1:x" for name in ("context", "diagnostic", "member", "observation", "request", "run", "target", "value")}
BASE = [
    ["nx_runs", [I["run"], "schema", "extractor", "grammar", "model", "snapshot-a"]],
    ["nx_targets", [I["target"], I["run"], "host.workstation", "evalModules", "x86_64-linux", "eval-a", "lib-a", "inputs-a", "policy-a", "complete"]],
    ["nx_contexts", [I["context"], I["target"], "root", "[]"]],
    ["nx_requests", [I["request"], I["target"], I["context"], "config", '["a.b"]', "value", 3, 20, 4096, 5, 64]],
]


def result(state="complete", reason="", observation=None):
    facts = deepcopy(BASE)
    facts.append(["nx_request_results", [I["request"], state, reason, 0]])
    if observation is not None:
        facts.append(["nx_observations", [I["observation"], I["request"], "config-path", '["a.b"]', "applied-config", observation]])
    return {"protocolVersion": 1, "facts": facts}


def scalar(kind, encoding, payload):
    packet = result(observation="observed")
    packet["facts"][-2][1][-1] = 1
    packet["facts"].extend([
        ["nx_observation_values", [I["observation"], I["value"]]],
        ["nx_values", [I["value"], kind, "complete"]],
        ["nx_scalar_values", [I["value"], encoding, payload]],
    ])
    return packet


# The key is known, but a failed leaf has no successful value link.
PARTIAL = result("partial", "selected-leaf-failed", "observed")
PARTIAL["facts"].extend([
    ["nx_observation_values", [I["observation"], I["value"]]],
    ["nx_values", [I["value"], "attrset", "partial"]],
    ["nx_value_members", [I["member"], I["value"], "attribute", "bad", 0]],
    ["nx_observations", ["nixql:v1:observation:1:y", I["request"], "member", I["member"], "applied-config", "failed"]],
])

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
