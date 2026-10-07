"""Run one offline Kimchi scenario against fakeprov.py. usage: drive.py <scenario.json> [<outdir>]
<outdir> defaults to <work>/<scenario name>; work = $PROBE_OUT/kimchi or a fresh temp dir.
Binaries: the repository's pinned kimchi and kimchi-workflows (KIMCHI_PKG / KIMCHI_WORKFLOWS_PKG override).

scenario keys: args (kimchi argv after the binary), stdin_lines (RPC/ACP: [{"at": sec, "line": obj}]),
after_request (optional stdin-line marker: wait for its first fake-provider POST before sending),
after_previous (optional stdin-line delay in seconds after the preceding send),
timeout (sec), tty (bool: TUI under a pseudo-terminal; stdin_lines are raw keystroke strings), env (extra env), workflows (bool: link kimchi-workflows ext), files ({relpath: text}
written under the project dir), home_files ({relpath: text} under HOME; @PROJ@ in either text is the
project path), setup_sh (strict-mode bash run in the scratch base before the scenario with $PROJ and
$BASE set; setup.log), config (extra non-secret config.json keys, e.g. onboarding state for a TUI run), settings (harness settings.json), prov_env (extra env for fakeprov.py), pre_args (list
of argv lists run with the same binary, env and cwd before the scenario; pre.log), full_wire (bool: the
provider also writes every request body verbatim to <outdir>/wire.jsonl), live_upstream (URL: LIVE run
through recproxy.py to the real gateway, with the operator's apiKey leaf copied into the scratch config).
Outputs: <outdir>/{provider.jsonl,stdout,stderr,meta.json[,wire.jsonl,pre.log,setup.log]}
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
live = sc.get("live_upstream")
if live:
    # LIVE: the operator's real key, copied as the apiKey leaf only (jq, umask 077), never printed.
    old_umask = os.umask(0o077)
    key = subprocess.check_output(["jq", "-r", ".apiKey", str(Path(os.environ["HOME"]) / ".config/kimchi/config.json")], text=True).strip()
else:
    key = "fake-key"
cfg = json.dumps({**sc.get("config", {}), "llmEndpoint": f"http://127.0.0.1:{port}", "apiKey": key, "telemetry": {"enabled": False}})
del key
for d in (home / ".config/kimchi", base / "config/kimchi"):
    d.mkdir(parents=True, exist_ok=True); (d / "config.json").write_text(cfg); (d / "config.json").chmod(0o600)
del cfg
if live:
    os.umask(old_umask)
settings = {}
if sc.get("workflows"):
    (harness / "extensions").mkdir(); (harness / "extensions/workflows").symlink_to(WF, target_is_directory=True)
    settings["packages"] = ["extensions/workflows"]
settings.update(sc.get("settings", {}))
if settings: (harness / "settings.json").write_text(json.dumps(settings))
for rel, txt in sc.get("files", {}).items():
    p = proj / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt.replace("@PROJ@", str(proj)))
for rel, txt in sc.get("home_files", {}).items():
    p = home / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt.replace("@PROJ@", str(proj)))
env.update(sc.get("env", {}))
if sc.get("setup_sh"):
    # Fixture shell (strict mode) run in the scratch base before the scenario with $PROJ and $BASE set,
    # e.g. a disposable repo whose linked worktree is the project dir; setup.log; a failure aborts the run.
    strict = "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n"
    with open(out / "setup.log", "w") as f:
        subprocess.run(["bash", "-c", strict + sc["setup_sh"]], cwd=base, env={**env, "PROJ": str(proj), "BASE": str(base)}, stdout=f, stderr=f, check=True, timeout=60)
plog = out / "provider.jsonl"
penv = {**os.environ, "LOG": str(plog)}
if sc.get("full_wire"): penv["WIRE"] = str(out / "wire.jsonl")
penv.update(sc.get("prov_env", {}))
if live: penv["UPSTREAM"] = live
prov = subprocess.Popen([sys.executable, str(HERE / ("recproxy.py" if live else "fakeprov.py")), str(port)], env=penv, stdout=subprocess.PIPE, text=True)
prov.stdout.readline()
for pre in sc.get("pre_args", []):
    # Setup invocations of the same binary (e.g. memory-import) before the scenario run; output in pre.log.
    with open(out / "pre.log", "a") as f:
        subprocess.run([KIMCHI] + [a.replace("@PROJ@", str(proj)) for a in pre], cwd=proj, env=env, stdout=f, stderr=f, timeout=60)
argv = [KIMCHI] + [a.replace("@PROJ@", str(proj)) for a in sc["args"]]
t0 = time.time()
acp = sc.get("acp", False)
tty = sc.get("tty", False)
if tty:
    # TUI: the binary gets a pseudo-terminal; stdin_lines carry raw keystroke strings ("\r" submits).
    import fcntl, pty, struct, termios
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    p = subprocess.Popen(argv, cwd=proj, env={**env, "TERM": "xterm-256color"}, stdin=slave, stdout=slave, stderr=open(out / "stderr", "w"), start_new_session=True)
    os.close(slave)
else:
    p = subprocess.Popen(argv, cwd=proj, env=env, stdin=subprocess.PIPE, stdout=(subprocess.PIPE if acp else open(out / "stdout", "w")), stderr=open(out / "stderr", "w"), text=True, start_new_session=True)
state = {"sid": None}
wlock = threading.Lock()
def send(obj):
    with wlock:
        if tty:
            os.write(master, obj.encode()); return
        p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()
def tty_reader():
    # TUI: drain the terminal (a full pty blocks the UI) into stdout, raw.
    with open(out / "stdout", "wb") as f:
        while True:
            try: data = os.read(master, 65536)
            except OSError: return
            if not data: return
            f.write(data); f.flush()
if tty: threading.Thread(target=tty_reader, daemon=True).start()
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
    if sc.get("close_stdin", True) and not tty:
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
if live:
    # LIVE: remove every scratch file that can hold the real key (config.json, Pi's synced auth.json).
    for d in (home / ".config/kimchi", base / "config/kimchi"):
        for f in [d / "config.json", *d.rglob("auth.json")]:
            f.unlink(missing_ok=True)
# keep session files for inspection
sess = sorted(str(x.relative_to(base)) for x in base.rglob("*.jsonl"))
(out / "meta.json").write_text(json.dumps({"argv": argv, "rc": rc, "timed_out": timed_out, "elapsed": round(time.time() - t0, 2), "session_files": sess, "base": str(base), "setup_error": state.get("setup_error")}, indent=1))
print(json.dumps({"rc": rc, "timed_out": timed_out, "elapsed": round(time.time() - t0, 2)}))
print(f"out: {out}")
