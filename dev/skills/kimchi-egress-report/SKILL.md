---
name: kimchi-egress-report
description: >-
  Refresh the committed report of the pinned Kimchi release's network surface,
  commands, resources, and direct dependencies when the operator asks for it.
---

`packages/kimchi/egress-report.json` has two writers, and `header.provenance`
names the one behind each field:

- **The network fact** writes `hosts` and `networkCallSites`, and with the
  environment fact `endpointVariables`. `scripts/generate.mjs` derives them from
  the committed `packages/kimchi/extracted/extracted.json`. Kimchi's update
  script runs it after every bump, and `checks.kimchi-egress-report` fails when
  the report differs from its output. `header.facts` names the release.
- **`scripts/scan.mjs`** writes the fields the fact does not cover: `commands`,
  `dependencies`, `goCallSites`, `goHosts`, `spawnCallSites` and
  `urlPathLiterals`. It needs the release trees, so it runs only when the
  operator requests a scan. `header.scan` names the release it read.

Use one worktree and one pull request per refresh under
`dev/fragments/monorepo/git-workflow.md`.

## 1. The facts

The committed facts are the pinned release's: `checks.kimchi-extracted` fails
otherwise. When they are stale, regenerate them on x86_64-linux, where the
CodeQL engine runs:

```bash
nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate
```

## 2. The scan

Resolve the pinned trees. `kimchi.src` is the patched build tree, whose hash is
not the pin's, so read the extraction sources:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

kimchi_source="$(nix build --no-link --print-out-paths .#kimchi.extractionSources.kimchi)"
pi_source="$(nix build --no-link --print-out-paths .#kimchi.extractionSources.pi)"
typescript_js="$(nix build --no-link --print-out-paths nixpkgs#typescript_5)/lib/node_modules/typescript/lib/typescript.js"

node dev/skills/kimchi-egress-report/scripts/scan.mjs \
  --tree "$kimchi_source" \
  --pi "$pi_source" \
  --sources packages/kimchi/sources.json \
  --typescript "$typescript_js" \
  --out packages/kimchi/egress-report.json
```

Use `nixpkgs#typescript_5`; the unversioned TypeScript package does not provide
the compiler API the scanner uses. Run the worktree's scripts by their
repository path. The installed skill copy is from `main` and may be stale.

## 3. Generate and diff

The scan writes its fields only. The generator adds the fact's fields and needs
no Nix build:

```bash
node dev/skills/kimchi-egress-report/scripts/generate.mjs
treefmt packages/kimchi/egress-report.json
git diff packages/kimchi/egress-report.json
```

Run steps 2 and 3 twice and verify that the report is byte-identical. The report
diff is the review artifact. If a script fails or looks wrong, fix it in the
same pull request. When the scanner changes, also run it against the previously
reported Kimchi and pi versions, and list that scanner-only delta separately in
the pull request body so it is not mistaken for a release change.

Commit the refresh as:

```text
chore(kimchi): refresh egress report for <version>
```

## Known limits

- The fact's limits are in `packages/kimchi/docs/kimchi-codeql-network.md`. In
  short: hosts a literal never names stay invisible, a scheme-less host literal
  appears only when it reaches a call site, and a call site with a literal
  target does not list its runtime-built ones.
- `goHosts`, `goCallSites` and the Go part of `urlPathLiterals` are regex scans
  of `tools/proxy-helper`, which a JavaScript database does not hold. Go
  argument extraction is approximate for nested expressions.
- `urlPathLiterals` has no fact equivalent: it holds path-shaped strings with no
  scheme, which may not be URLs. Kimchi's tree is read by AST and pi's `dist` by
  regex, so pi's quote pairing can drift in minified code. pi-ai is not read.
- `spawnCallSites` matches callee names without import-binding resolution. Its
  entries identify network-capable executables; they do not prove that a
  particular invocation reaches the network.
- Kimchi end-to-end fixtures without `.test.` or `.spec.` in their names are
  scanned. Treat their entries as fixture noise during review.
