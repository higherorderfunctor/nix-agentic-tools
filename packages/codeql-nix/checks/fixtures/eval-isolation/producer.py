"""Trusted metadata producer: independently spells F1 rows, never imports production."""

# cspell:ignore unrequested

import json
from pathlib import Path
import sys
import time

job = json.load(sys.stdin)
ids = job["identities"]
mode = job["request"]["path"][0]


def key(namespace, suffix=""):
    part = ids["request"] + suffix
    return "nixql:v1:" + namespace + ":" + str(len(part.encode())) + ":" + part


def packet(count=1):
    option = key("option")
    facts = [
        ["nx_request_results", [ids["request"], "complete", "", count]],
        ["nx_observations", [key("observation"), ids["request"], "pre-apply-metadata", "observed"]],
        ["nx_options", [option, ids["context"], json.dumps(job["request"]["path"], ensure_ascii=False, separators=(",", ":"))]],
    ]
    facts.append(["nx_observation_options", [key("observation"), option]])
    if job["request"]["facet"] in ("isDefined", "priority"):
        facts.append(["nx_option_metadata", [option, "isDefined", "true"]])
    if job["request"]["facet"] == "priority":
        facts.append(["nx_option_priority", [option, "100"]])
    return {"protocolVersion": 1, "facts": facts}


if mode == "timeout":
    time.sleep(30)
elif mode == "memory":
    chunks = [bytearray(8 * 1024 * 1024) for _ in range(80)]
elif mode == "crash":
    print(json.dumps(packet()))
    print("fixture crash", file=sys.stderr)
    sys.exit(7)
elif mode == "malformed":
    print('{"protocolVersion":1,"facts":[')
    sys.exit(0)
elif mode == "large-stderr":
    print("x" * 1200000, file=sys.stderr)
    sys.exit(7)
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
if mode in ("large-fields", "oversized-field", "bytes"):
    for index in range(2):
        origin = key("origin", str(index))
        size = 1048577 if mode == "oversized-field" and index == 0 else 600000
        response["facts"].extend([
            ["nx_option_declarations", [key("option"), index, origin]],
            ["nx_origins", [origin, "x" * size, "synthetic"]],
        ])
elif mode == "result-only":
    response["facts"] = response["facts"][:1]
elif mode == "observation-without-metadata":
    response["facts"] = response["facts"][:4]
elif mode == "unobserved-metadata":
    response["facts"][1][1][-1] = "unforced"
elif mode == "invalid-abi":
    response["facts"][-1][1][-1] = "not-json"
elif mode == "forge":
    response["facts"].append(["nx_targets", [ids["target"], ids["run"], "forged", "evalModules", "x86_64-linux", "eval", "lib", "inputs", "policy", "complete"]])
elif mode == "foreign-request":
    response["facts"][0][1][0] = "nixql:v1:request:7:foreign"
elif mode == "foreign-observation":
    response["facts"][1][1][1] = "nixql:v1:request:7:foreign"
elif mode == "foreign-context":
    response["facts"][2][1][1] = "nixql:v1:context:7:foreign"
elif mode == "foreign-path":
    response["facts"][2][1][-1] = '["foreign"]'
elif mode == "foreign-origin":
    response["facts"].append(["nx_origins", [key("origin"), "foreign", "synthetic"]])
elif mode == "unrequested-metadata":
    response["facts"].append(["nx_option_declarations", [key("option"), 0, key("origin")]])
    response["facts"].append(["nx_origins", [key("origin"), "unrequested", "synthetic"]])
elif mode == "priority-without-witness":
    response["facts"] = [row for row in response["facts"] if row[0] != "nx_option_metadata"]
print(json.dumps(response, ensure_ascii=False))
