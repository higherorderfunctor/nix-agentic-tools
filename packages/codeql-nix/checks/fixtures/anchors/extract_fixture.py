"""Drive the real S2 producer and add independent adversarial QL facts."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def key(namespace, *parts):
    return "nixql:v1:" + namespace + ":" + "".join(
        f"{len(part.encode('utf-8'))}:{part}" for part in parts)


def quote(text):
    return '"' + text.replace('"', '""') + '"'


def absent_builtin_model(trap_dir, facts):
    runs = [args for relation, args in facts if relation == "nx_runs"]
    transformed = 0
    identities = 0
    for run, schema, extractor, grammar, model, snapshot in runs:
        replacement = key("run", schema, extractor, "not-requested", snapshot)
        columns = ", ".join(map(quote, [schema, extractor, grammar, model, snapshot]))
        absent = ", ".join(map(quote, [schema, extractor, grammar, "not-requested", snapshot]))
        row = re.compile(r"^(nx_runs\(#[0-9]+, )" + re.escape(columns) + r"(\))$", re.MULTILINE)
        for path in sorted(trap_dir.rglob("*.trap")):
            text, count = row.subn(lambda match: match[1] + absent + match[2], path.read_bytes().decode("utf-8"))
            transformed += count
            def replace_identity(match):
                nonlocal identities
                if match.group() == quote(run):
                    identities += 1
                    return quote(replacement)
                return match.group()
            text = re.sub(r'"(?:""|[^"])*"', replace_identity, text)
            path.write_bytes(text.encode("utf-8"))
    if not transformed or not identities:
        raise AssertionError("absent-model control has no completed run facts to transform")
    print(f"N2 absent builtin model: transformed {transformed} runs and {identities} run identities to not-requested", flush=True)


def duplicate_raw(trap_dir):
    count = 0
    for index, path in enumerate(sorted(trap_dir.rglob("*.trap"))):
        text = path.read_text()
        # Raw local labels are deliberately fresh. Global labels retain the
        # exact same key, preserving the authenticated file association.
        raw = "\n".join(line for line in text.splitlines() if not line.startswith("nx_")) + "\n"
        pattern = r'"(?:""|[^"])*"|#[0-9]+'
        def rename(match):
            token = match.group()
            return "#" + str(int(token[1:]) + 10000000) if token.startswith("#") else token
        duplicate = re.sub(pattern, rename, raw)
        (trap_dir / f"ambiguous-{index}.trap").write_text(duplicate)
        count += 1
    if not count:
        raise AssertionError("ambiguity control has no completed raw TRAP to duplicate")
    print(f"S2 ambiguity control: duplicated {count} raw transactions with fresh labels", flush=True)


def adversarial_anchors(trap_dir):
    root = key("root", "qltest", "s2-qltest-v1")
    digest = hashlib.sha256(b"41").hexdigest()
    file = key("file", root, "bridge.nix", digest)
    fake_digest = hashlib.sha256(b"42").hexdigest()
    fake = key("file", root, "bridge.nix", fake_digest)
    rows = [
        (file, 0, 2, "identifier", "[0]"),
        (file, 0, 2, "integer_expression", "[7]"),
        (file, 1, 2, "integer_expression", "[0]"),
        (file, 0, 1, "integer_expression", "[0]"),
        (fake, 0, 2, "integer_expression", "[0]"),
    ]
    labels = {file: "#1", fake: "#2"}
    # The real multiline root ends on line 2, column 2. End 2 preserves
    # that column but changes line; end 4 preserves line but changes column.
    if (Path.cwd() / "multiline.nix").is_file():
        multiline = key("file", root, "multiline.nix", hashlib.sha256(b"41\n#\n").hexdigest())
        rows.extend((multiline, 0, end, "source_code", "[]") for end in (2, 4))
        labels[multiline] = "#3"
    for index, row in enumerate(rows, len(labels) + 1):
        labels[key("anchor", row[0], str(row[1]), str(row[2]), row[3], row[4])] = f"#{index}"
    lines = [f"{label}=@{quote(global_key)}" for global_key, label in labels.items()]
    lines.append(f"nx_files(#2,{quote(root)},{quote('bridge.nix')},{quote(fake_digest)},{quote('project')})")
    for file_id, start, end, kind, path in rows:
        anchor = key("anchor", file_id, str(start), str(end), kind, path)
        lines.append(f"nx_anchors({labels[anchor]},{labels[file_id]},{start},{end},{quote(kind)},{quote(path)})")
    def escaped(text):
        return text.replace("%", "%25").replace("|", "%7C")
    def source_identity(content_hash):
        return "|".join(escaped(part) for part in (root, "bridge.nix", content_hash))
    def metadata(name, value):
        lines.append(f"databaseMetadata({quote(name)},{quote(value)})")
    # Wrong kind and span reuse the genuine file/line/path admission of [0].
    # Wrong path has an explicit companion row, but no such raw child exists.
    metadata("nixql.s2.path|" + source_identity(digest) + "|[7]", "[7]")
    # A same-spelling fake file has line/path metadata, but no authenticated
    # file-map entry. These rows cannot admit it by borrowing the real file.
    metadata("nixql.s2.line|" + source_identity(fake_digest), "1|0")
    metadata("nixql.s2.path|" + source_identity(fake_digest) + "|[0]", "[0]")
    (trap_dir / "adversarial-anchors.trap").write_text("\n".join(lines) + "\n")
    print("S2 quality controls: admitted metadata with wrong kind/path/span; unauthenticated fake digest", flush=True)


def main():
    file_list, driver = Path(sys.argv[1]), sys.argv[2]
    root = Path.cwd().resolve()
    paths = sorted(Path(line).resolve() for line in file_list.read_text().splitlines() if line)
    if not paths:
        raise AssertionError("QL fixture source selection is empty")
    entries = [{"contentHash": hashlib.sha256(path.read_bytes()).hexdigest(),
                "path": str(path.relative_to(root))} for path in paths]
    manifest = {"roots": [{"files": entries, "logicalName": "qltest", "path": str(root),
        "rootContentIdentity": "s2-qltest-v1", "sourceKind": "project"}]}
    with tempfile.TemporaryDirectory(prefix="s2-qltest-") as scratch:
        temp = Path(scratch)
        manifest_file = temp / "manifest.json"
        manifest_file.write_text(json.dumps(manifest))
        subprocess.run([driver, str(manifest_file), str(temp / "output")], check=True)
        trap_dir = Path(os.environ["CODEQL_EXTRACTOR_NIX_TRAP_DIR"])
        absent_builtin_model(trap_dir, json.loads((temp / "output/facts.json").read_text())["facts"])
    if os.environ.get("NIXQL_TEST_DUPLICATE_RAW") == "1":
        duplicate_raw(trap_dir)
    adversarial_anchors(trap_dir)


if __name__ == "__main__":
    main()
