"""Pre-start refusal of auth-file model rewrites; never print credential data."""
import json
import os
from pathlib import Path
import sys


def permitted(value):
    if isinstance(value, list):
        return all(map(permitted, value))
    if not isinstance(value, dict):
        return True
    refused = {
        "prefix", "model_aliases", "model-aliases", "models",
        "excluded_models", "excluded-models", "cloak", "cloak_mode",
        "cloak_strict_mode", "cloak_sensitive_words", "cloak_cache_user_id",
    }
    return not refused.intersection(value) and all(map(permitted, value.values()))


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


try:
    # CPA loads .env itself after this scan. Refuse the file so dotenv's
    # MANAGEMENT_PASSWORD cannot enable management behind our environment check.
    if "MANAGEMENT_PASSWORD" in os.environ or Path(".env").exists():
        raise ValueError()
    for path in Path(sys.argv[1]).rglob("*.json"):
        document = json.loads(path.read_text(), object_pairs_hook=unique)
        if not isinstance(document, dict) or document.get("type") not in {"claude", "codex"} or not permitted(document):
            raise ValueError()
except (OSError, ValueError):
    sys.exit("CPA exactModels pre-start refused environment or auth metadata")
