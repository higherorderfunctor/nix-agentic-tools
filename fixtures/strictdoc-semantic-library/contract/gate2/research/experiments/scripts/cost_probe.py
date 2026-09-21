"""Small synthetic cost probe with hard process budgets, not an SLA benchmark."""

import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

from finalists import SELECTOR, cozo, opa, relation, rustworkx

ROOT = Path(__file__).resolve().parents[1]


def data(n, shape, closed):
    nodes = {str(i): {"closed": closed and i == n // 2} for i in range(n)}
    parents = [(i, i - 1 if shape == "deep" else (i - 1) // 3) for i in range(1, n - 1)]
    parents.append((n - 1, 0))
    return {"nodes": nodes, "relations": [relation(str(c), str(p)) for c, p in parents],
            "hierarchy": SELECTOR,
            "queries": [{"id": "query", "origin": str(n - 1), "target": str(n - 2), "mode": "visible"}],
            "snapshot": {"id": "empty", "records": {}}, "projection": {}}


def worker(backend, n, shape):
    evaluate = {"rustworkx": rustworkx, "cozo": cozo, "opa": opa}[backend]
    candidate = data(n, shape, False)
    serialized = json.dumps(candidate)
    times = []
    for _ in range(3):
        start = time.perf_counter()
        assert evaluate(candidate)["query"]
        times.append((time.perf_counter() - start) * 1000)
    # The unchanged query must change when a deep interior closes.
    if shape == "deep":
        candidate["nodes"][str(n // 2)]["closed"] = True
        assert not evaluate(candidate)["query"]
    print(json.dumps({"backend": backend, "nodes": n, "shape": shape,
                      "three_full_runs_ms": times, "median_ms": statistics.median(times),
                      "json_bytes": len(serialized), "deep_boundary_control": shape == "deep"}))


def run():
    rows = []
    for n in [1000, 10000]:
        for shape in ["deep", "wide"]:
            for backend in ["rustworkx", "cozo", "opa"]:
                command = [sys.executable, str(Path(__file__).resolve()), "--worker", backend, str(n), shape]
                try:
                    proc = subprocess.run(command, text=True, capture_output=True, timeout=8)
                    assert proc.returncode == 0, proc.stderr
                    row = json.loads(proc.stdout)
                except subprocess.TimeoutExpired:
                    row = {"backend": backend, "nodes": n, "shape": shape,
                           "status": "8-second process budget exceeded; no timing claim"}
                rows.append(row)
                print(json.dumps(row), flush=True)
                (ROOT / "results" / "cost.json").write_text(json.dumps({
                    "evidence_version": 2, "host": platform.platform(), "python": platform.python_version(),
                    "method": "3 serial full recomputations plus deep closed-boundary control; setup/serialization included by backend, no Scribe/provider/Git; 8-second per-worker process budget",
                    "rows": rows}, indent=2)+"\n")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        worker(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    else:
        run()
