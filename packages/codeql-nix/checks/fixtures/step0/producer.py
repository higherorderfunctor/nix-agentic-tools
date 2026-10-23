"""Adversarial F1 definition packets, independent of producer implementation."""
# cspell:ignore execv

import json
import os
import sys
import time

job = json.load(sys.stdin)
if "moduleFixture" in job["moduleArguments"]:
    fixture = job["moduleArguments"]["moduleFixture"]
    projection = 'let ' + fixture["setup"] + ' in import ' + fixture["adapter"] + ' { inherit lib modules; moduleArguments = {}; specialArguments = {}; job = builtins.fromJSON ' + json.dumps(json.dumps(job)) + '; }'
    os.execv(fixture["nix"], [fixture["nix"], "--store", fixture["store"], "--extra-experimental-features", "nix-command", "eval", "--json", "--impure", "--expr", projection])
ids, request = job["identities"], job["request"]
mode = request["path"][0]


def key(kind, suffix=""):
    component = ids["request"] + suffix
    return f"nixql:v1:{kind}:{len(component.encode())}:{component}"


option = key("option")
facts = [
    ["nx_request_results", [ids["request"], "complete", "", 1]],
    ["nx_options", [option, ids["context"], json.dumps(request["path"], separators=(",", ":"))]],
    ["nx_observations", [key("observation"), ids["request"], "option", option, "pre-apply-metadata", "observed"]],
]
for ordinal in range(2):
    origin = key("origin", str(ordinal))
    facts.extend([
        ["nx_definitions", [key("definition", str(ordinal)), option, ordinal, origin]],
        ["nx_origins", [origin, "synthetic-" + str(ordinal), "synthetic"]],
    ])
if mode == "forged-source":
    relation = job["moduleArguments"]["forged"]
    file = job["moduleArguments"]["file"]
    forged = {"nx_files": file, "nx_origin_files": [key("origin", "0"), file[0]], "nx_target_inputs": [ids["target"], file[0], "root"]}
    facts.append([relation, forged[relation]])
elif mode in ("gap", "duplicate", "starts-one"):
    for relation, args in facts:
        if relation == "nx_definitions":
            args[2] = 0 if mode == "duplicate" else args[2] + (1 if mode == "starts-one" else args[2])
elif mode == "foreign-origin":
    facts[3][1][3] = key("origin", "foreign")
elif mode == "detached-origin":
    facts.append(["nx_origins", [key("origin", "detached"), "forged", "source"]])
elif mode == "foreign-request":
    facts[0][1][0] = key("request", "foreign")
elif mode == "foreign-target":
    facts.append(["nx_target_inputs", [key("target", "foreign"), key("file"), "root"]])
elif mode == "foreign-context":
    facts[1][1][1] = key("context", "foreign")
elif mode == "no-witness":
    facts[2][1][-1] = "unforced"
elif mode == "oversized":
    facts[4][1][1] = "x" * 1048577
elif mode == "timeout":
    time.sleep(30)
print(json.dumps({"protocolVersion": 1, "facts": facts}))
