"""Trusted test producer: independently spells F1 rows, never imports production."""

import json
from pathlib import Path
import sys
import time

job = json.load(sys.stdin)
ids = job["identities"]
mode = job["request"]["path"][0]
value = "nixql:v1:value:7:fixture" + str(len(ids["request"].encode())) + ":" + ids["request"]
observation = "nixql:v1:observation:" + str(len(ids["request"].encode())) + ":" + ids["request"]


def packet(payload="true", count=1):
    return {"protocolVersion": 1, "facts": [
        ["nx_request_results", [ids["request"], "complete", "", count]],
        ["nx_observations", [observation, ids["request"], "config-path", json.dumps(job["request"]["path"], ensure_ascii=False, separators=(",", ":")), "applied-config", "observed"]],
        ["nx_observation_values", [observation, value]],
        ["nx_values", [value, "boolean", "complete"]],
        ["nx_scalar_values", [value, "boolean-json-v1", payload]],
    ]}


def graph(adjacency, payload=None):
    """Independent wire fixture; adjacency indexes identify shared values."""
    response = packet(count=len(adjacency))
    response["facts"] = response["facts"][:3]
    values = [value + str(len(str(index))) + ":" + str(index) for index in range(len(adjacency))]
    response["facts"][2][1][1] = values[0]
    for index, children in enumerate(adjacency):
        kind = "string" if payload is not None and not children else "attrset"
        response["facts"].append(["nx_values", [values[index], kind, "complete"]])
        if kind == "string":
            response["facts"].append(["nx_scalar_values", [values[index], "string-json-v1", json.dumps(payload)]])
        for ordinal, child in enumerate(children):
            member = "nixql:v1:member:" + str(len(ids["request"].encode())) + ":" + ids["request"] + str(len(str(index))) + ":" + str(index) + "1:" + str(ordinal)
            obs = observation + str(len(str(index))) + ":" + str(index) + "1:" + str(ordinal)
            response["facts"].extend([
                ["nx_value_members", [member, values[index], "attribute", str(ordinal), ordinal]],
                ["nx_member_values", [member, values[child]]],
                ["nx_observations", [obs, ids["request"], "member", member, "applied-config", "observed"]],
                ["nx_observation_values", [obs, values[child]]],
            ])
    return response


if mode == "timeout":
    time.sleep(30)
elif mode == "memory":
    # A controlled address-space refusal has a deterministic allocation demand.
    chunks = [bytearray(8 * 1024 * 1024) for _ in range(80)]
elif mode == "crash":
    print(json.dumps(packet()))
    print("fixture crash", file=sys.stderr)
    sys.exit(7)
elif mode == "malformed":
    print('{"protocolVersion":1,"facts":[')
    sys.exit(0)
elif mode == "bytes":
    response = packet()
    response["facts"][-2][1][1] = "string"
    response["facts"][-1][1][1:] = ["string-json-v1", json.dumps("x" * 131072)]
    print(json.dumps(response))
    sys.exit(0)
elif mode == "large-fields" or mode == "oversized-field":
    response = graph([[1, 2], [], []], "x" * 600000)
    if mode == "oversized-field":
        next(args for relation, args in response["facts"] if relation == "nx_scalar_values")[-1] = json.dumps("x" * 1048576)
    print(json.dumps(response))
    sys.exit(0)
elif mode == "large-stderr":
    print("x" * 1200000, file=sys.stderr)
    sys.exit(7)
elif mode in ("shared-dag", "cycle", "unequal-depth"):
    adjacency = ([[index + 1, index + 1] for index in range(25)] + [[]]
                 if mode == "shared-dag" else [[1], [0]] if mode == "cycle"
                 else [[3, 1], [2], [3], []])
    print(json.dumps(graph(adjacency)))
    sys.exit(0)
elif mode == "trace":
    print("é" * 1048577, file=sys.stderr)
    sys.exit(7)
elif mode == "binding":
    assert job["moduleArguments"] == {"sentinel": "module"}
    assert job["specialArguments"] == {"sentinel": "special"}
    assert job["target"]["system"] == "x86_64-linux"
elif mode == "serial":
    log = Path(job["moduleArguments"]["log"])
    with log.open("a") as stream:
        stream.write("start\n")
    time.sleep(0.08)
    with log.open("a") as stream:
        stream.write("end\n")
response = packet(count=3 if mode == "nodes" else 1)
if mode in ("result-only", "observation-without-value"):
    response["facts"] = response["facts"][:1 if mode == "result-only" else 2]
    response["facts"][0][1][-1] = 0
elif mode in ("opaque-function", "empty-attrset", "empty-list"):
    kind = {"opaque-function": "function", "empty-attrset": "attrset", "empty-list": "list"}[mode]
    response["facts"][-2][1][1:] = [kind, "opaque" if kind == "function" else "complete"]
    response["facts"].pop()
elif mode == "explicit-null":
    response["facts"][-2][1][1] = "null"
    response["facts"][-1][1][1:] = ["null-json-v1", "null"]
elif mode == "invalid-abi":
    response["facts"][-1][1][-1] = "not-a-boolean"
elif mode == "forge":
    response["facts"].append(["nx_targets", [ids["target"], ids["run"], "forged", "evalModules", "x86_64-linux", "eval", "lib", "inputs", "policy", "complete"]])
elif mode == "foreign-request":
    response["facts"][0][1][0] = "nixql:v1:request:7:foreign"
elif mode == "string-context-output":
    response["facts"][-2][1][1] = "string"
    response["facts"][-1][1][1:] = ["string-json-v1", '"secret"']
    response["facts"].append(["nx_string_context", [value, "/nix/store/fixture", "opaque", ""]])
elif mode == "depth":
    response["facts"][-2] = ["nx_values", [value, "attrset", "complete"]]
    response["facts"].pop()
    member = "nixql:v1:member:1:m"
    child = "nixql:v1:value:1:c"
    child_observation = "nixql:v1:observation:1:c"
    response["facts"].extend([
        ["nx_value_members", [member, value, "attribute", "child", 0]],
        ["nx_member_values", [member, child]],
        ["nx_observations", [child_observation, ids["request"], "member", member, "applied-config", "observed"]],
        ["nx_observation_values", [child_observation, child]],
        ["nx_values", [child, "boolean", "complete"]],
        ["nx_scalar_values", [child, "boolean-json-v1", "true"]],
    ])
print(json.dumps(response, ensure_ascii=False))
