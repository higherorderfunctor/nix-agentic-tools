"""LIVE probe (costs quota; uses the operator's own Claude login): a logging pass-through proxy in
front of api.anthropic.com. Logs request BODIES only (never headers) to <work>/out/<case>/NNN.json,
then runs one `claude -p --model haiku` against it. Usage: python3 live_proxy_probe.py <case>
<work> = $PROBE_OUT/claude-live or a fresh temp dir.
Case live_resume: does SendMessage to a COMPLETED background agent resume it with its prior history?
"""
import argparse, json, os, pathlib, ssl, subprocess, sys, threading, time, http.client
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S.parent / "common"))
import pin  # noqa: E402
W = pin.workdir("claude-live")
CLAUDE = os.environ.get("CLAUDE_BIN") or str(pin.package("claude-code") / "bin" / "claude")
PORT = int(os.environ.get("MOCK_PORT", "18790"))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("case", choices=["live_resume"])
parser.add_argument("--claude-token-file", required=True, help="Read the OAuth token from this file descriptor; never log or persist it")
args = parser.parse_args()
CASE = args.case
OUT = W / "out" / CASE
OUT.mkdir(parents=True, exist_ok=True)
N = [0]
LOCK = threading.Lock()


class P(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def fwd(self, method):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) if method == "POST" else None
        if method == "POST" and "/v1/messages" in self.path and "count_tokens" not in self.path:
            with LOCK:
                N[0] += 1
                try:
                    (OUT / f"{N[0]:03}.json").write_text(json.dumps({"path": self.path, "t": time.time(),
                                                                      "body": json.loads(body)}, indent=1))
                except Exception:
                    pass
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection",
                                                                          "accept-encoding")}
        c = http.client.HTTPSConnection("api.anthropic.com", context=ssl.create_default_context(), timeout=300)
        c.request(method, self.path, body=body, headers=hdrs)
        r = c.getresponse()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "content-length", "connection", "content-encoding"):
                self.send_header(k, v)
        self.end_headers()
        while True:
            chunk = r.read1(65536) if hasattr(r, "read1") else r.read(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def do_POST(self):
        self.fwd("POST")

    def do_GET(self):
        self.fwd("GET")


PROMPTS = {
    "live_resume": (
        "This is an automated harness test. Follow these steps exactly and do nothing else.\n"
        "Step 1: call the Agent tool with run_in_background true, description 'resume probe', and prompt: "
        "'Run the Bash command: echo ALPHA_7731 . Then reply with exactly the word DONE and nothing else.'\n"
        "Step 2: when the completion notification for that agent arrives, call SendMessage with to set to that agent's agentId "
        "and message: 'What exact text did your Bash command print? Reply with only that text.'\n"
        "Step 3: when that agent's second completion notification arrives, reply with exactly FINISHED."),
}

if __name__ == "__main__":
    if not (W / "fixture").exists():
        subprocess.run([str(S / "mkfixture.sh"), str(W / "fixture")], check=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), P)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE",) and not k.startswith("CLAUDE_CODE_")}
    # Keep this case's login in process memory only; its scratch config is empty.
    for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"):
        env.pop(key, None)
    env["CLAUDE_CONFIG_DIR"] = str(W / "config")
    env["CLAUDE_CODE_OAUTH_TOKEN"] = pathlib.Path(args.claude_token_file).read_text().strip()
    env.update({"ANTHROPIC_BASE_URL": f"http://127.0.0.1:{PORT}", "DISABLE_AUTOUPDATER": "1",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
    argv = [CLAUDE, "-p", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config", "--mcp-config",
            '{"mcpServers":{}}', "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions",
            "--output-format", "stream-json", "--verbose", PROMPTS[CASE]]
    (OUT / "argv.json").write_text(json.dumps({"argv": argv, "cwd": str(W / "fixture")}, indent=1))
    r = subprocess.run(argv, cwd=W / "fixture", env=env, capture_output=True, text=True, timeout=300, input="")
    (OUT / "stdout").write_text(r.stdout)
    (OUT / "stderr").write_text(r.stderr)
    srv.shutdown()
    print("rc", r.returncode, "requests", N[0], "stderr", r.stderr[-300:])
