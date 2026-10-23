"""Every refused metadata key, malformed file and management environment."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

scanner = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    auth = root / "auth"
    auth.mkdir()
    login = auth / "login.json"

    def check(document, allowed, **environment):
        login.write_text(document)
        result = subprocess.run(
            [sys.executable, scanner, str(auth)], cwd=root,
            env={**os.environ, **environment}, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, "metadata scan result differs"
        assert b"private-value" not in result.stdout + result.stderr
        assert b"login.json" not in result.stdout + result.stderr

    clean = {"type": "claude", "access_token": "private-value"}
    for vendor in ("claude", "codex"):
        check(json.dumps({**clean, "type": vendor}), True)
    for key in (
        "cloak", "cloak_cache_user_id", "cloak_mode", "cloak_sensitive_words",
        "cloak_strict_mode", "excluded-models", "excluded_models",
        "model-aliases", "model_aliases", "models", "prefix",
    ):
        check(json.dumps({**clean, key: "private-value"}), False)
        check(json.dumps({**clean, "attributes": {key: "private-value"}}), False)
    for invalid in ("{", "[]", '{"type":"claude","type":"codex"}', '{"type":"kimi"}'):
        check(invalid, False)
    check(json.dumps(clean), False, MANAGEMENT_PASSWORD="private-value")
    (root / ".env").write_text("export MANAGEMENT_PASSWORD=private-value\n")
    check(json.dumps(clean), False)
    (root / ".env").unlink()
    check(json.dumps(clean), True)
print("ok: exact-model auth metadata and management refusal controls")
