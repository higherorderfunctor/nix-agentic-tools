"""drive.py removes a LIVE run's scratch key even when the run dies early. usage: scrub_check.py

OFFLINE: the "operator" HOME is a fixture whose config.json holds a sentinel apiKey, and
live_upstream points at a dead local port, so no gateway is contacted and no real key is read.
Two variants interrupt drive.py after it has written the key into the scratch config:

- setup-fail: `setup_sh` exits non-zero (drive.py raises CalledProcessError).
- sigterm: `setup_sh` sleeps and drive.py receives SIGTERM.

Prints, per variant:

    SCRUB <variant> rc=<drive.py exit> key_written=<yes|no> key_files=<files still holding the sentinel>

`key_written=yes` (the fixture shell saw the sentinel in the scratch config) shows the key was on
disk when the run was interrupted; `key_files=0` shows the finally removed every copy.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "common"))
import pin  # noqa: E402

SENTINEL = "SCRUB_SENTINEL_KEY_7f3c"
# setup_sh records whether the scratch config holds the key, then fails or waits for the signal.
SEEN = 'if grep -qF "$SENTINEL" "$BASE/home/.config/kimchi/config.json"; then echo KEY_WRITTEN; fi\n'
VARIANTS = {
    "setup-fail": (SEEN + "exit 3\n", None),
    "sigterm": (SEEN + "sleep 30\n", 3),
}


def main():
    out = pin.workdir("kimchi-scrub-check")
    out.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "KIMCHI_PKG": str(pin.package("kimchi"))}
    operator = Path(tempfile.mkdtemp(prefix="operator-", dir=out))
    (operator / ".config/kimchi").mkdir(parents=True)
    (operator / ".config/kimchi/config.json").write_text(json.dumps({"apiKey": SENTINEL}))
    env.update(HOME=str(operator), SENTINEL=SENTINEL)
    for name, (setup, term_after) in VARIANTS.items():
        sc = out / f"{name}.json"
        sc.write_text(json.dumps({"live_upstream": "http://127.0.0.1:9", "timeout": 20, "setup_sh": setup,
                                  "env": {"SENTINEL": SENTINEL}, "args": ["-p", "--", "go"]}))
        run = out / name
        proc = subprocess.Popen([sys.executable, str(HERE / "drive.py"), str(sc), str(run)], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if term_after is not None:
            time.sleep(term_after)
            proc.send_signal(signal.SIGTERM)
        rc = proc.wait(timeout=60)
        setup_log = run / "setup.log"
        written = setup_log.exists() and "KEY_WRITTEN" in setup_log.read_text()
        leaked = [p for p in run.rglob("*") if p.is_file() and not p.is_symlink()
                  and SENTINEL.encode() in p.read_bytes()]
        print(f"SCRUB {name} rc={rc} key_written={'yes' if written else 'no'} key_files={len(leaked)}", flush=True)
        for p in leaked:
            print(f"  leaked: {p.relative_to(run)}")
    print(f"out: {out}")


if __name__ == "__main__":
    main()
