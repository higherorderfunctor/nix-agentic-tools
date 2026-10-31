"""Synthetic mitmdump and Kiro stand-in; never sends network traffic."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import sys
import time
from urllib.parse import urlsplit

if "--listen-host" in sys.argv:
    args = sys.argv[1:]
    assert args[args.index("--listen-host") + 1] == "127.0.0.1"
    assert args[args.index("--allow-hosts") + 1] == r"^runtime\.us-east-1\.kiro\.dev:443$"
    assert not os.environ.get("HTTPS_PROXY")
    state = Path(os.environ["KIRO_USAGE_DB"]).parent
    sys.path.insert(0, sys.argv[sys.argv.index("--scripts") + 1].rsplit("/", 1)[0])
    from capture import Collector
    Collector(os.environ["KIRO_USAGE_DB"]).close()
    (state / "service.json").write_text(json.dumps({"argv": args, "warn_bytes": os.environ["KIRO_USAGE_WARN_BYTES"]}))
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
        # One finished call of this run, marked as the collector marks it: by the proxy credentials' invocation.
        invocation = urlsplit(os.environ["HTTPS_PROXY"]).username.removeprefix("kiro-usage-")
        with sqlite3.connect(Path(os.environ["XDG_STATE_HOME"]) / "kiro-cli/usage/usage.sqlite3") as db:
            db.execute("INSERT INTO captures(id,started_utc_ns,metadata_json,state,completion_seen,credits) VALUES (?,?,?,'complete',1,.5)",
                       (invocation, time.time_ns(), json.dumps({"invocation": invocation, "kiro:conversation_id": "sess_auto_index"})))
        db.close()
    print(json.dumps({"argv": sys.argv[1:], "proxy": os.environ.get("HTTPS_PROXY"), "ca": os.environ.get("NODE_EXTRA_CA_CERTS"), "bypass": {name: os.environ[name] for name in ("ALL_PROXY", "NO_PROXY", "all_proxy", "no_proxy") if name in os.environ}}))
