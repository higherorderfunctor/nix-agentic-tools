"""Resolve a HuggingFace revision, verify its artifact, then replace both pins."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote
from urllib.request import urlopen


def update(args):
    recipe = Path(args.recipe)
    original = recipe.read_text()
    # Read both anchors before any network access or write. Ambiguous recipes
    # must fail rather than update a second model or only one half of a pin.
    patterns = {key: rf'({key} = ")([0-9a-f]{{{length}}})(";)' for key, length in
                [("rev", 40), ("sha256Hex", 64)]}
    current = {}
    for key, pattern in patterns.items():
        matches = re.findall(pattern, original)
        if len(matches) != 1:
            raise ValueError(f"Expected one {key} assignment in {recipe}")
        current[key] = matches[0][1]

    model_id = f"{quote(args.publisher, safe='')}/{quote(args.repo, safe='')}"
    revision = quote(args.revision, safe="")
    url = f"https://huggingface.co/api/models/{model_id}/revision/{revision}?blobs=true"
    with urlopen(url, timeout=60) as response:
        metadata = json.load(response)
    rev = metadata["sha"]
    entries = [entry for entry in metadata["siblings"] if entry["rfilename"] == args.file]
    if len(entries) != 1:
        raise ValueError(f"Expected one artifact named {args.file}")
    lfs = entries[0].get("lfs")
    digest = lfs.get("sha256") if isinstance(lfs, dict) else None
    if not isinstance(digest, str):
        raise ValueError("Artifact has no LFS SHA-256; non-LFS models are unsupported")
    if not re.fullmatch(r"[0-9a-f]{40}", rev) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid commit or LFS digest from HuggingFace")
    candidate = {"rev": rev, "sha256Hex": digest}
    if candidate == current:
        print(f"Already pinned to {rev}")
        return

    # Verify actual bytes before publishing either pin. Nix can reuse a verified
    # store object; the LFS pointer alone is never treated as a successful fetch.
    sri = "sha256-" + base64.b64encode(bytes.fromhex(digest)).decode("ascii")
    artifact = f"https://huggingface.co/{model_id}/resolve/{rev}/{quote(args.file, safe='/')}"
    subprocess.run([args.nix, "store", "prefetch-file", "--json", "--name",
                    Path(args.file).name.lower(), "--expected-hash", sri, artifact], check=True)
    updated = original
    for key, value in candidate.items():
        updated = re.sub(patterns[key], lambda match: match[1] + value + match[3], updated)
    # Keep rev + digest atomic, including on failures. Never overwrite a recipe
    # another editor changed while the large artifact was downloading.
    if recipe.read_text() != original:
        raise RuntimeError("Recipe changed during prefetch")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=recipe.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(updated)
        temporary.chmod(recipe.stat().st_mode)
        os.replace(temporary, recipe)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Updated {args.file}: {current['rev']} -> {rev}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True)
    parser.add_argument("--nix", required=True)
    parser.add_argument("--publisher", required=True)
    parser.add_argument("--recipe", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--revision", default="main")
    update(parser.parse_args())


if __name__ == "__main__":
    main()
