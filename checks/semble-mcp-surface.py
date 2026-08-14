"""Extract the Semble MCP server's tool surface by speaking MCP to it.

Emits ``{"<tool>": {"arguments": [...], "required": [...]}}`` on stdout.

Why the wire protocol rather than importing ``semble.mcp`` and introspecting:
the private constructor signatures move between releases (0.5.4's
``_IndexCache`` takes ``content``, 0.5.5's does not), so introspection would
need version-specific handling to answer a version-independent question. A
JSON-RPC ``tools/list`` is what an agent runtime actually sees, and it is
stable across both.

This runs inside the Nix build sandbox with no network. That is fine: the
server pre-loads its embedding model in a background task whose failure is
caught and logged, and stdio serving does not wait on it, so ``tools/list``
answers in seconds without ever reaching the network.
"""

from __future__ import annotations

import json
import subprocess
import sys

REQUESTS = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "nix-agentic-tools-surface-probe", "version": "0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
]

TIMEOUT_SECONDS = 120


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: semble-mcp-surface.py <path-to-semble-mcp>")

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

    tools = None
    for line in proc.stdout:
        message = json.loads(line)
        if message.get("id") == 2:
            if "error" in message:
                proc.kill()
                sys.exit(f"FAIL: semble-mcp rejected tools/list: {message['error']}")
            tools = message["result"]["tools"]
            break

    proc.stdin.close()
    try:
        proc.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()

    # A silent empty answer must fail the build rather than snapshot an empty
    # surface, which would then "match" a reviewed empty surface forever.
    if not tools:
        sys.exit("FAIL: semble-mcp returned no tools from tools/list")

    surface = {
        tool["name"]: {
            "arguments": sorted((tool["inputSchema"].get("properties") or {}).keys()),
            "required": sorted(tool["inputSchema"].get("required") or []),
        }
        for tool in tools
    }
    json.dump(surface, sys.stdout, indent=2, sort_keys=True)


if __name__ == "__main__":
    main()
