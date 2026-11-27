"""Render ai.kimchi.projectTrust as the trust.json Kimchi will match.

pi 1.3.0 looks a decision up under realpath(cwd), then under each parent in
turn (findNearestTrustEntry, dist/core/trust-manager.js:21-34), and reads the
file's keys verbatim (readTrustFile, :71-94). A declared key that reaches its
directory through a symlink would therefore never match. Canonicalizing needs
the filesystem, so it happens here, when the writer runs, and not at
evaluation.

os.path.realpath resolves the existing prefix and keeps a missing tail, so a
project that does not exist yet is still declared. Two keys that resolve to one
directory with different decisions fail the writer: either answer would
silently discard the other.
"""

import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    declared = json.load(handle)

rendered: dict[str, bool] = {}
declared_as: dict[str, str] = {}
for key, decision in sorted(declared.items()):
    canonical = os.path.realpath(key)
    if canonical in rendered and rendered[canonical] != decision:
        sys.exit(
            f"ai.kimchi.projectTrust: {declared_as[canonical]!r} and {key!r} both "
            f"resolve to {canonical!r} but declare different decisions"
        )
    rendered[canonical] = decision
    declared_as.setdefault(canonical, key)

json.dump(rendered, sys.stdout)
