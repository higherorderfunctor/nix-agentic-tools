"""judge:J3: print the pinned source's Ferment-only continuation guard.

Set KIMCHI_SRC to an already materialized pinned source to avoid a build.
"""

import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "common"))
import pin

source = Path(os.environ["KIMCHI_SRC"]) if "KIMCHI_SRC" in os.environ else pin.source("kimchi")
path = source / "src/extensions/agents/manager/agent-manager.ts"
lines = path.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("const DEFAULT_MAX_CONTINUATION_RESUMES ="):
        print(f"{path.name}:{i + 1}:{line}")
start = next(i for i, line in enumerate(lines) if "const attemptsForPurpose =" in line)
end = next(i for i in range(start, len(lines)) if "exhausted the cumulative" in lines[i]) - 1
for i in range(start, end):
    print(f"{path.name}:{i + 1}:{lines[i]}")
