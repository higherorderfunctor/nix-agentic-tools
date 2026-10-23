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
    ["nx_observations", [key("observation"), ids["request"], "pre-apply-metadata", "observed"]],
    ["nx_observation_options", [key("observation"), option]],
]
for ordinal in range(2):
    origin = key("origin", str(ordinal))
    observation = key("observation", str(ordinal))
    facts.extend([
        ["nx_definitions", [key("definition", str(ordinal)), option, ordinal, origin]],
        ["nx_origins", [origin, "synthetic-" + str(ordinal), "synthetic"]],
        ["nx_observations", [observation, ids["request"], "pre-apply-metadata", "observed"]],
        ["nx_observation_definitions", [observation, key("definition", str(ordinal))]],
    ])


def row(relation, index=0):
    return [args for table, args in facts if table == relation][index]


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
    row("nx_definitions")[3] = key("origin", "foreign")
elif mode == "detached-origin":
    facts.append(["nx_origins", [key("origin", "detached"), "forged", "source"]])
elif mode == "foreign-request":
    row("nx_request_results")[0] = key("request", "foreign")
elif mode == "foreign-target":
    facts.append(["nx_target_inputs", [key("target", "foreign"), key("file"), "root"]])
elif mode == "foreign-context":
    row("nx_options")[1] = key("context", "foreign")
elif mode == "no-witness":
    row("nx_observations")[-1] = "unforced"
elif mode in ("missing-option-link", "missing-definition-link"):
    relation = "nx_observation_options" if mode == "missing-option-link" else "nx_observation_definitions"
    facts.remove(next(item for item in facts if item[0] == relation))
elif mode == "missing-definition-observation":
    observation = row("nx_observation_definitions")[0]
    facts = [item for item in facts if not (item[0] in ("nx_observations", "nx_observation_definitions") and item[1][0] == observation)]
elif mode in ("foreign-option-link", "foreign-definition-link", "foreign-observation-link"):
    relation = "nx_observation_options" if mode == "foreign-option-link" else "nx_observation_definitions"
    index = 0 if mode == "foreign-observation-link" else 1
    kind = "observation" if index == 0 else "option" if relation == "nx_observation_options" else "definition"
    row(relation)[index] = key(kind, "foreign")
elif mode == "wrong-definition-sibling":
    row("nx_observation_definitions")[1] = row("nx_observation_definitions", 1)[1]
elif mode in ("duplicate-definition-observation", "duplicate-option-observation"):
    kind = "definition" if mode == "duplicate-definition-observation" else "option"
    subject = row("nx_definitions")[0] if kind == "definition" else option
    observation = key("observation", "extra")
    facts.extend([
        ["nx_observations", [observation, ids["request"], "pre-apply-metadata", "observed"]],
        ["nx_observation_" + kind + "s", [observation, subject]],
    ])
elif mode == "mixed-subject-links":
    facts.append(["nx_observation_definitions", [key("observation"), row("nx_definitions")[0]]])
elif mode == "duplicate-subject-link":
    facts.append(["nx_observation_definitions", list(row("nx_observation_definitions"))])
elif mode == "oversized":
    row("nx_origins")[1] = "x" * 1048577
elif mode == "timeout":
    time.sleep(30)
print(json.dumps({"protocolVersion": 1, "facts": facts}))
