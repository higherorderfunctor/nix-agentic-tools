#!/usr/bin/env python3
# cspell:ignore sdoc
"""Entry point for both invocation shapes.

    python3 -m sdoc_extractors ...                       # as a package
    <runner> dev/scripts/sdoc_extractors/__main__.py ... # as a plain script

The second shape is the one the scribe wrappers use -- they carry an
INTERPRETER and resolve the script at run time -- and running a file inside a
package puts the PACKAGE directory on sys.path rather than its parent, which
breaks every relative import. The bootstrap below re-anchors sys.path on the
parent so the same file works either way.
"""

from __future__ import annotations

import sys
from pathlib import Path

if __package__ in (None, ""):  # invoked as a plain script path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from sdoc_extractors.cli import main
else:
    from .cli import main

if __name__ == "__main__":
    sys.exit(main())
