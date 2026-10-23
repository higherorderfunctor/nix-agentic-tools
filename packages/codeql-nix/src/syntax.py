"""Authenticate source transactions and publish the kit's raw syntax plus anchors."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def load_abi(path):
    spec = importlib.util.spec_from_file_location("nixql_abi", path)
    abi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(abi)
    return abi


def quote(value):
    return '"' + value.replace('"', '""') + '"'


def part(value):
    # This private index framing is distinct from F1's durable identity framing.
    return str(value).replace("%", "%25").replace("|", "%7C")


def metadata(prefix, identity, value, abi, suffix=None):
    key = "nixql.s2." + prefix + "|" + "|".join(map(part, identity))
    if suffix is not None:
        key += "|" + part(suffix)
    return f"databaseMetadata({quote(abi.text(key))}, {quote(abi.text(value))})\n"


def trap_facts(abi, facts, offset=0):
    labels = {}
    for relation, args in facts:
        for (_, kind), value in zip(abi.COLUMNS[relation], args):
            if kind not in ("text", "int", "bool"):
                labels.setdefault(value, offset + len(labels) + 1)
    lines = [f"#{number}=@{quote(key)}\n" for key, number in labels.items()]
    for relation, args in facts:
        values = [quote(value) if kind == "text" else str(value) if kind in ("int", "bool") else f"#{labels[value]}"
                  for (_, kind), value in zip(abi.COLUMNS[relation], args)]
        lines.append(f"{relation}({', '.join(values)})\n")
    return "".join(lines)


def next_label(raw):
    # TRAP has no reader in the pinned kit. Strip its doubled-quote strings
    # before finding local labels, so source text can never collide with IDs.
    unquoted = re.sub(r'"(?:""|[^"])*"', '""', raw)
    return max(map(int, re.findall(r"#([0-9]+)", unquoted)), default=0)


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_name(path.name + ".pending")
    pending.write_bytes(data)
    pending.replace(path)


def main():
    binary, schema, combined_schema, pins_path, manifest_path, output_path = sys.argv[1:]
    abi = load_abi(Path(schema) / "abi.py")
    manifest = json.loads(Path(manifest_path).read_text())
    output = Path(output_path)
    output.mkdir(parents=True, exist_ok=True)
    trap = Path(os.environ.get("CODEQL_EXTRACTOR_NIX_TRAP_DIR", output / "trap"))
    archive = Path(os.environ.get("CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR", output / "archive"))
    trap.mkdir(parents=True, exist_ok=True)
    facts = []
    status_facts = []
    seen = set()
    failed = False
    schema_hash = hashlib.sha256(Path(combined_schema).read_bytes()).hexdigest()
    extractor_hash = hashlib.sha256(Path(binary).read_bytes() + Path(__file__).read_bytes()).hexdigest()
    snapshot = sorted((root["logicalName"], root["rootContentIdentity"],
                       sorted((entry["path"], entry["contentHash"]) for entry in root["files"]))
                      for root in manifest["roots"])
    snapshot_hash = hashlib.sha256(abi.canonical(snapshot).encode()).hexdigest()
    run = abi.key("run", [schema_hash, extractor_hash, snapshot_hash])
    run_row = ["nx_runs", [run, schema_hash, extractor_hash, json.loads(Path(pins_path).read_text())["grammar"], "not-requested", snapshot_hash]]
    for root in manifest["roots"]:
        root_key = abi.key("root", [root["logicalName"], root["rootContentIdentity"]])
        for entry in root["files"]:
            file = None
            file_row = None
            try:
                relative = abi.text(entry["path"])
                abi.require(relative and not Path(relative).is_absolute() and ".." not in relative.split("/"), "root-escaping source path")
                identity = [abi.text(root_key), relative, abi.text(entry["contentHash"])]
                file = abi.key("file", identity)
                candidate = ["nx_files", [file, *identity, abi.text(root["sourceKind"])]]
                abi.validate([candidate])
                file_row = candidate
                if file in seen:
                    continue
                root_path = Path(root["path"]).resolve(strict=True)
                source_path = (root_path / relative).resolve(strict=True)
                abi.require(source_path.is_relative_to(root_path), "source root escape")
                source = source_path.read_bytes()
                abi.require(hashlib.sha256(source).hexdigest() == entry["contentHash"], "source-snapshot-race")
                with tempfile.TemporaryDirectory(prefix=".syntax-", dir=output) as temporary:
                    private = Path(temporary)
                    snapshot = private / "snapshot"
                    snapshot.write_bytes(source)
                    result = subprocess.run([binary, str(snapshot), str(source_path), str(private / "raw.trap"), str(private / "index")], capture_output=True)
                    abi.require(result.returncode == 0, "text-field-too-large" if b"text-field-too-large" in result.stderr else "syntax-extraction-failed")
                    rows = (private / "index").read_text().splitlines()
                    state, errors = rows[0].split("\t")
                    transaction = [file_row, ["nx_syntax_results", [file, state, int(errors)]]]
                    index_rows = [metadata("file", identity, part(str(source_path)) + "|" + str(len(source)), abi)]
                    line_starts = [0] + [i + 1 for i, byte in enumerate(source) if byte == 10]
                    index_rows.extend(metadata("line", identity, f"{line}|{offset}", abi)
                                      for line, offset in enumerate(line_starts, 1))
                    for line in rows[1:]:
                        start, end, kind, child, raw_child, mapped = line.split("\t")
                        anchor = [int(start), int(end), kind, child]
                        key = abi.key("anchor", [file, start, end, kind, child])
                        transaction.append(["nx_anchors", [key, file, *anchor]])
                        if mapped == "1":
                            index_rows.append(metadata("path", identity, raw_child, abi, child))
                    abi.validate(transaction)
                    # Compare again after parsing. The archive and raw writer both used
                    # snapshot bytes; a changing checkout must not silently be admitted.
                    abi.require((root_path / relative).resolve(strict=True) == source_path and source_path.read_bytes() == source, "source-snapshot-race")
                    raw = (private / "raw.trap").read_bytes().decode("utf-8")
                    completed = raw + "".join(index_rows) + trap_facts(abi, transaction, next_label(raw))
                    atomic(archive / str(source_path).lstrip("/"), source)
                    transaction_name = hashlib.sha256(file.encode()).hexdigest()
                    atomic(trap / f"syntax-{transaction_name}.trap", completed.encode())
                    facts.extend(transaction)
                    seen.add(file)
            except (OSError, ValueError, UnicodeError) as error:
                failed = True
                code = "text-field-too-large" if "text-field-too-large" in str(error) else "source-snapshot-race" if "source-snapshot" in str(error) else "syntax-extraction-failed"
                if file_row is not None and file not in seen:
                    refusal = [file_row, ["nx_syntax_results", [file, "failed", 0]]]
                    facts.extend(refusal)
                    status_facts.extend(refusal)
                    seen.add(file)
                diagnostic = abi.key("diagnostic", [run, str(len(facts))])
                diagnostic_row = ["nx_diagnostics", [diagnostic, run, code, code]]
                facts.append(diagnostic_row)
                status_facts.append(diagnostic_row)
    enclosing = [run_row, ["nx_phases", [run, "syntax", "failed" if failed else "complete", "file-refusal" if failed else "all-selected-files"]]]
    facts.extend(enclosing)
    status_facts.extend(enclosing)
    abi.validate(facts)
    atomic(trap / f"identities-{snapshot_hash}.trap", trap_facts(abi, status_facts).encode())
    atomic(output / "facts.json", (abi.canonical({"protocolVersion": 1, "facts": facts}) + "\n").encode())
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
