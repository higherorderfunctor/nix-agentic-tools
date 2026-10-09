"""Replay the packaged workflow thinking contract without launching a harness."""

import os
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[5]
if package := os.environ.get("KIMCHI_WORKFLOWS_PKG"):
    output = Path(package).resolve()
else:
    result = subprocess.run(
        ["nix", "build", "--offline", "--no-link", "--print-out-paths", ".#kimchi-workflows"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    output = Path(result.stdout.strip().splitlines()[-1])

source = output / "src"
assert "thinking: options.thinking" in (source / "flow/create-agent-step.ts").read_text()
assert "thinking: step.thinking" in (source / "engine/step-runner.ts").read_text()
bridge = (source / "host/pi-agent.ts").read_text()
assert 'args.push("--thinking", request.thinking)' in bridge
assert "pi.setThinkingLevel(thinkingBaseline)" in bridge
assert f'"file:{output}"' in (source / "host/workflow-package.ts").read_text()
assert "@workflowPackage@" not in (source / "host/workflow-package.ts").read_text()
print("PASS packaged workflow thinking dispatch and same-output preparation")
print("Offline source/build contract only; no harness or provider request")
