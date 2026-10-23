"""Contract-only facts and raw nodes; no evaluator or syntax producer is invoked."""
# cspell:ignore attrpath

import importlib.util
from pathlib import Path
import sys


def key(kind, *parts):
    return f"nixql:v1:{kind}:" + "".join(f"{len(p.encode())}:{p}" for p in parts)


def emit(destination, abi_path):
    spec = importlib.util.spec_from_file_location("abi", abi_path)
    abi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(abi)
    rows, raw = [], []
    def add(table, *args):
        rows.append(["nx_" + table, list(args)])
    def observe(kind, subject, request, state, *identity):
        observation = key("observation", *identity)
        add("observations", observation, request, "pre-apply-metadata", state)
        add("observation_" + kind + "s", observation, subject)
    run, root = key("run", "metadata"), key("root", "fixture", "v1")
    add("runs", run, "schema", "extractor", "grammar", "not-requested", "snapshot")
    files = {name: key("file", root, name + ".nix", "fixture") for name in ("shared", "unique")}
    for name, file in files.items():
        add("files", file, root, name + ".nix", "fixture", "project")
        add("syntax_results", file, "complete", 0)
    for name in ("alpha", "beta"):
        target, context = key("target", name), key("context", name)
        add("targets", target, run, name, "evalModules", "x86_64-linux", "eval", "lib", "inputs", "policy", "complete")
        add("contexts", context, target, "root", "[]")
        add("target_inputs", target, files["shared" if name == "alpha" else "unique"], "root")
    # Two targets share an exact path, and one target has a different quoted-dot path.
    cases = [
        ("alpha", "answer", '["demo","answer"]', "complete", "observed", "-9223372036854775808", ["first", "second"]),
        ("beta", "answer", '["demo","answer"]', "complete", "observed", "9223372036854775807", ["only"]),
        ("alpha", "dot", '["demo.answer"]', "complete", "observed", "-1", ["dot", "synthetic"]),
        ("alpha", "failed", '["failed"]', "failed", "failed", None, ["failed"]),
        ("alpha", "missing", '["missing"]', None, None, None, ["missing"]),
        ("alpha", "partial", '["partial"]', "partial", "observed", None, []),
        # Request paths do not establish subject identity, even for complete work.
        ("alpha", "redirect", '["observed","subject"]', "complete", "observed", None, []),
        # Complete work and sibling metadata do not observe every definition.
        ("alpha", "sparse", '["sparse"]', "complete", "observed", "0", ["retained", "unobserved"]),
    ]
    for name, suffix, path, state, observed, priority, definitions in cases:
        option, request = key("option", name, suffix), key("request", name, suffix)
        add("options", option, key("context", name), path)
        request_path = '["requested","prefix"]' if suffix == "redirect" else path
        add("requests", request, key("target", name), key("context", name), "option-metadata", request_path, "priority" if priority is not None else "isDefined", 0, 10, 1048576, 5, 64)
        if state:
            add("request_results", request, state, "timeout" if state == "failed" else "", len(definitions) + 1)
            observe("option", option, request, observed, name, suffix)
        if priority is not None:
            add("option_metadata", option, "isDefined", "true")
            add("option_priority", option, priority)
        for ordinal, label in enumerate(definitions):
            origin, definition = key("origin", label), key("definition", label)
            add("origins", origin, label, "synthetic" if label == "synthetic" else "source")
            add("definitions", definition, option, ordinal, origin)
            if state == "complete" and label != "unobserved":
                observe("definition", definition, request, "observed", label)
            if label in ("first", "second", "only", "dot", "retained", "unobserved"):
                add("origin_files", origin, files["unique" if label == "only" else "shared"])
        if suffix == "dot":
            # Source identity is optional even when the option was observed.
            origin = key("origin", "unknown-declaration")
            add("origins", origin, "synthetic-declaration", "synthetic")
            add("option_declarations", option, 0, origin)
        if suffix == "answer":
            origin = key("origin", "declaration-" + name)
            add("origins", origin, "declaration-" + name, "source")
            add("origin_files", origin, files["shared" if name == "alpha" else "unique"])
            add("origin_positions", origin, 7, 13, "utf8-byte-1-based")
            add("option_declarations", option, 0, origin)
            declaration = key("request", name, "declaration")
            add("requests", declaration, key("target", name), key("context", name), "option-metadata", path, "declarations", 0, 10, 1048576, 5, 64)
            add("request_results", declaration, "complete", "", 1)
            observe("option", option, declaration, "observed", name, "declaration")
    abi.validate(rows)
    labels = sorted({value for table, args in rows for (_, kind), value in zip(abi.COLUMNS[table], args) if kind in abi.CONTRACT["entities"]})
    ids = {label: f"#{index}" for index, label in enumerate(labels, 1)}
    quote = lambda value: '"' + value.replace('"', '""') + '"'
    lines = [f"{local}=@{quote(label)}" for label, local in ids.items()]
    for table, args in rows:
        fields = [ids[value] if kind in abi.CONTRACT["entities"] else quote(value) if kind == "text" else str(value) for (_, kind), value in zip(abi.COLUMNS[table], args)]
        lines.append(f"{table}({','.join(fields)})")
    # Handwritten A0 graph for demo.answer=1; repeated twice only in shared.nix.
    for file_index, name in enumerate(files):
        identity = "|".join((root, name + ".nix", "fixture"))
        raw.append(f'#{1000 + file_index}=*')
        raw.append(f'files(#{1000 + file_index},"/fixture/{name}.nix")')
        raw.append(f'databaseMetadata({quote("nixql.s2.file|" + identity)},"/fixture/{name}.nix|30")')
        for row in range(2 if name == "shared" else 1):
            base, start = 2000 + file_index * 100 + row * 10, row * 15
            raw.append(f'databaseMetadata({quote("nixql.s2.line|" + identity)},"{row + 1}|{start}")')
            raw.extend(f'#{base + offset}=*' for offset in range(5))
            raw.extend([f'nix_binding_def(#{base},#{base+1},#{base+4})', f'nix_attrpath_def(#{base+1})', f'nix_attrpath_attr(#{base+1},0,#{base+2})', f'nix_attrpath_attr(#{base+1},1,#{base+3})', f'nix_tokeninfo(#{base+2},6,"demo")', f'nix_tokeninfo(#{base+3},6,"answer")', f'nix_tokeninfo(#{base+4},7,"1")', f'nix_ast_node_parent(#{base+4},#{base},1)'])
            for offset, begin, end, kind, child in ((0, start, start+14, "binding", "[]"), (4, start+12, start+13, "integer_expression", "[1]")):
                raw.append(f'#{base + offset + 5000}=*')
                anchor = key("anchor", files[name], str(begin), str(end), kind, child)
                raw.extend([f'#{base+5+offset}=@{quote(anchor)}', f'nx_anchors(#{base+5+offset},{ids[files[name]]},{begin},{end},{quote(kind)},{quote(child)})', f'locations_default(#{base+offset+5000},#{1000+file_index},{row+1},{begin-start+1},{row+1},{end-start})', f'nix_ast_node_location(#{base+offset},#{base+offset+5000})', f'databaseMetadata({quote("nixql.s2.path|" + identity + "|" + child)},{quote(child)})'])
    Path(destination).write_text("\n".join(lines + raw) + "\n")
    print(f"L0 handwritten fixture: {len(rows)} ABI-validated metadata rows; typed subjects, mismatched request path, one observed sibling; three source candidates", flush=True)


if __name__ == "__main__":
    emit(sys.argv[1], sys.argv[2])
