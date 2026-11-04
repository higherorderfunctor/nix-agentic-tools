---
name: kimchi-egress-report
description: >-
  Refresh the committed report of the pinned Kimchi release's network surface,
  commands, resources, and direct dependencies when the operator asks for it.
---

`packages/kimchi/egress-report.json` combines two sources:

- `scripts/generate.mjs` derives `hosts`, `networkCallSites` and
  `endpointVariables` from the committed network and environment facts through
  `lib.extracted`. PR CI runs it after Kimchi fact regeneration; the drift check
  compares parsed JSON. `header.facts` names the release.
- The Kimchi extraction runs `scripts/scan.mjs` on the original pinned
  `extractionSources.kimchi` and `.pi` trees with pinned Node and TypeScript.
  Its static x86_64-linux `egressScan` fact holds commands, dependencies, Go
  sites and hosts, spawned executables, path literals and `header.scan`.
  `generate.mjs` reads it through `lib.extracted`; CI keeps these fields fresh
  alongside the network and environment fields. `header.provenance` names each
  field's producer.

Use one worktree and pull request per refresh.

## 1. The facts

The committed facts, including `egressScan`, are the pinned release's:
`checks.kimchi-extracted` fails otherwise. When they are stale, regenerate them
on x86_64-linux, where the CodeQL engine runs:

```bash
nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate
```

Extraction runs the scanner before merging `egressScan` beside the CodeQL facts.
It verifies both original tree hashes, pi's version and Kimchi's direct pi
dependency against `packages/kimchi/sources.json`. `kimchi.src` and the
assembled CodeQL tree contain patches and cannot replace those scanner inputs.
PR CI regenerates the facts and report in one commit-back delta.

## 2. Generate and diff

`regenerate.sh` evaluates `checks.<system>.kimchi-egress-report.passthru.facts`
with `nix eval`, which builds nothing, runs `generate.mjs` over all three facts,
and formats the complete report with installed `treefmt`. Run the worktree's
script by its repository path; the installed skill copy is from `main` and may
be stale.

```bash
dev/skills/kimchi-egress-report/scripts/regenerate.sh
git diff packages/kimchi/egress-report.json
```

Run step 2 twice and verify that the report is byte-identical. The report diff
is the review artifact. If a script fails or looks wrong, fix it in the same
pull request. When the scanner changes, review its `egressScan` delta and
distinguish it from release changes in the pull request body.

Commit the refresh as:

```text
chore(kimchi): refresh egress report for <version>
```

## Known limits

- The network fact's limits are in
  `packages/kimchi/docs/kimchi-codeql-network.md`. In short: hosts a literal
  never names stay invisible, a scheme-less host literal appears only when it
  reaches a call site, and a call site with a literal target does not list its
  runtime-built ones.
- `goHosts`, `goCallSites` and the Go part of `urlPathLiterals` are regex scans
  of `tools/proxy-helper`, which a JavaScript database does not hold. Go
  argument extraction is approximate for nested expressions.
- `urlPathLiterals` has no network fact equivalent: it holds path-shaped strings
  with no scheme, which may not be URLs. Kimchi's tree is read by AST and pi's
  `dist` by regex, so pi's quote pairing can drift in minified code. pi-ai is
  not read.
- `spawnCallSites` matches callee names without import-binding resolution. Its
  entries identify network-capable executables; they do not prove that a
  particular invocation reaches the network.
- Kimchi end-to-end fixtures without `.test.` or `.spec.` in their names are
  scanned. Treat their entries as fixture noise during review.
