from __future__ import annotations

import hashlib
import json
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Any

from semble.nix_config import CONFIG

CUSTOMIZATION_FINGERPRINT = hashlib.sha256(
    json.dumps(
        {"grammars": CONFIG["grammars"], "pathMappings": CONFIG["pathMappings"]},
        sort_keys=True,
    ).encode()
).hexdigest()
# In match order; the first matching pattern wins. A None language means
# line chunking, with no parser lookup.
_MAPPINGS: list[dict[str, Any]] = CONFIG["pathMappings"]


def find_mapping(file_path: Path, root: Path | None = None) -> dict[str, Any] | None:
    try:
        relative = file_path.relative_to(root).as_posix() if root is not None else file_path.as_posix()
    except ValueError:
        relative = file_path.as_posix()

    for mapping in _MAPPINGS:
        pattern = mapping["pattern"]
        candidate = relative if "/" in pattern else file_path.name
        if fnmatchcase(candidate, pattern):
            return mapping
    return None


def get_mapped_content(file_path: Path, root: Path) -> str | None:
    mapping = find_mapping(file_path, root)
    return None if mapping is None else mapping["content"]
