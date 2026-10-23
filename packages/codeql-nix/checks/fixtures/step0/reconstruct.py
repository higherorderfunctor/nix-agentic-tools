"""Reconstruct only verified relation rows; source bytes enter only the Nix oracle."""
import json
from pathlib import Path
import subprocess
import sys


def reconstruct(rows):
    table = {}
    for node, role, index, value in rows:
        fields = table.setdefault(node, {}).setdefault(role, {})
        assert index not in fields, (node, role, index)
        fields[index] = value
    assert {fields["kind"][0] for fields in table.values()} == {
        "binding", "function", "identifier", "let", "set"}

    def render(node):
        fields = table[node]
        kind = fields["kind"][0]
        def child(role):
            return render(fields[role][0])
        def bindings():
            return " ".join(render(value) for _, value in sorted(fields.get("binding", {}).items()))
        if kind == "identifier":
            return fields["name"][0]
        if kind == "binding":
            segments = fields["segment"]
            assert sorted(segments) == list(range(len(segments))) and segments
            path = ".".join(json.dumps(segments[i]) for i in range(len(segments)))
            return path + " = " + child("value") + ";"
        if kind == "set":
            return "{ " + bindings() + " }"
        if kind == "let":
            return "let " + bindings() + " in " + child("body")
        assert kind == "function"
        return child("parameter") + ": " + child("body")

    roots = [node for node, fields in table.items() if fields["kind"][0] == "function"]
    assert len(roots) == 1
    return render(roots[0])


def parsed(text):
    result = subprocess.run(["nix-instantiate", "--parse", "--expr", text],
                            capture_output=True, text=True, check=True)
    assert result.stdout.strip()
    return result.stdout


def verify(rows, original):
    assert parsed(reconstruct(rows)) == original, "table reconstruction changed parsed syntax"


rows = []
for line in Path(sys.argv[1]).read_text().splitlines():
    node, role, index, value = (field.strip() for field in line.strip("|").split("|"))
    rows.append((node, role, int(index), value))
# The caller has already established exact equality of these reviewed rows and
# the live database output through codeql test run. No source archive is opened.
original = subprocess.run(["nix-instantiate", "--parse", sys.argv[2]],
                          capture_output=True, text=True, check=True).stdout
verify(rows, original)
print("A0 reconstruction: all five forms agree with independent nix-instantiate --parse")
for role in ("body", "segment"):
    mutant = [row for row in rows if row[1] != role]
    try:
        verify(mutant, original)
    except (AssertionError, KeyError, subprocess.CalledProcessError):
        print(f"A0 reconstruction: missing-{role} table refused (source replay cannot pass)")
    else:
        raise AssertionError(f"missing-{role} table unexpectedly reconstructed")
