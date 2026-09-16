"""A fake Kiro v2 ACP server, for exercising semble-kiro-acp.py's teardown.

It answers exactly the three exchanges the real driver performs -- initialize,
session/new, and one commands/available notification -- and then does whatever
FAKE_TEARDOWN says once stdin reaches EOF. That last part is the point: the real
`kiro-cli-chat` gives no way to ask for a hang, a panic, or a third-party
signal, so the teardown branches were unreachable by any test and stayed wrong
for weeks.

argv: acp --agent <name>
FAKE_TEARDOWN: hang | signal | <int exit status>
"""

import json
import os
import signal
import sys
import time

# Long enough that the driver's SHUTDOWN_BUDGET_SECONDS always expires first,
# short enough that a leaked process cannot outlive a build.
HANG_SECONDS = 600

agent = sys.argv[sys.argv.index("--agent") + 1]
teardown = os.environ["FAKE_TEARDOWN"]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


# The real server advertises Semble's MCP server to the configured agent only;
# the control agent must see neither the server nor its tools.
def commands_available():
    if agent != "semble-search":
        return {"tools": []}
    return {
        "mcpServers": [{"name": "semble", "status": "running", "toolCount": 2}],
        "tools": [
            {"name": "find_related", "source": "mcp:semble"},
            {"name": "search", "source": "mcp:semble"},
        ],
    }


for line in sys.stdin:
    if not line.strip():
        continue
    request = json.loads(line)
    if request.get("method") == "initialize":
        send({"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": 1}})
    elif request.get("method") == "session/new":
        send({
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {"modes": {"currentModeId": agent}, "sessionId": "fake-session"},
        })
        send({"jsonrpc": "2.0", "method": "_kiro.dev/commands/available", "params": commands_available()})

# stdin reached EOF: this is the window the driver budgets and the fix is about.
if teardown == "hang":
    time.sleep(HANG_SECONDS)
elif teardown == "signal":
    # A third party killing the child, which the driver must still treat as a
    # failure -- `harness_kill` stays false because it sent nothing.
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(HANG_SECONDS)
sys.exit(int(teardown))
