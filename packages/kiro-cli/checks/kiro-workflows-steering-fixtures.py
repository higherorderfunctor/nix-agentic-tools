# Fixture controls for lib/kiro-workflows-steering.py: the content anchor, the
# exactly-one rule, and the JS escape decoder. The real-bundle drift check
# proves it works on the pinned release; these prove each rule fires.
import subprocess
import sys
import tempfile
from pathlib import Path

extractor = sys.argv[1]
HEAD = "# Workflow Orchestration"


def run(source):
    with tempfile.NamedTemporaryFile("wb", suffix=".js") as bundle:
        bundle.write(source.encode("utf-8"))
        bundle.flush()
        return subprocess.run(
            [sys.executable, extractor, bundle.name], capture_output=True, text=True
        )


def ok(source, expected):
    result = run(source)
    assert result.returncode == 0, (source, result.stderr)
    assert result.stdout == expected, (source, result.stdout, expected)


def fails(source, reason):
    result = run(source)
    assert result.returncode != 0, (source, result.stdout)
    assert reason in result.stderr, (source, result.stderr)


# Any binding name, any surrounding code: the old name, the minified one, none.
for prefix in ["var workflows_default = ", "var Dho=", "x(", ""]:
    ok(prefix + "'" + HEAD + "\\nrun_workflow';", HEAD + "\nrun_workflow")

# Double quotes, and an apostrophe that only a double-quoted literal leaves raw.
ok('a="' + HEAD + " it's run_workflow\";", HEAD + " it's run_workflow")

# The JS escape set, each decoded as JS does.
ok(
    "'" + HEAD + " run_workflow"
    + r"\' \" \\ \t \x41 é \u{1F600} 😀 \q \0 a\
b'",
    HEAD + " run_workflow' \" \\ \t A é \U0001F600 \U0001F600 q \0 ab",
)
# Raw UTF-8 survives (the Latin-1 `unicode_escape` codec would mojibake it).
ok("'" + HEAD + " run_workflow — é'", HEAD + " run_workflow — é")

# Exactly one literal, or a precise failure.
fails("var x = 1;", "expected exactly one string literal beginning with '# Workflow Orchestration', found 0")
fails("'" + HEAD + " run_workflow';'" + HEAD + " run_workflow';", "found 2")
# The heading outside a literal start does not count as a match.
fails("// " + HEAD + "\n'see " + HEAD + "'", "found 0")
fails("`" + HEAD + " ${x} run_workflow`", "template literal")
fails("'" + HEAD + " run_workflow", "unterminated")
fails("'" + HEAD + " run_workflow\n'", "raw line break")
fails("'" + HEAD + r" run_workflow \1'", "legacy octal")
fails("'" + HEAD + r" run_workflow \xZZ'", "malformed escape")
fails("'" + HEAD + r" run_workflow \u{110000}'", "escape out of range")
fails("'" + HEAD + r" run_workflow \uD800'", "unpaired surrogate escape")
fails("'" + HEAD + " nothing else'", "lacks 'run_workflow'")

print("PASS: steering extractor anchors on content and decodes JS escapes")
