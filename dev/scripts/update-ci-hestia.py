#!/usr/bin/env python3
"""Move the patched Hestia source and both action refs as one update target."""

import re
import subprocess
import sys
from pathlib import Path

REPO = "Mic92/hestia"
ROOT = Path.cwd()
RECIPE = Path("dev/ci-hestia.nix")
ACTIONS = (
    Path(".github/actions/check-cache/action.yml"),
    Path(".github/workflows/ci.yml"),
)


def run(*argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout.strip()


def replace_one(text, pattern, replacement, path):
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"{path}: expected one match for {pattern!r}, found {count}")
    return updated


def updated_files(files, version, revision, source_hash):
    recipe = files[RECIPE]
    old_version = re.search(r'^  version = "([^"]+)";$', recipe, re.MULTILINE).group(1)
    old_revision = re.search(r'^  rev = "([0-9a-f]{40})";$', recipe, re.MULTILINE).group(1)
    recipe = replace_one(recipe, r'^  version = "[^"]+";$', f'  version = "{version}";', RECIPE)
    recipe = replace_one(recipe, r'^  rev = "[0-9a-f]{40}";$', f'  rev = "{revision}";', RECIPE)
    recipe = replace_one(recipe, r'^    hash = "sha256-[^"]+";$', f'    hash = "{source_hash}";', RECIPE)
    updated = {RECIPE: recipe}
    for path in ACTIONS:
        pattern = rf'(uses: {REPO}(?:/matrix)?@){old_revision}( # v){re.escape(old_version)}$'
        updated[path] = replace_one(files[path], pattern, rf'\g<1>{revision}\g<2>{version}', path)
    return updated


def main():
    gh, git, prefetch, nix = sys.argv[1:]
    tag = run(gh, "api", f"repos/{REPO}/releases/latest", "--jq", ".tag_name")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError(f"unexpected Hestia release tag: {tag!r}")
    refs = run(git, "ls-remote", f"https://github.com/{REPO}.git", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    revisions = dict(line.split("\t", 1)[::-1] for line in refs.splitlines())
    revision = revisions.get(f"refs/tags/{tag}^{{}}", revisions.get(f"refs/tags/{tag}"))
    if revision is None or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"tag {tag} did not resolve to a 40-hex commit")
    base32_hash = run(prefetch, "--unpack", f"https://github.com/{REPO}/archive/{revision}.tar.gz").splitlines()[-1]
    source_hash = run(nix, "hash", "to-sri", "--type", "sha256", base32_hash)
    files = {path: (ROOT / path).read_text() for path in (RECIPE, *ACTIONS)}
    updated = updated_files(files, tag[1:], revision, source_hash)
    for path, content in updated.items():
        (ROOT / path).write_text(content)
    print(f"Hestia {tag} {revision}: recipe and both action refs updated")


if __name__ == "__main__":
    main()
