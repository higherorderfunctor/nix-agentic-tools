# shellcheck shell=bash
if usage_cpa codex; then exit 0; fi

timeout 25s python3 - <<'PY' | usage_project codex || {
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
                raise RuntimeError("Codex rate-limit request failed")
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
  printf '%s\n' 'usage: invalid codex usage response' >&2
  exit 1
}
