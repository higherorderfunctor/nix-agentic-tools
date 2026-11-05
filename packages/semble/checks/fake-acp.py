"""A fake Kiro v3 ACP server, for exercising semble-kiro-acp.py's teardown.

It answers exactly the three exchanges the real driver performs -- initialize,
session/new, and one mcp/status notification -- and then does whatever
FAKE_TEARDOWN says once stdin reaches EOF. That last part is the point: the real
`kiro-cli` gives no way to ask for a hang, a panic, or a third-party
signal, so the teardown branches were unreachable by any test and stayed wrong
for weeks.

argv: acp (the v3 engine rejects `--agent`; the agent arrives as
`session/new` `_meta.kiro.modeId`)
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

# A driver still passing the v2 selector must fail here as it does on the real
# engine.
if "--agent" in sys.argv:
    sys.exit("error: the following arguments are not supported with --agent-engine=v3: --agent")
teardown = os.environ["FAKE_TEARDOWN"]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


# The real server connects Semble's MCP server for the configured agent only;
# the control agent must see neither the server nor its tools.
def mcp_status(agent):
    if agent != "semble-search":
        return None
    return {
        "sessionId": "fake-session",
        "servers": [
            {
                "name": "semble",
                "status": "connected",
                "tools": [{"name": "find_related"}, {"name": "search"}],
            }
        ],
    }


for line in sys.stdin:
    if not line.strip():
        continue
    request = json.loads(line)
    if request.get("method") == "initialize":
        send({"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": 1}})
    elif request.get("method") == "session/new":
        agent = request["params"]["_meta"]["kiro"]["modeId"]
        send({
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {
                "modes": {"currentModeId": agent, "availableModes": [{"id": agent}]},
                "sessionId": "fake-session",
            },
        })
        status = mcp_status(agent)
        if status is not None:
            send({"jsonrpc": "2.0", "method": "_kiro/mcp/status", "params": status})

# stdin reached EOF: this is the window the driver budgets and the fix is about.
if teardown == "hang":
    time.sleep(HANG_SECONDS)
elif teardown == "signal":
    # A third party killing the child, which the driver must still treat as a
    # failure -- `harness_kill` stays false because it sent nothing.
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(HANG_SECONDS)
sys.exit(int(teardown))
