#!/usr/bin/env python3
# cspell:ignore sdoc
"""Entry point for both invocation shapes, as sdoc_extractors does it.

    python3 -m sdoc_semantics ...                       # as a package
    <runner> dev/scripts/sdoc_semantics/__main__.py ... # as a plain script

Running a file inside a package puts the PACKAGE directory on sys.path rather
than its parent, which breaks every relative import; the bootstrap re-anchors
sys.path on the parent so one file serves both.
"""

from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):  # invoked as a plain script path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from sdoc_semantics.cli import main
else:
    from .cli import main

if __name__ == "__main__":
    sys.exit(main())
