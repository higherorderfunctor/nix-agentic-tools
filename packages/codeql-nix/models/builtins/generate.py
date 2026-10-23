"""Project the runtime export inventory and pinned C++ registration AST into models."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from tree_sitter import Language, Parser
import tree_sitter_cpp


def walk(node):
    yield node
    for child in node.named_children:
        yield from walk(child)


def string(node):
    if node.type == "string_literal":
        return json.loads(node.text)
    if node.type == "raw_string_literal":
        return next(child.text.decode() for child in node.named_children if child.type == "raw_string_content")
    raise ValueError("unsupported registration string")


def fields(node):
    return {child.child_by_field_name("designator").text.decode().removeprefix("."):
            child.child_by_field_name("value") for child in node.named_children
            if child.type == "initializer_pair"}


def registrations(source):
    parser = Parser(Language(tree_sitter_cpp.language()))
    result = {}
    for path in sorted((source / "src/libexpr").rglob("*.cc")):
        tree = parser.parse(path.read_bytes())
        for node in walk(tree.root_node):
            metadata = None
            if node.type == "declaration" and node.child_by_field_name("type") is not None and node.child_by_field_name("type").text == b"RegisterPrimOp":
                initializer = node.child_by_field_name("declarator").child_by_field_name("value")
                if initializer is not None and initializer.named_children:
                    metadata = initializer.named_children[0]
            elif node.type == "call_expression" and node.child_by_field_name("function").text in (b"addConstant", b"addPrimOp"):
                arguments = node.child_by_field_name("arguments").named_children
                if arguments and arguments[0].type == "initializer_list":
                    metadata = arguments[0]
                elif len(arguments) == 3 and arguments[0].type == "string_literal":
                    metadata = arguments[2]
            if metadata is not None and metadata.type == "compound_literal_expression":
                metadata = metadata.child_by_field_name("value")
            if metadata is None or metadata.type != "initializer_list":
                continue
            values = fields(metadata)
            name = values.get("name")
            if name is None and node.type == "call_expression":
                name = arguments[0]
            if name is None or name.type != "string_literal":
                continue
            registered = string(name)
            parameters = values.get("args")
            parameters = ([string(child) for child in parameters.named_children]
                          if parameters is not None else None)
            documentation = values.get("doc")
            documentation = (string(documentation) if documentation is not None and
                             documentation.type in ("string_literal", "raw_string_literal") else None)
            entry = {"documentation": documentation,
                     "evidence": {"endLine": node.end_point.row + 1, "path": path.relative_to(source).as_posix(),
                                  "startLine": node.start_point.row + 1},
                     "parameters": parameters}
            exported = registered.removeprefix("__")
            if exported in result:
                raise ValueError("ambiguous registration: " + exported)
            result[exported] = entry
    if not result:
        raise ValueError("no registration ASTs")
    return result


def output(model, destination):
    destination.mkdir(parents=True, exist_ok=True)
    # JSON is the sole model representation; QL is a mechanical projection.
    asset = destination / "builtins.json"
    asset.write_text(json.dumps(model, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    model = json.loads(asset.read_text())
    quote = json.dumps
    clauses = []
    for record in model["builtins"]:
        for export in record["exports"]:
            clauses.append("namespace = " + quote(export["namespace"]) + " and name = " + quote(export["name"]) +
                           " and identity = " + quote(record["identity"]))
    facts = "/** Generated from builtins.json; regenerate with models/builtins/generate.py. */\n"
    facts += "predicate identity(string namespace, string name, string identity) {\n  " + "\n  or ".join(clauses) + "\n}\n"
    for predicate, value in (("runtimeIdentity", model["runtime"]["identity"]),
                             ("runtimeSourceHash", model["runtime"]["sourceHash"]),
                             ("modelFingerprint", model["modelVersion"])):
        facts += "\npredicate " + predicate + "(string value) { value = " + quote(value) + " }\n"
    (destination / "builtins.qll").write_text(facts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("nix", "source", "output"):
        parser.add_argument("--" + flag, required=True)
    args = parser.parse_args()

    policy = json.loads(Path(__file__).with_name("policy.json").read_text())
    options = [part for key, value in policy.items() for part in ("--option", key, value)]

    def nix(*arguments):
        with tempfile.TemporaryDirectory() as config:
            env = os.environ | {"NIX_CONF_DIR": config, "NIX_CONFIG": "", "NIX_PATH": "", "NIX_USER_CONF_FILES": ""}
            return subprocess.run([args.nix, "--store", "dummy://", *options, *arguments],
                                  env=env, stdout=subprocess.PIPE, text=True, check=True).stdout.strip()

    runtime = {"identity": nix("--version"), "sourceHash": nix("hash", "path", args.source)}
    metadata = registrations(Path(args.source))
    names = json.loads(nix("eval", "--json", "--expr", "builtins.attrNames builtins"))
    # A with sentinel fills only unbound names. Inspect types, never call exports.
    candidates = sorted({candidate for name in names for candidate in (name, "__" + name)})
    probe = "[ " + " ".join('(with { ' + name + ' = "nixql-unbound"; }; '
                              '(builtins.isString ' + name + ' && ' + name + ' == "nixql-unbound"))'
                              for name in candidates) + " ]"
    unbound = json.loads(nix("eval", "--json", "--expr", probe))
    globals = {name for name, missing in zip(candidates, unbound) if not missing}
    builtins = []
    for name in names:
        entry = metadata.get(name)
        exports = [{"name": name, "namespace": "builtins"}]
        exports = ([{"name": candidate, "namespace": ""} for candidate in sorted(globals & {name, "__" + name})]
                   + exports)
        builtins.append({"behavior": "opaque", "confidence": "source" if entry else "unknown",
                         "documentation": entry["documentation"] if entry else None,
                         "evidence": entry["evidence"] if entry else None, "exports": exports,
                         "identity": "builtin:" + hashlib.sha256(json.dumps([runtime, name], sort_keys=True).encode()).hexdigest(),
                         "parameters": entry["parameters"] if entry else None})
    model = {"builtins": builtins, "generatorVersion": "1", "policy": policy, "runtime": runtime}
    model["modelVersion"] = "sha256:" + hashlib.sha256(json.dumps(model, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    output(model, Path(args.output))


if __name__ == "__main__":
    main()
