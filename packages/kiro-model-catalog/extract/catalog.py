"""Refresh model suggestions from an isolated, authenticated Kiro CLI."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

# Enterprise governance may hide this model from the updater account.
MANUAL_FALLBACK = "claude-fable-5.1"


def model_ids(response):
    rows = response.get("models") if isinstance(response, dict) else None
    if not isinstance(rows, list) or not rows:
        raise ValueError("invalid catalog: expected nonempty models")
    ids = []
    for row in rows:
        value = row.get("model_id") if isinstance(row, dict) else None
        if not isinstance(value, str) or not value or any(c.isspace() for c in value):
            raise ValueError("invalid catalog: expected nonempty model_id without whitespace")
        ids.append(value)
    if len(set(ids)) != len(ids):
        raise ValueError("invalid catalog: duplicate model_id")
    if not any(value != "auto" for value in ids):
        raise ValueError("invalid catalog: no concrete models (authentication may have failed)")
    return sorted(set(ids) | {MANUAL_FALLBACK})


def refresh(executable, destination, timeout=60):
    key = os.environ.get("KIRO_API_KEY")
    if not key or not key.strip():
        raise ValueError("authentication requires KIRO_API_KEY")
    with tempfile.TemporaryDirectory(prefix="kiro-catalog-") as directory:
        root = Path(directory)
        # An allowlist prevents inherited account/configuration overrides from
        # changing which service or identity supplies the catalog.
        env = {name: os.environ[name] for name in (
            "HTTPS_PROXY", "HTTP_PROXY", "NIX_SSL_CERT_FILE", "NO_PROXY",
            "PATH", "SSL_CERT_FILE", "https_proxy", "http_proxy", "no_proxy",
        ) if name in os.environ}
        home = root / "home"
        home.mkdir()
        env["HOME"] = str(home)
        for name in ("XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
            path = home / name.lower()
            path.mkdir()
            env[name] = str(path)
        env["KIRO_API_KEY"] = key
        env["KIRO_DISABLE_TELEMETRY"] = "1"
        env["KIRO_NO_AUTO_UPDATE"] = "1"
        try:
            result = subprocess.run(
                [str(executable), "chat", "--list-models", "--format", "json"],
                cwd=root, env=env, stdin=subprocess.DEVNULL,
                capture_output=True, timeout=timeout, check=False,
            )
        except subprocess.TimeoutExpired:
            raise ValueError("catalog request timed out") from None
        except OSError:
            raise ValueError("catalog CLI could not start") from None
        if result.returncode:
            raise ValueError("catalog request failed; check authentication and service availability")
        try:
            ids = model_ids(json.loads(result.stdout))
        except (UnicodeError, json.JSONDecodeError):
            raise ValueError("invalid catalog: expected JSON") from None
    content = (json.dumps({"models": ids}, indent=2) + "\n").encode()
    if destination.exists() and destination.read_bytes() == content:
        return False
    # A temporary sibling makes replacement atomic on the destination filesystem.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        temporary.chmod(0o644)
        temporary.replace(destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        changed = refresh(args.executable.resolve(), args.destination)
    except (OSError, ValueError) as error:
        # OS diagnostics can contain paths; CLI output and credentials are never logged.
        message = str(error) if isinstance(error, ValueError) else "catalog file could not be updated"
        parser.exit(1, f"kiro-model-catalog: {message}\n")
    print("Kiro model suggestions updated." if changed else "Kiro model suggestions unchanged.")


if __name__ == "__main__":
    main()
