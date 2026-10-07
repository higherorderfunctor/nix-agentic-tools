"""Print the Semble MCP tools/list surface as stable reviewable JSON."""

from __future__ import annotations

import json
import selectors
import subprocess
import sys
import time

REQUESTS = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "nix-agentic-tools", "version": "0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: semble-mcp-surface.py <semble-mcp>")

    proc = subprocess.Popen(
        [sys.argv[1]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert proc.stdin is not None and proc.stdout is not None
    for request in REQUESTS:
        proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()

    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    response = None
    deadline = time.monotonic() + 120
    while response is None and time.monotonic() < deadline:
        for key, _ in selector.select(deadline - time.monotonic()):
            line = key.fileobj.readline()
            if not line:
                break
            message = json.loads(line)
            if message.get("id") == 2:
                response = message
                break

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    if response is None:
        sys.exit("FAIL: semble-mcp timed out or returned no tools/list response")
    if "error" in response:
        sys.exit(f"FAIL: semble-mcp rejected tools/list: {response['error']}")

    tools = response["result"]["tools"]
    if not tools:
        sys.exit("FAIL: semble-mcp returned an empty tool list")

    # Preserve the complete contract exposed by tools/list. In particular, the
    # committed prompt depends on content remaining a scalar with the documented
    # enum, which a names-only projection could not guard.
    surface = {
        tool["name"]: {key: value for key, value in tool.items() if key != "name"}
        for tool in tools
    }
    json.dump(surface, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
