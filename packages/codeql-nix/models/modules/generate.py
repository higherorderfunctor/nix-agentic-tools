"""Generate the exact-library helper model and shared builtin/module bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def fingerprint(value):
    return "sha256:" + hashlib.sha256(canonical(value).encode()).hexdigest()


def source_bindings(parser, source):
    """Use S2's concrete AST index, accepting only the outer module let frame."""
    data = source.read_bytes()
    with tempfile.TemporaryDirectory(prefix="nixql-module-model-") as temporary:
        directory = Path(temporary)
        subprocess.run([parser, str(source), str(source), str(directory / "raw.trap"),
                        str(directory / "index")], check=True)
        rows = [line.split("\t") for line in (directory / "index").read_text().splitlines()[1:]]
    nodes = {tuple(json.loads(row[3])): (int(row[0]), int(row[1]), row[2]) for row in rows}
    bindings = {}
    for path, (start, end, kind) in nodes.items():
        if kind != "binding" or nodes[path[:-1]][2] != "binding_set":
            continue
        frame = path[:-2]
        if len(frame) != 2 or nodes[frame][2] != "let_expression" or nodes[frame[:-1]][2] != "function_expression":
            continue
        name = nodes.get(path + (0, 0))
        if name is None or name[2] != "identifier" or path + (0, 1) in nodes:
            continue
        text = data[name[0]:name[1]].decode()
        if text in bindings:
            raise ValueError("ambiguous module model binding")
        line = data[:start].count(b"\n") + 1
        bindings[text] = {"column": start - (data.rfind(b"\n", 0, start) + 1) + 1,
                          "file": str(source), "line": line}
    return bindings


def generate(nix, library, builtins_model, output, anchors):
    source = Path(library).resolve()
    environment = os.environ | {"NIX_CONFIG": "", "NIX_CONF_DIR": "/nixql/no-config", "NIX_PATH": "", "NIX_USER_CONF_FILES": ""}
    command = [nix, "--store", "dummy://", "--extra-experimental-features", "nix-command"]
    lib_hash = subprocess.check_output(command + ["hash", "path", str(source)], text=True, env=environment).strip()
    expression = "import " + str(Path(__file__).with_name("properties.nix")) + " { lib = import " + json.dumps(str(source / "lib")) + "; }"
    model = json.loads(subprocess.check_output(command + ["eval", "--json", "--impure", "--expr", expression], text=True, env=environment))
    model.update(generatorVersion="1", libHash=lib_hash)
    bindings = source_bindings(anchors, source / "lib/modules.nix")
    model["constantEvidence"]["ordinaryOverridePriority"] = [bindings["defaultOverridePriority"]]
    for helper in model["helpers"]:
        helper["evidence"].append(dict(bindings[helper["name"]]))
        helper["exportIdentity"] = "module-helper:" + fingerprint([lib_hash, helper["name"]])
        helper["argumentSpecJson"] = canonical({"arity": helper["arity"], "content": helper["arity"] - 1})
    evidence_rows = [evidence for records in model["constantEvidence"].values() for evidence in records] + [evidence for helper in model["helpers"] for evidence in helper["evidence"]]
    for evidence in evidence_rows:
        if evidence is None:
            raise ValueError("helper lacks source export/binding evidence")
        path = Path(evidence["file"])
        evidence["file"] = path.relative_to(source).as_posix()
        evidence["lineText"] = path.read_text().splitlines()[evidence["line"] - 1]
    model["modelVersion"] = fingerprint(model)
    builtin_version = json.loads(Path(builtins_model).read_text())["modelVersion"]
    model["bundleHash"] = fingerprint({"builtins": builtin_version, "modules": model["modelVersion"]})
    destination = Path(output)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "modules.json").write_text(json.dumps(model, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    quote = json.dumps
    clauses = ["exportIdentity = " + quote(h["exportIdentity"]) + " and kind = " + quote(h["kind"]) + " and argumentSpecJson = " + quote(h["argumentSpecJson"]) for h in model["helpers"]]
    facts = "/** Generated from modules.json; do not edit. */\n"
    facts += "predicate helper(string libHash, string modelHash, string exportIdentity, string kind, string argumentSpecJson) {\n libHash = " + quote(lib_hash) + " and modelHash = " + quote(model["bundleHash"]) + " and (\n " + "\n or ".join(clauses) + ")\n}\n"
    facts += "predicate exported(string name, string identity) {\n " + "\n or ".join("name = " + quote(h["name"]) + " and identity = " + quote(h["exportIdentity"]) for h in model["helpers"]) + "\n}\n"
    constants = model["constants"] | {h["name"]: h["priority"] for h in model["helpers"] if h["priority"] is not None}
    facts += "predicate constant(string name, string priority) {\n " + "\n or ".join("name = " + quote(name) + " and priority = " + quote(priority) for name, priority in sorted(constants.items())) + "\n}\n"
    for predicate, value in (("builtinFingerprint", builtin_version), ("bundleFingerprint", model["bundleHash"]), ("libraryFingerprint", lib_hash)):
        facts += "predicate " + predicate + "(string value) { value = " + quote(value) + " }\n"
    (destination / "modules.qll").write_text(facts)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("anchors", "nix", "library", "builtins", "output"):
        parser.add_argument("--" + flag, required=True)
    args = parser.parse_args()
    generate(args.nix, args.library, args.builtins, args.output, args.anchors)
