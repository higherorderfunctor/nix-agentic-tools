import json
import sys


# The TUI is materialized before chat needs an agent. Answer only the initial
# capability handshake; never authenticate or accept a session/prompt request.
for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") != "initialize":
        break
    response = {
        "jsonrpc": "2.0",
        "id": request["id"],
        "result": {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": False,
                "promptCapabilities": {},
                "mcpCapabilities": {},
            },
            "authMethods": [],
        },
    }
    print(json.dumps(response), flush=True)
