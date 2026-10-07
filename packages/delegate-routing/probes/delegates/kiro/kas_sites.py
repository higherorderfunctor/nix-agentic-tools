#!/usr/bin/env python3
"""Count literal sites in the pinned KAS bundle and print a short excerpt of each.

usage: python3 kas_sites.py <literal> [<literal> ...]

Reads `$KIRO_BUNDLES/kas.js` when KIRO_BUNDLES is set; otherwise extracts it with
bundles.py (hash-checked against the pinned binary) into a temporary directory
that is removed afterwards. Prints `<count> <literal>` per literal, then one
`  @<offset> …<context>…` line per site (at most 8). Plain substring search, so
the minified identifiers around each site belong to this exact bundle.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CONTEXT = 120
MAX_SITES = 8


def report(src, literals):
    for literal in literals:
        sites, start = [], src.find(literal)
        while start != -1:
            sites.append(start)
            start = src.find(literal, start + 1)
        print(f"{len(sites)} {literal}")
        for site in sites[:MAX_SITES]:
            excerpt = src[max(0, site - CONTEXT) : site + len(literal) + CONTEXT].replace("\n", " ")
            print(f"  @{site} …{excerpt}…")


def main(literals):
    if not literals:
        sys.exit(__doc__)
    bundles = os.environ.get("KIRO_BUNDLES")
    if bundles:
        report((pathlib.Path(bundles) / "kas.js").read_text(encoding="utf-8"), literals)
        return
    with tempfile.TemporaryDirectory(prefix="kas-sites-") as tmp:
        subprocess.run([sys.executable, str(HERE / "bundles.py"), tmp], check=True, stdout=subprocess.DEVNULL)
        report((pathlib.Path(tmp) / "kas.js").read_text(encoding="utf-8"), literals)


main(sys.argv[1:])
