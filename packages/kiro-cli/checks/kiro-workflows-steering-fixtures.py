"""Negative controls supplement the renamed-binding hook fixture in runtime.py."""
import runpy
import sys

extract = runpy.run_path(sys.argv[1])["extract"]
literal = b"'# Workflow Orchestration run_workflow"
for tail in [b"';" + literal, rb"\q", rb"\N{SPACE}", rb"\a", rb"\uD800", rb"\uDC00"]:
    source = literal + tail + b"'"
    try:
        extract(source)
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError(f"accepted invalid steering: {source!r}")
print("PASS: duplicate steering and unsupported escapes are rejected")
