#!/usr/bin/env python3
"""One deterministic shared-core operation using Kiro's command-watch protocol."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


OPERATIONS = {"next-wave", "report", "tasks"}
STAGES = {"adjudicate", "dedupe", "finalize", "lens", "refine", "surface"}


def poll(request):
    config = request["config"]
    operation = config["operation"]
    if operation not in OPERATIONS:
        raise ValueError("unknown deterministic operation")
    helper = Path(config["helper"]).resolve(strict=True)
    run_dir = Path(config["run_dir"]).resolve(strict=True)
    args = [sys.executable, str(helper), operation, "--run-dir", str(run_dir), "--arm", config["arm"]]
    if operation == "tasks":
        stage = config["stage"]
        if stage not in STAGES:
            raise ValueError("unknown stage")
        args += ["--stage", stage]
    completed = subprocess.run(args, check=False, capture_output=True, text=True)
    if completed.returncode:
        raise ValueError(f"shared operation refused ({completed.returncode}): {completed.stderr.strip()}")
    payload = json.loads(completed.stdout)
    if operation == "next-wave":
        if not isinstance(payload.get("continue"), bool):
            raise ValueError("next-wave needs boolean continue control")
        control_path = run_dir / "kiro-next-wave.json"
        with tempfile.NamedTemporaryFile(mode="w", dir=run_dir, delete=False) as stream:
            json.dump({"continue": payload["continue"]}, stream)
            stream.write("\n")
            temporary = stream.name
        os.replace(temporary, control_path)
    return {"outcome": "terminal-state", "cursor": None, "payload": json.dumps(payload, sort_keys=True)}


def main():
    try:
        response = poll(json.load(sys.stdin))
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    print(json.dumps(response, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
