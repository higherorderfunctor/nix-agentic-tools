"""Bounded reproduction of an independent memory read behind an active writer."""

import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if len(sys.argv) > 1:
    from cozo_embedded import CozoDbPy
    db = CozoDbPy("mem", "", "{}")
    db.run_script(":create value {id: Int => n: Int}", {}, False)
    db.run_script("?[id,n] <- [[1,10]] :put value {id => n}", {}, False)
    tx = db.multi_transact(True)
    tx.run_script("?[id,n] <- [[1,20]] :put value {id => n}", {})
    print("write transaction staged; next call is independent read", flush=True)
    db.run_script("?[id,n] := *value{id,n}", {}, True)
    print("read returned", flush=True)
    tx.abort()
else:
    try:
        proc = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--worker"],
                              capture_output=True, text=True, timeout=3)
        raise AssertionError((proc.returncode, proc.stdout, proc.stderr))
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout.decode() if isinstance(exc.stdout, bytes) else exc.stdout
        assert "next call is independent read" in output
        result = {"engine": "Cozo 0.7.6 mem", "status": "read blocked beyond 3-second process budget",
                  "stdout": output, "termination": "subprocess.run killed and waited for isolated worker"}
        (ROOT / "results/cozo-lock.json").write_text(json.dumps(result, indent=2)+"\n")
        print(json.dumps(result, indent=2))
