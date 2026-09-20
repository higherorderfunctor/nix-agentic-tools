#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

timeout 25s python3 - <<'PY' | jq '.rateLimits.primary | {usedPercent, remainingPercent: (100 - .usedPercent), resetsAt: (.resetsAt | strflocaltime("%Y-%m-%d %H:%M:%S %Z"))}'
import json
import subprocess

p = subprocess.Popen(
    ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
)


def send(message):
    p.stdin.write(json.dumps(message) + "\n")
    p.stdin.flush()


def receive(request_id):
    for line in p.stdout:
        message = json.loads(line)
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(message["error"])
            return message["result"]
    raise RuntimeError("Codex closed the connection")


try:
    send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "usage_check", "version": "1.0"}}})
    receive(1)
    send({"method": "initialized"})
    send({"id": 2, "method": "account/rateLimits/read"})
    print(json.dumps(receive(2)))
finally:
    p.stdin.close()
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
PY
