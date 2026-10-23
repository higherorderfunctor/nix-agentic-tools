"""Exercise the shared production syntax writer before kit text clipping occurs."""

import argparse
from itertools import chain
import json
from pathlib import Path
import re
import subprocess
import tempfile

LIMIT = 1048576


def tuple_strings(trap):
    """Decode TRAP quote doubling, excluding comments and global label keys."""
    for line in trap.splitlines():
        if not re.match(r"^[A-Za-z_][A-Za-z_0-9]*\(", line):
            continue
        position = line.index("(") + 1
        while position < len(line):
            start = line.find('"', position)
            if start < 0:
                break
            pieces = []
            position = start + 1
            while True:
                end = line.index('"', position)
                pieces.append(line[position:end])
                position = end + 1
                if position < len(line) and line[position] == '"':
                    pieces.append('"')
                    position += 1
                else:
                    break
            yield "".join(pieces)


def cases():
    for size in (LIMIT - 1, LIMIT, LIMIT + 1):
        ascii_text = "x" * size
        unicode_text = "é" * (size // 2) + "x" * (size % 2)
        comment = "#" + '"' * (size - 1)
        path = "./" + "x" * (size - 2)
        logical = "/bootstrap/" + "x" * (size - len("/bootstrap/.nix")) + ".nix"
        for name, source, logical_path, exact in (
            ("attribute-key", "{" + ascii_text + " = 0;}", "/bootstrap/input.nix", ascii_text),
            ("comment-quotes", comment + "\n0", "/bootstrap/input.nix", comment),
            ("file-path", "0", logical, logical),
            ("path-fragment", path, "/bootstrap/input.nix", path),
            ("string-ascii", '"' + ascii_text + '"', "/bootstrap/input.nix", ascii_text),
            ("string-utf8", '"' + unicode_text + '"', "/bootstrap/input.nix", unicode_text),
        ):
            assert len(exact.encode("utf-8")) == size
            yield f"{name}/{size}", source, logical_path, exact, size <= LIMIT, None



def diagnostic_cases():
    malformed = (
        "A parse error occurred. Check the syntax of the file. If the file is invalid, "
        "correct the error or exclude the file from analysis."
    )
    mismatch = (
        'Type mismatch for field source_code::expression with type '
        'TypeName { kind: "integer_expression", named: true } != '
        'Single(TypeName { kind: "identifier", named: true })'
    )
    schema = [
        {"named": True, "type": "identifier"},
        {"named": True, "type": "integer_expression"},
        {
            "fields": {
                "expression": {
                    "multiple": False,
                    "required": False,
                    "types": [{"named": True, "type": "identifier"}],
                },
            },
            "named": True,
            "type": "source_code",
        },
    ]
    for name, source, plaintext, node_types in (
        ("parse-diagnostic", "]", malformed, None),
        ("ordinary-tree-diagnostic", "0", mismatch, schema),
    ):
        logical = "/bootstrap/diagnostic.nix"
        yield name + "/short", source, logical, f"{logical}:1: {plaintext}", True, node_types
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            overhead = len(("/bootstrap/.nix:1: " + plaintext).encode("utf-8"))
            logical = "/bootstrap/" + "x" * (size - overhead) + ".nix"
            full = f"{logical}:1: {plaintext}"
            assert len(full.encode("utf-8")) == size
            yield f"{name}/message-{size}", source, logical, full, size <= LIMIT, node_types
        logical = "/bootstrap/" + "x" * (LIMIT - 1 - len("/bootstrap/.nix")) + ".nix"
        yield name + "/near-limit-path", source, logical, "", False, node_types


def check_result(result, trap_file, exact, accepted, name):
    if accepted:
        assert result.returncode == 0, (name, result.returncode, result.stderr[:4096])
        assert trap_file.is_file(), (name, "no completed TRAP")
        strings = list(tuple_strings(trap_file.read_text(encoding="utf-8")))
        assert exact in strings, (name, "exact field did not round-trip through kit TRAP")
        assert all(len(text.encode("utf-8")) <= LIMIT for text in strings), name
    else:
        assert result.returncode != 0, (name, "expected refusal")
        assert result.returncode == 2, (name, result.returncode)
        assert b"text-field-too-large" in result.stderr, (name, result.stderr[:4096])
        assert len(result.stderr) < 8192, (name, "diagnostic embeds oversized field")
        assert not trap_file.exists(), (name, "rejected transaction published TRAP")


def syntax_cases(probe, scratch):
    count = 0
    for case in chain(cases(), diagnostic_cases()):
        name, source, logical, exact, accepted, schema = case
        with tempfile.TemporaryDirectory(prefix="preflight-", dir=scratch) as temp:
            root = Path(temp)
            source_file, path_file, trap_file = (root / n for n in ("source.nix", "path.txt", "syntax.trap"))
            source_file.write_text(source, encoding="utf-8")
            path_file.write_text(logical, encoding="utf-8")
            command = [str(probe.resolve()), str(source_file), str(path_file), str(trap_file)]
            if schema is not None:
                schema_file = root / "node-types.json"
                schema_file.write_text(json.dumps(schema), encoding="utf-8")
                command.append(str(schema_file))
            result = subprocess.run(command, capture_output=True, check=False, timeout=90)
            check_result(result, trap_file, exact, accepted, name)
        count += 1
        print(f"PASS {name}")
    assert count == 28, f"empty or incomplete syntax corpus: {count}"
    print(f"PASS {count} raw exact-text and diagnostic cases")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args()
    args.scratch.mkdir(parents=True, exist_ok=True)
    syntax_cases(args.probe, args.scratch)


if __name__ == "__main__":
    main()
