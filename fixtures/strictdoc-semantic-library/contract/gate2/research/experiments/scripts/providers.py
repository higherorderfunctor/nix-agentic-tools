"""Executable acquisition contract controls; harness code, not a public API."""

import copy
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def capture(command):
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=0.2)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    if proc.returncode != 0:
        return {"status": "process-error", "exit": proc.returncode}
    try:
        result = json.loads(proc.stdout)
    except ValueError:
        return {"status": "malformed"}
    if (not isinstance(result, dict) or result.get("complete") is not True
        or not isinstance(result.get("id"), str) or not result["id"]
        or not isinstance(result.get("records"), dict)):
        return {"status": "incomplete-or-invalid"}
    return {"status": "ok", "snapshot": result}


def run():
    rows = []
    provider = [sys.executable, str(Path(__file__).resolve()), "--provider"]
    for mode, expected in [("empty", "ok"), ("protected", "ok"),
                           ("nonzero", "process-error"), ("timeout", "timeout"),
                           ("malformed", "malformed"), ("incomplete", "incomplete-or-invalid"),
                           ("missing_id", "incomplete-or-invalid")]:
        result = capture(provider + [mode])
        assert result["status"] == expected, (mode, result)
        rows.append({"case": mode, **result})
    # Capture creates independent JSON values. Later provider calls cannot
    # retroactively replace an evaluation's captured external input.
    old = capture(provider + ["protected"])["snapshot"]
    new = capture(provider + ["empty"])["snapshot"]
    assert old["id"] != new["id"] and "I0" in old["records"] and not new["records"]
    rows.append({"case": "snapshot_change", "old": old["id"], "new": new["id"]})
    (ROOT / "results" / "providers.json").write_text(json.dumps(rows, indent=2)+"\n")
    print("pass: seven provider status controls and snapshot change")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--provider":
        mode = sys.argv[2]
        if mode == "nonzero":
            sys.exit(7)
        if mode == "timeout":
            import time
            time.sleep(2)
        if mode == "malformed":
            print("{")
        else:
            result = {"complete": mode != "incomplete", "id": mode + "-1", "records": {}}
            if mode == "protected":
                result["records"] = {"I0": {"closed": False}}
            if mode == "missing_id":
                del result["id"]
            print(json.dumps(result))
    else:
        run()
