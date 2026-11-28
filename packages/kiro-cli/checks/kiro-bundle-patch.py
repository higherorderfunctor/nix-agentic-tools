# cspell:ignore héllo nined Ahéllo
"""Check scoped edits on a synthetic bundle: matching, splicing, re-encoding, and refusal.

The bundle carries a non-ASCII prefix and three prompts (a single-quoted string with escapes, a
backtick template, a double-quoted string) whose raw bytes and decoded text are written out here
independently of the patcher. Usage: `kiro-bundle-patch.py <patcher>`.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("patcher", sys.argv.pop(1))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
Edit = patcher.Edit

# name, quote, raw literal body, decoded text
PROMPTS = {
    "s": ("'", "héllo \\u00e9 \\x41\\n\\'q\\' jo\\\nined aaa end", "héllo é A\n'q' joined aaa end"),
    "t": ("`", "top\nmid \\` and \\${ kept $ tail\r\nend", "top\nmid ` and ${ kept $ tail\nend"),
    "u": ('"', 'joined \\"u\\" only-u', 'joined "u" only-u'),
}
BUNDLE = "var prefix='é😀';\n".encode()
FACTS = {}
for name, (quote, raw, text) in PROMPTS.items():
    BUNDLE += f"var {name}=".encode()
    FACTS[name] = {"start": len(BUNDLE), "kind": "NoSubstitutionTemplateLiteral" if quote == "`" else "StringLiteral", "text": text}
    BUNDLE += f"{quote}{raw}{quote}".encode()
    FACTS[name]["end"] = len(BUNDLE)
    BUNDLE += b";\n"
TEXTS = {name: text for name, (_, _, text) in PROMPTS.items()}
OUTPUT = "console.log(JSON.stringify([s,t,u]))"
SPAN = "héllo é A\n"
# Replacement text that must survive as the same JavaScript string value in every literal kind.
NASTY = "é😀 it's \"new\" `b` ${c} $ {y} \\n\n\r\u2028"
EDITS = {
    "match spanning an escape and a continuation": ("s", "joined", NASTY),
    "template backtick, dollar and brace": ("t", "` and ${ kept", NASTY),
    "template text after an unchanged dollar": ("t", " tail", "{y"),
    "match across a template CRLF": ("t", "tail\nend", "T"),
    "double-quoted string": ("u", "only", NASTY),
    "match after a non-ASCII prefix": ("s", "é A", "E"),
    "span edit with its pinned digest": ("s", "héllo", "H"),
}


def run(edits, facts=FACTS):
    return patcher.patch(BUNDLE, facts, edits)


class PatchTests(unittest.TestCase):
    def evaluate(self, bundle):
        return json.loads(subprocess.check_output(["node", "-e", bundle.decode() + OUTPUT]))

    def test_edits_round_trip_through_node_and_leave_other_bytes(self):
        for label, (leaf, match, replace) in EDITS.items():
            with self.subTest(label):
                spanned = {"until": "A\n", "sha256": hashlib.sha256(SPAN.encode()).hexdigest()} if label.startswith("span") else {}
                result, errors = run([Edit("x", leaf, match, replace, **spanned)])
                self.assertEqual(errors, [])
                expected = {**TEXTS, leaf: TEXTS[leaf].replace(SPAN if spanned else match, replace, 1)}
                self.assertEqual(self.evaluate(result), [expected[name] for name in "stu"])
                fact = FACTS[leaf]
                self.assertEqual(result[: fact["start"]], BUNDLE[: fact["start"]])
                tail = len(BUNDLE) - fact["end"]
                self.assertEqual(result[len(result) - tail :], BUNDLE[fact["end"] :])

    def test_adjacent_edits_apply_once_by_original_offsets(self):
        result, errors = run([Edit("b", "s", "é A", "héllo "), Edit("a", "s", "héllo ", "é A")])
        self.assertEqual(errors, [])
        self.assertEqual(self.evaluate(result)[0], "é Ahéllo \n'q' joined aaa end")

    def test_refusals_name_edits_never_content(self):
        digest = hashlib.sha256(SPAN.encode()).hexdigest()
        rows = {
            "overlapping occurrences": ([Edit("e", "s", "aa", "x")], ["e: expected exactly one match in s, found 2"]),
            "empty match": ([Edit("e", "s", "", "x")], ["e: expected exactly one match in s, found 0"]),
            "absent": ([Edit("e", "s", "zzz", "x")], ["e: expected exactly one match in s, found 0"]),
            "text only in another prompt": ([Edit("e", "t", "only-u", "x")], ["e: expected exactly one match in t, found 0"]),
            "unknown prompt": ([Edit("e", "v", "x", "y")], ["e: unknown leaf v"]),
            "duplicate id": ([Edit("e", "s", "héllo", "x"), Edit("e", "u", "only", "y")], ["e: named by more than one edit"]),
            "intersection": (
                [Edit("a", "s", "héllo é", "x"), Edit("b", "s", "é A", "y"), Edit("c", "u", "only", "z")],
                ["a and b: selections intersect in s"],
            ),
            "digest drift": ([Edit("e", "s", "héllo", "x", "A\n", "0" * 64)], ["e: the selected text differs from its pinned digest"]),
            "end anchor ambiguous": ([Edit("e", "s", "héllo", "x", "a", digest)], ["e: expected exactly one end anchor in s, found 3"]),
            "end anchor first": ([Edit("e", "s", "end", "x", "héllo", digest)], ["e: the end anchor does not follow the match"]),
            "valid edit beside a bad one": ([Edit("ok", "s", "héllo", "x"), Edit("bad", "t", "zzz", "y")], ["bad: expected exactly one match in t, found 0"]),
        }
        for label, (edits, expected) in rows.items():
            with self.subTest(label):
                result, errors = run(edits)
                self.assertIsNone(result)
                self.assertEqual(errors, expected)
        drifted = {**FACTS, "s": {**FACTS["s"], "end": FACTS["s"]["end"] - 1}}
        self.assertEqual(run([], drifted), (None, ["leaf s: the extracted fact does not match the bundle"]))

    def test_cli_keeps_stock_bytes_exports_leaves_and_never_half_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "in.js").write_bytes(BUNDLE)
            (root / "facts.json").write_text(json.dumps(FACTS), encoding="utf-8")

            def cli(*args):
                return subprocess.run([sys.executable, patcher.__file__, str(root / "in.js"), str(root / "facts.json"), *args], capture_output=True, text=True)

            self.assertEqual(cli(str(root / "stock.js"), "--export-leaves", str(root / "out")).returncode, 0)
            self.assertEqual((root / "stock.js").read_bytes(), BUNDLE)
            self.assertEqual({p.name: p.read_text(encoding="utf-8") for p in (root / "out").iterdir()}, {f"{n}.txt": t for n, t in TEXTS.items()})
            (root / "kept.js").write_bytes(b"untouched")
            for args in (["--check"], [str(root / "kept.js"), "--replace", "relativeFileCheckPaths"]):
                result = cli(*args)
                self.assertEqual(result.returncode, 1)
                self.assertIn("relativeFileCheckPaths.paragraph: unknown leaf agents.workflow.creator", result.stderr)
            self.assertEqual((root / "kept.js").read_bytes(), b"untouched")

    def test_builtin_ids_are_namespaced_by_their_tweak(self):
        for tweak, edits in patcher.TWEAKS.items():
            self.assertTrue(all(edit.id.startswith(f"{tweak}.") for edit in edits))


if __name__ == "__main__":
    unittest.main()
