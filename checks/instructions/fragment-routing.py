"""Check source reach using the generator's actual rule metadata."""

import json
from pathlib import PurePosixPath
import sys


with open(sys.argv[1]) as source:
    rules = json.load(source)

contract = "packages/ai-module/docs/contract.md"
directory_helpers = "dev/fragments/ai-module/dir-helpers.md"

# A source composed into two matching categories reaches the reader twice.
for reference, owner in [
    (contract, "ai-module-contract"),
    (directory_helpers, "ai-dir-helpers"),
]:
    memberships = [
        category
        for category, rule in rules.items()
        for member in rule["references"]
        if member == reference
    ]
    assert memberships == [owner], (reference, memberships)

# Real consumers cover literal paths, backend globs, nested engine paths and
# both sides of the directory-helper split. Adjacent names are negative inputs.
for path, expected_contracts, expected_helpers in [
    (".github/workflows/devenv-test.yml", 1, 0),
    ("checks/ai-context/module-eval.nix", 1, 1),
    ("checks/ai-factory/factory-eval.nix", 0, 1),
    ("checks/glab/module-eval.nix", 1, 0),
    ("devenv.nix", 1, 0),
    ("devenv.nix.bak", 0, 0),
    ("lib/ai/app/mkBackendTransform.nix", 1, 1),
    ("lib/ai/dir-helpers.nix", 0, 1),
    ("lib/ai/hm-helpers.nix", 1, 0),
    ("lib/markdown/guards.nix", 1, 0),
    ("packages/ai-module/lib/files/default.nix", 1, 0),
    ("packages/chatgpt-codex/lib/mkCodex.nix", 1, 1),
    ("packages/claude-code/modules/devenv/default.nix", 1, 0),
    ("packages/claude-code/modules/homeManager/default.nix", 1, 0),
    ("packages/glab/lib/mkGlab.nix", 0, 0),
    ("packages/glab/modules/devenv/default.nix", 1, 0),
    ("packages/glab/modules/homeManager/default.nix", 1, 0),
]:
    matches = [
        reference
        for rule in rules.values()
        if any(PurePosixPath(path).full_match(glob) for glob in rule["matcher"])
        for reference in rule["references"]
    ]
    actual = (matches.count(contract), matches.count(directory_helpers))
    assert actual == (expected_contracts, expected_helpers), (path, actual)

print("PASS: unique contract/helper sources and 17 routing inputs")
