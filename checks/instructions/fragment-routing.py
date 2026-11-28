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
    assert memberships == [owner], (reference, [owner], memberships)

# Expected counts are (contract, directory helpers). Each real consumer names
# the scope regression it detects.
for path, expected, regression in [
    (".github/workflows/devenv-test.yml", (1, 0), "devenv test workflow loses its literal scope"),
    ("checks/ai-context/module-eval.nix", (1, 1), "context check loses either side of the split"),
    ("checks/ai-factory/factory-eval.nix", (0, 1), "factory check receives the general contract"),
    ("devenv.nix", (1, 0), "devenv root loses its literal scope"),
    ("devenv.nix.bak", (0, 0), "devenv root scope matches backups"),
    ("lib/ai/app/mkBackendTransform.nix", (1, 1), "backend transform loses either side of the split"),
    ("lib/ai/dir-helpers.nix", (0, 1), "directory ingestion receives the general contract"),
    ("lib/ai/hm-helpers.nix", (1, 0), "home-manager helper loses the devenv contract scope"),
    ("lib/markdown/guards.nix", (1, 0), "markdown guards lose the markdown library scope"),
    ("packages/ai-module/lib/files/default.nix", (1, 0), "engine glob stops descending into files"),
    ("packages/chatgpt-codex/lib/mkCodex.nix", (1, 1), "named runtime factory loses either reference"),
    ("packages/glab/lib/mkGlab.nix", (0, 0), "runtime factory scope widens to MCP factories"),
    ("packages/glab/modules/devenv/default.nix", (1, 0), "devenv module glob narrows to runtimes"),
    ("packages/glab/modules/homeManager/default.nix", (1, 0), "home-manager module glob narrows to runtimes"),
]:
    matches = [
        reference
        for rule in rules.values()
        if any(PurePosixPath(path).full_match(glob) for glob in (rule["matcher"] or ["**"]))
        for reference in rule["references"]
    ]
    actual = (matches.count(contract), matches.count(directory_helpers))
    assert actual == expected, (regression, path, expected, actual)

print("PASS: unique contract/helper sources and representative routing inputs")
