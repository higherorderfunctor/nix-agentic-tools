"""Shared handling of files fetched by actions/download-artifact."""

from pathlib import Path


def downloaded(directory, filename):
    """Every `filename` a `pattern` download of actions/download-artifact left in `directory`.

    Since v5 the action extracts a pattern that matches exactly ONE artifact
    straight into `directory`, and two or more into `directory/<artifact-name>/`.
    No input forces the per-artifact directory, so readers accept both layouts.
    """
    return sorted(Path(directory).glob(f"*/{filename}")) + sorted(Path(directory).glob(filename))
