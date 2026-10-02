---
name: kimchi-egress-report
description: >-
  Refresh the committed report of the pinned Kimchi release's network surface,
  commands, resources, and direct dependencies when the operator asks for it.
---

Refresh `packages/kimchi/egress-report.json` only when the operator requests a
scan. Do not run this on every Kimchi update.

Use one worktree and one pull request per refresh under
`dev/fragments/monorepo/git-workflow.md`. Resolve the pinned inputs from the
flake and source metadata:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

kimchi_source="$(nix build --no-link --print-out-paths .#kimchi.src)"
pi_source="$(nix build --no-link --print-out-paths .#kimchi.extractionSources.pi)"
typescript_js="$(nix build --no-link --print-out-paths nixpkgs#typescript_5)/lib/node_modules/typescript/lib/typescript.js"
```

If the pi attribute changes, find its current attribute in the Kimchi package
definition or resolve the version and URL from `packages/kimchi/sources.json`.
Use `nixpkgs#typescript_5`; the unversioned TypeScript package does not provide
the compiler API this scanner uses.

Run the worktree's scanner by its repository path. The installed skill copy is
from `main` and may be stale:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

node dev/skills/kimchi-egress-report/scripts/scan.mjs \
  --tree "$kimchi_source" \
  --pi "$pi_source" \
  --sources packages/kimchi/sources.json \
  --typescript "$typescript_js" \
  --out packages/kimchi/egress-report.json
```

Run it twice and verify that the report is byte-identical. The report diff is
the review artifact. If the scan fails or looks wrong, fix the scanner in the
same pull request.

When the scanner changes, also run the new scanner against the previously
reported Kimchi and pi versions. List that scanner-only delta separately in the
pull request body so it is not mistaken for a release change.

Commit the refresh as:

```text
chore(kimchi): refresh egress report for <version>
```

## Known limits

- Runtime-built hosts and paths remain invisible when no complete literal
  contains them. Call sites show the local target expression, not its provenance
  through helper layers.
- Call-site matching uses callee names without import-binding resolution. It can
  miss aliases and destructured bare `request` calls; a local function with a
  matched name can produce a false positive.
- Host and path classification is heuristic. Hosts use a curated TLD list; paths
  include path-shaped strings that may not be URLs.
- Go and bundled pi JavaScript use regex literal scans. Go argument extraction
  is approximate for nested expressions. The pi bundle does not produce call
  sites because minification makes callee names unreliable.
- Kimchi end-to-end fixtures without `.test.` or `.spec.` in their names are
  included. Treat their entries as fixture noise during review.
- Spawn entries identify network-capable executables. They do not prove that a
  particular invocation reaches the network.
