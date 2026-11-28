# Appended to a customized Semble's interpreter header. Drives the patched MCP
# server in-process. First `semble-mcp`'s argument handling, with the server
# stubbed out, then real tool calls through `create_server`, checking the
# model each call's content routed to. argv[1] is a JSON file of expectations,
# argv[2] the repository to index.
import asyncio
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch

import semble.mcp
from semble import cli
from semble.cache import find_index_from_cache_folder
from semble.types import ContentType

expected = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
repo = str(Path(sys.argv[2]).resolve())

# `semble-mcp` argv -> the server's default content and upstream's --http port.
captured = []


async def fake_serve(content, port):
    captured.append(([item.value for item in content], port))


# 0.6.2's semble-mcp ends in os._exit(0) after serve(), which would end this
# script before its assertions run.
class _Exited(BaseException):
    pass


def _fake_exit(code):
    assert code == 0, code
    raise _Exited


real_exit = os._exit
real_serve = semble.mcp.serve
os._exit = _fake_exit
semble.mcp.serve = fake_serve
try:
    for case in expected["argv"]:
        captured.clear()
        sys.argv = ["semble-mcp", *case["argv"]]
        try:
            cli.main()
        except _Exited:
            pass
        assert captured == [(case["content"], case["port"])], (case["name"], captured)
        print("ok argv", case["name"])
finally:
    semble.mcp.serve = real_serve
    os._exit = real_exit


def text_of(result) -> str:
    return result.content[0].text


class StubServer:
    """Stands in for the stdio server: waits for the loads serve() started."""

    def __init__(self, cache) -> None:
        self.cache = cache

    async def run_stdio_async(self) -> None:
        await asyncio.wait(list(self.cache._models.values()))


async def drive_serve(default) -> None:
    """Run the real serve() with the stdio server stubbed; check what it preloads."""
    created = []
    real_create_server = semble.mcp.create_server

    def fake_create_server(cache, default_content):
        created.append(cache)
        return StubServer(cache)

    semble.mcp.create_server = fake_create_server
    try:
        await semble.mcp.serve(default)
    finally:
        semble.mcp.create_server = real_create_server
    (cache,) = created
    assert list(cache._models) == [expected["preload"]], list(cache._models)
    assert cache._models[expected["preload"]].result() == expected["preload"]
    print("ok serve preload", expected["preload"])


async def failed_load_is_retrieved() -> None:
    """A load nobody awaits must not end as 'Task exception was never retrieved'."""
    cache = semble.mcp._IndexCache()
    task = cache._model_task(str(Path(sys.argv[2]) / "no-such-model"))
    await asyncio.wait([task])
    # asyncio clears this flag once the exception is retrieved; only the done
    # callback can have done that yet, so check it before calling exception().
    assert task._log_traceback is False
    assert task.exception() is not None
    print("ok failed load retrieved")


class RecordingCache(semble.mcp._IndexCache):
    """Observe the real index that each tool receives, including cache hits."""

    def __init__(self) -> None:
        super().__init__()
        self.served = []

    async def get(self, source, content=(ContentType.CODE,)):
        index = await super().get(source, content=content)
        self.served.append((source, sorted(item.value for item in index.content), index._model_path))
        return index


async def main() -> None:
    # A fixed model name pins the cache ABI without hashing the production input twice.
    name = find_index_from_cache_folder(repo, (ContentType.DOCS,), "fixture/model").name
    assert name == "index-docs@9f0bc9496cfb0995", name
    default = [ContentType(value) for value in expected["defaultContent"]]
    await drive_serve(default)
    await failed_load_is_retrieved()
    cache = RecordingCache()
    server = semble.mcp.create_server(cache, default_content=default)
    with patch.object(semble.mcp, "_load_model", wraps=semble.mcp._load_model) as load:
        for call in expected["calls"]:
            cache.served.clear()
            arguments = {"repo": repo, **call["arguments"]}
            text = text_of(await server.call_tool(call["tool"], arguments))
            assert text.startswith("{") and "error" not in json.loads(text), (call["name"], text)
            assert cache.served == [(repo, call["content"], call["model"])], (call["name"], cache.served)
            print("ok", call["name"])
    # Count actual loads, not just distinct model keys remaining in the cache.
    loads = sorted(args[0] for args, _ in load.await_args_list)
    assert loads == sorted(expected["models"]), loads


asyncio.run(main())
