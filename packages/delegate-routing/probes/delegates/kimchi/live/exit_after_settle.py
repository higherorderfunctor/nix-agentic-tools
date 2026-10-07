"""Does `kimchi -p` exit after `agent_settled`? usage: exit_after_settle.py [<variant>...]

Runs drive.py once per variant: a one-turn `-p --mode json` session against fakeprov.py, with
or without a stdio MCP server (mcpstub.py, which logs its own lifecycle). Prints one line per
variant:

    EXIT <variant> settled=<yes|no> timed_out=<true|false> elapsed=<s> stub=<events> at_kill=<events>

`timed_out=true` with `settled=yes` means the turn finished and the process stayed alive until
drive.py killed it at the scenario timeout. `stub=` lists the MCP server's own log up to that
kill: `none` when it never started; an `eof` or `signal:<NAME>` entry there would mean Kimchi
closed it. What the stub logged once drive.py killed the process group follows in `at_kill=`.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "common"))
import pin  # noqa: E402

TIMEOUT = 12
BASE = ["-p", "--model", "kimchi-dev/fake-a", "--mode", "json"]
USER_MCP = ".config/kimchi/harness/mcp.json"
# variant -> (where the stdio MCP config goes: None / "user" / "project", extra argv, harness settings)
VARIANTS = {
    "control": (None, [], {}),
    "user-stdio": ("user", [], {}),
    "user-stdio-mcpapps-off": ("user", [], {"resources": {"plugins.mcp-apps": False}}),
    "project-stdio-approve": ("project", ["--approve"], {}),
    "project-stdio-default": ("project", [], {}),
}


def main(names):
    out = pin.workdir("kimchi-exit-after-settle")
    out.mkdir(parents=True, exist_ok=True)
    scen = Path(tempfile.mkdtemp(prefix="sc-", dir=out))
    # Resolve the pin once, so each drive.py launch starts at once and its kill time is known.
    env = {**os.environ, "KIMCHI_PKG": str(pin.package("kimchi"))}
    for name in names or VARIANTS:
        where, extra, settings = VARIANTS[name]
        stub_log = out / f"{name}.mcp.jsonl"
        stub_log.unlink(missing_ok=True)
        sc = {"args": BASE + extra + ["--", "go"], "timeout": TIMEOUT, "linger": 0}
        if settings:
            sc["settings"] = settings
        if where:
            mcp = json.dumps({"mcpServers": {"stub": {"type": "stdio", "command": sys.executable,
                                                      "args": [str(HERE / "mcpstub.py"), str(stub_log)]}}})
            sc["home_files" if where == "user" else "files"] = {USER_MCP if where == "user" else ".mcp.json": mcp}
        path = scen / f"{name}.json"
        path.write_text(json.dumps(sc))
        run = out / name
        launched = time.time()
        subprocess.run([sys.executable, str(HERE / "drive.py"), str(path), str(run)], check=True,
                       stdout=subprocess.DEVNULL, env=env)
        kill_at = launched + TIMEOUT - 0.5  # drive.py kills the group at its own start + TIMEOUT
        meta = json.loads((run / "meta.json").read_text())
        settled = any('"type":"agent_settled"' in line.replace(" ", "") for line in (run / "stdout").read_text().splitlines())
        events, at_kill = [], []
        if stub_log.exists():
            for row in map(json.loads, stub_log.read_text().splitlines()):
                label = {"request": row.get("method"), "notification": row.get("method"),
                         "signal": f"signal:{row.get('signal')}"}.get(row["event"], row["event"])
                if row["event"] != "exit":
                    (events if row["t"] < kill_at or not meta["timed_out"] else at_kill).append(label)
        print(f"EXIT {name} settled={'yes' if settled else 'no'} timed_out={str(meta['timed_out']).lower()} "
              f"elapsed={meta['elapsed']} stub={','.join(events) or 'none'} at_kill={','.join(at_kill) or 'none'}", flush=True)
    print(f"out: {out}")


if __name__ == "__main__":
    unknown = [n for n in sys.argv[1:] if n not in VARIANTS]
    if unknown:
        sys.exit(f"unknown variant(s) {unknown}; choose from {list(VARIANTS)}")
    main(sys.argv[1:])
