"""Read the store-backed runtime configuration once for all Semble modules."""

import json
import os
from pathlib import Path

CONFIG = json.loads(Path(os.environ["SEMBLE_NIX_CONFIG"]).read_text())
