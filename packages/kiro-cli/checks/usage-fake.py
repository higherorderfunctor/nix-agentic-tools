"""Synthetic mitmdump and Kiro stand-in; never sends network traffic."""
import json
import os
from pathlib import Path
import socket
import sys

if "--listen-host" in sys.argv:
    args = sys.argv[1:]
    assert args[args.index("--listen-host") + 1] == "127.0.0.1"
    assert args[args.index("--allow-hosts") + 1] == r"^runtime\.us-east-1\.kiro\.dev:443$"
    assert not os.environ.get("HTTPS_PROXY")
    state = Path(os.environ["KIRO_USAGE_DB"]).parent
    sys.path.insert(0, sys.argv[sys.argv.index("--scripts") + 1].rsplit("/", 1)[0])
    from capture import Collector
    Collector(os.environ["KIRO_USAGE_DB"]).close()
    (state / "service.json").write_text(json.dumps({"argv": args, "budget": os.environ["KIRO_USAGE_MAX_BYTES"]}))
    (state / "ca/mitmproxy-ca-cert.pem").write_text("synthetic test CA\n")
    with socket.socket() as server:
        server.bind(("127.0.0.1", int(args[args.index("--listen-port") + 1])))
        server.listen()
        while True:
            connection, _ = server.accept()
            connection.close()
else:
    if os.environ.get("KIRO_USAGE_TEST_AUTO_INDEX"):
        session = Path(os.environ["HOME"]) / ".kiro/sessions/workspace/sess_auto_index"
        session.mkdir(parents=True, exist_ok=True)
        (session / "session.json").write_text(json.dumps({"modelId": "synthetic-auto-index"}))
        (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": [{"usage": .75, "unit": "credit"}]}}) + "\n")
    print(json.dumps({"argv": sys.argv[1:], "proxy": os.environ.get("HTTPS_PROXY"), "ca": os.environ.get("NODE_EXTRA_CA_CERTS"), "bypass": {name: os.environ[name] for name in ("ALL_PROXY", "NO_PROXY", "all_proxy", "no_proxy") if name in os.environ}}))
