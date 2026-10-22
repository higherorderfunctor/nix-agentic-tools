---
name: kimchi-egress-report
description: >-
  Refresh the committed report of the pinned Kimchi release's network surface,
  commands, resources, and direct dependencies when the operator asks for it.
---

`packages/kimchi/egress-report.json` combines two sources:

- `scripts/generate.mjs` derives `hosts`, `networkCallSites` and
  `endpointVariables` from the committed network and environment facts through
  `lib.extracted`. Kimchi updates run it automatically; the drift check compares
  parsed JSON. `header.facts` names the release.
- `scripts/scan.mjs` reads release trees for commands, dependencies, Go sites
  and hosts, spawned executables and path literals. Run it only on operator
  request. `header.scan` names its release; `header.provenance` names each
  field's writer.

Use one worktree and pull request per refresh.

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

The scan writes its fields only. `regenerate.sh` adds the facts' fields. It
evaluates `checks.<system>.kimchi-egress-report.passthru.facts` with `nix eval`,
which builds nothing, runs `generate.mjs` over the result, and formats with
installed `treefmt`:

```bash
dev/skills/kimchi-egress-report/scripts/regenerate.sh
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
