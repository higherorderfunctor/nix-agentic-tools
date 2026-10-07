"""Run one offline Kimchi scenario against fakeprov.py. usage: drive.py <scenario.json> [<outdir>]
<outdir> defaults to <work>/<scenario name>; work = $PROBE_OUT/kimchi or a fresh temp dir.
Binaries: the repository's pinned kimchi and kimchi-workflows (KIMCHI_PKG / KIMCHI_WORKFLOWS_PKG override).

scenario keys: args (kimchi argv after the binary), stdin_lines (RPC/ACP: [{"at": sec, "line": obj}]),
after_request (optional stdin-line marker: wait for its first fake-provider POST before sending),
after_previous (optional stdin-line delay in seconds after the preceding send),
timeout (sec), env (extra env), workflows (bool: link kimchi-workflows ext), files ({relpath: text}
written under the project dir), home_files ({relpath: text} under HOME).
Outputs: <outdir>/{provider.jsonl,stdout,stderr,meta.json}
"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time, signal
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "common"))
import pin  # noqa: E402
if len(sys.argv) < 2:
    sys.exit(__doc__)
KIMCHI = str(pin.package("kimchi") / "bin" / "kimchi")
sc = json.loads(Path(sys.argv[1]).read_text())
WF = str(pin.package("kimchi-workflows")) if sc.get("workflows") else None
out = Path(sys.argv[2]) if len(sys.argv) > 2 else pin.workdir("kimchi") / Path(sys.argv[1]).stem
shutil.rmtree(out, ignore_errors=True); out.mkdir(parents=True)
base = Path(tempfile.mkdtemp(prefix="kd-", dir=out))
home, proj = base / "home", base / "project"
env = {"HOME": str(home), "PATH": os.environ["PATH"], "KIMCHI_TELEMETRY_ENABLED": "0", "KIMCHI_NO_UPDATE_CHECK": "1", "OLLAMA_HOST": "http://127.0.0.1:9"}
for k, d in [("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_RUNTIME_DIR", "runtime"), ("XDG_STATE_HOME", "state")]:
    (base / d).mkdir(parents=True, mode=0o700); env[k] = str(base / d)
proj.mkdir(parents=True)
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
harness = home / ".config/kimchi/harness"; harness.mkdir(parents=True)
cfg = json.dumps({"llmEndpoint": f"http://127.0.0.1:{port}", "apiKey": "fake-key", "telemetry": {"enabled": False}})
for d in (home / ".config/kimchi", base / "config/kimchi"):
    d.mkdir(parents=True, exist_ok=True); (d / "config.json").write_text(cfg)
settings = {}
if sc.get("workflows"):
    (harness / "extensions").mkdir(); (harness / "extensions/workflows").symlink_to(WF, target_is_directory=True)
    settings["packages"] = ["extensions/workflows"]
settings.update(sc.get("settings", {}))
if settings: (harness / "settings.json").write_text(json.dumps(settings))
for rel, txt in sc.get("files", {}).items():
    p = proj / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
for rel, txt in sc.get("home_files", {}).items():
    p = home / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
env.update(sc.get("env", {}))
plog = out / "provider.jsonl"
prov = subprocess.Popen([sys.executable, str(HERE / "fakeprov.py"), str(port)], env={**os.environ, "LOG": str(plog)}, stdout=subprocess.PIPE, text=True)
prov.stdout.readline()
argv = [KIMCHI] + [a.replace("@PROJ@", str(proj)) for a in sc["args"]]
t0 = time.time()
acp = sc.get("acp", False)
p = subprocess.Popen(argv, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=(subprocess.PIPE if acp else open(out / "stdout", "w")), stderr=open(out / "stderr", "w"), text=True, start_new_session=True)
state = {"sid": None}
wlock = threading.Lock()
def send(obj):
    with wlock:
        p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()
def reader():
    # ACP: record stdout with receive time, capture sessionId, auto-allow permission requests
    with open(out / "stdout", "w") as f:
        for line in p.stdout:
            f.write(json.dumps({"t": round(time.time() - t0, 2), "msg": line.rstrip()}) + "\n"); f.flush()
            try: m = json.loads(line)
            except ValueError: continue
            r = m.get("result")
            if isinstance(r, dict) and r.get("sessionId") and not state["sid"]: state["sid"] = r["sessionId"]
            if m.get("method") == "session/request_permission" and "id" in m:
                opts = m["params"].get("options", [])
                pick = next((o["optionId"] for o in opts if o.get("kind", "").startswith("allow")), opts[0]["optionId"] if opts else None)
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": {"outcome": "selected", "optionId": pick}}})
if acp: threading.Thread(target=reader, daemon=True).start()
def feeder():
    previous_send = t0
    for item in sc.get("stdin_lines", []):
        send_at = max(t0 + item["at"], previous_send + item.get("after_previous", 0))
        while time.time() < send_at: time.sleep(0.05)
        marker = item.get("after_request")
        if marker:
            # Provisioning a workflow may outlast its timed cancel/abort input.
            # Establish an active step before testing cancellation of that step.
            while p.poll() is None and time.time() - t0 < sc.get("timeout", 60):
                rows = plog.read_text().splitlines() if plog.exists() else []
                requests = []
                for row in rows:
                    try: requests.append(json.loads(row))
                    except ValueError: pass
                if any(r.get("kind") == "POST" and marker in r.get("first_user_head", "") for r in requests):
                    break
                time.sleep(0.05)
            else:
                state["setup_error"] = f"provider request not ready: {marker}"
                return
        raw = json.dumps(item["line"]).replace("@PROJ@", str(proj))
        if "@SID@" in raw:
            while not state["sid"] and time.time() - t0 < 60: time.sleep(0.05)
            raw = raw.replace("@SID@", state["sid"] or "none")
        try:
            send(json.loads(raw))
            previous_send = time.time()
            with open(out / "stdin.jsonl", "a") as f:
                f.write(json.dumps({"t": previous_send, "line": json.loads(raw)}) + "\n")
        except Exception as e:
            break
    if sc.get("close_stdin", True):
        try: p.stdin.close()
        except Exception: pass
threading.Thread(target=feeder, daemon=True).start()
try:
    rc = p.wait(timeout=sc.get("timeout", 60)); timed_out = False
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM); time.sleep(1)
    try: os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    rc = p.wait(); timed_out = True
time.sleep(sc.get("linger", 1))
prov.terminate()
# keep session files for inspection
sess = sorted(str(x.relative_to(base)) for x in base.rglob("*.jsonl"))
(out / "meta.json").write_text(json.dumps({"argv": argv, "rc": rc, "timed_out": timed_out, "elapsed": round(time.time() - t0, 2), "session_files": sess, "base": str(base), "setup_error": state.get("setup_error")}, indent=1))
print(json.dumps({"rc": rc, "timed_out": timed_out, "elapsed": round(time.time() - t0, 2)}))
print(f"out: {out}")
