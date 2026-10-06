#!/usr/bin/env python3
"""mkcache.py <codex-src> <out-models_cache.json> — writes a fresh models_cache.json from the
model catalog bundled in the pinned Codex source (codex-rs/models-manager/models.json).

The original probes used the operator's account-fetched cache. That file carries an account
identity, so it is not committed; the bundled catalog gives the same multi_agent_version per model
(v2: gpt-6.1-sol, gpt-6-astra, gpt-6-sol, gpt-6-luna, gpt-5.6-sol, gpt-5.6-terra; v1: gpt-5.6-luna,
codex-auto-review; none: gpt-5.5; gpt-reserve is absent). Checked 2026-10-05: judge:J1 and
claude:R8 reproduce with this file.
"""
import datetime
import json
import pathlib
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)
src = pathlib.Path(sys.argv[1]) / "codex-rs"
catalog = json.loads((src / "models-manager" / "models.json").read_text())
version = re.search(r'^version = "([^"]+)"', (src / "Cargo.toml").read_text(), re.M)
cache = {
    "fetched_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "etag": None,
    "client_version": version.group(1) if version else None,
    "identity": None,
    "models": catalog["models"],
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(cache, indent=2) + "\n")
