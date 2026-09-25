# Appended to a customized Semble's interpreter header. Drives the patched MCP
# server in-process. First `semble-mcp`'s argument handling, with the server
# stubbed out, then real tool calls through `create_server`, checking the
# model each call's content routed to. argv[1] is a JSON file of expectations,
# argv[2] the repository to index.
import asyncio
import json
import sys
from pathlib import Path

import semble.mcp
from semble import cli
from semble.types import ContentType

expected = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
repo = str(Path(sys.argv[2]).resolve())

# `semble-mcp` argv -> the server's default content.
captured = []


async def fake_serve(content):
    captured.append([item.value for item in content])


real_serve = semble.mcp.serve
semble.mcp.serve = fake_serve
for case in expected["argv"]:
    captured.clear()
    sys.argv = ["semble-mcp", *case["argv"]]
    cli.main()
    assert captured == [case["content"]], (case, captured)
    print("ok argv", case["argv"])
semble.mcp.serve = real_serve


def text_of(result) -> str:
    blocks = result[0] if isinstance(result, tuple) else result
    return blocks[0].text


async def main() -> None:
    default = [ContentType(value) for value in expected["defaultContent"]]
    # serve() preloads this model before the first call.
    assert semble.mcp._model_for(default) == expected["preload"], semble.mcp._model_for(default)
    cache = semble.mcp._IndexCache()
    server = semble.mcp.create_server(cache, default_content=default)
    for call in expected["calls"]:
        arguments = {"repo": repo, **call["arguments"]}
        text = text_of(await server.call_tool(call["tool"], arguments))
        assert text.startswith("{") and '"error"' not in text, (call, text)
        selected = semble.mcp._resolve_content_selection(call["arguments"].get("content"), default)
        key = cache._compute_cache_key(repo, selected)
        assert key[2] == call["model"], (call, key)
        assert cache._tasks[key].result()._model_path == call["model"], call
        print("ok call", call["tool"], call["arguments"].get("content"))
    # One load per model, each used by its own content.
    assert sorted(cache._models) == sorted(expected["models"]), sorted(cache._models)


asyncio.run(main())
