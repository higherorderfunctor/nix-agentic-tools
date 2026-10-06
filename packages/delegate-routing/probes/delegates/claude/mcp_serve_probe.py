# Lists the tools `claude mcp serve` exposes over stdio (offline; fake key).
# usage: python3 mcp_serve_probe.py   (writes <work>/out/mcp-serve-tools.json; work = $PROBE_OUT/claude-mcp-serve or a temp dir)
import json, subprocess, os, pathlib, sys
S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S.parent / "common"))
import pin  # noqa: E402
W = pin.workdir("claude-mcp-serve")
C = os.environ.get("CLAUDE_BIN") or str(pin.package("claude-code") / "bin" / "claude")
env = {**{k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}, "CLAUDE_CONFIG_DIR": str(W / "cfg/mcpserve"),
       "ANTHROPIC_API_KEY": "mock", "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "DISABLE_AUTOUPDATER": "1"}
(W / "cfg/mcpserve").mkdir(parents=True, exist_ok=True)
(W / "out").mkdir(exist_ok=True)
if not (W / "fixture").exists():
    subprocess.run([str(S / "mkfixture.sh"), str(W / "fixture")], check=True)
p = subprocess.Popen([C, "mcp", "serve"], cwd=W / "fixture", env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def rpc(i, m, params=None):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": params or {}}) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
init = rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}})
p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
tl = rpc(2, "tools/list")
p.kill()
names = [t["name"] for t in tl["result"]["tools"]]
out = {"serverInfo": init["result"].get("serverInfo"), "capabilities": init["result"].get("capabilities"), "tools": names}
(W / "out" / "mcp-serve-tools.json").write_text(json.dumps({"init": init, "tools": tl}, indent=1))
print(json.dumps(out))
