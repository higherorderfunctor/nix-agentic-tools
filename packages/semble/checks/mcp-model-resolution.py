# Appended to a customized Semble's interpreter header. Drives the patched
# `semble-mcp` argument handling with the server stubbed out, and checks the
# content and model each argv resolves to. argv[1] is a JSON list of cases:
# {"argv": [...], "content": [...], "model": str | null} or
# {"argv": [...], "exit": int}.
import asyncio
import json
import os
import sys

import semble.mcp
from semble import cli

resolved = []


async def fake_serve(content):
    resolved.append(([item.value for item in content], os.environ.get("SEMBLE_MODEL_NAME")))


semble.mcp.serve = fake_serve

with open(sys.argv[1], encoding="utf-8") as handle:
    cases = json.load(handle)

for case in cases:
    os.environ.pop("SEMBLE_MODEL_NAME", None)
    resolved.clear()
    sys.argv = ["semble-mcp", *case["argv"]]
    try:
        cli.main()
    except SystemExit as exc:
        assert "exit" in case and exc.code == case["exit"], (case, exc.code)
        continue
    assert "exit" not in case, case
    assert resolved == [(case["content"], case["model"])], (case, resolved)
    print("ok", case["argv"])
