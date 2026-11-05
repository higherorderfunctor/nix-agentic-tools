## Kimchi egress report

> **Last verified:** 2026-11-03 — the producer-boundary fixture checks guard
> joins, explicit absence and preservation of legacy report fields. Scripts in
> `packages/kimchi/extract/egress/` consume `egressScan`, `environment`,
> `network`, `regionRegistry`, `requestCallers`, `requestGuards` and
> `resourceDefinitions` through `lib.extracted`. The extraction runs `scan.mjs`
> 2.0.0 on the original pinned Kimchi and pi trees. QL compilation, fixture
> results and complete release regeneration remain CI checks; PR CI regenerates
> the facts and report together.

`packages/kimchi/egress-report.json` is the review artifact for the pinned
release's network surface. `generate.mjs` writes the complete report from facts.
`header.provenance` names the producer of each field: the CodeQL facts or
`scan.mjs`, whose output is the static x86_64-linux `egressScan` fact. Both
scripts live in `packages/kimchi/extract/egress/` and share `report.mjs`, whose
`FACT_FIELDS` and `SCAN_FIELDS` are the one list of field ownership.

### Field provenance

| Field                 | Producer       | Source                                                              |
| --------------------- | -------------- | ------------------------------------------------------------------- |
| `endpointVariables`   | `generate.mjs` | `network` env targets, each joined with its `environment` row       |
| `hosts`               | `generate.mjs` | `network` target hosts and `unattributed` URL literals              |
| `networkCallSites`    | `generate.mjs` | `network.callSites`, sorted                                         |
| `regionRegistry`      | `generate.mjs` | `regionRegistry` exported fields and default, with locations        |
| `requestCallers`      | `generate.mjs` | `requestCallers` occurrence edges and stop boundaries, sorted       |
| `requestGuards`       | `generate.mjs` | `requestGuards` joined to each `network.callSites` row              |
| `resourceDefinitions` | `generate.mjs` | `resourceDefinitions` static ids, defaults and restart declarations |
| `commands`            | `scan.mjs`     | TypeScript AST over the Kimchi and pi trees                         |
| `dependencies`        | `scan.mjs`     | Kimchi's `package.json` and `sources.json`                          |
| `goCallSites`         | `scan.mjs`     | regex over `tools/proxy-helper`                                     |
| `goHosts`             | `scan.mjs`     | regex over `tools/proxy-helper`                                     |
| `spawnCallSites`      | `scan.mjs`     | TypeScript AST over Kimchi's tree, callee names                     |
| `urlPathLiterals`     | `scan.mjs`     | AST over Kimchi's tree, regex over pi's `dist` and the Go tree      |

A host's `files` are where its literal sits; its `callSites` are the call sites
it reaches, empty for a literal no call site reads. File labels are the fact's
own: `src/...` for Kimchi, and `@earendil-works/...` or `pi-mcp-adapter/...` for
pi and its adapter. The scanner's fields keep its `kimchi/` and `pi/` labels.

The declaration and guard CodeQL fields come through `lib.extracted` in the same
fact input. `resourceDefinitions` preserves declared defaults and restart
requirements; missing restart declarations are null. `regionRegistry` preserves
every modeled region field and the default-region declaration with source
locations. Neither field describes effective enablement or override precedence.

`requestCallers` is a separate list of Kimchi request occurrences, including
columns, enclosing functions, caller/callback edges and explicit stop
boundaries. It preserves the fact rows and sorts them deterministically.
`header.provenance.requestCallers` labels them as reachability evidence only,
not conditions. A registration, store, recursion, depth, unreferenced or
unresolved boundary is never rendered as "no callers" or "dead". The existing
report fields retain their exact values and shapes. See
[request callers](kimchi-codeql-callers.md) for row fields, binding resolution,
the four-edge limit and unsupported property or mutable-state flow. CI
regenerates the fact and report together; neither projection is hand-edited.

`requestGuards` is a separate list of network sites with `guards` and `status`;
the existing `networkCallSites` shape and values are unchanged. Each guard names
its exact call column, guard location, source kind/key, required source
truthiness, whole-condition outcome and `intraprocedural` scope. These are
necessary local conditions, not sufficient conditions for execution. A grouped
network line can hold multiple calls: evidence applies only to the listed
columns. An empty list is rendered as `no modeled local guard`, never as enabled
or always on. Recognized forms and unresolved cases are documented in
`packages/kimchi/docs/kimchi-codeql-guards.md`. All three fields have entries in
`header.provenance`; legacy fields retain their shape and values. CI regenerates
the committed facts and report together after compiling and running the queries.

`header.facts` is the release in `sources.json`. It names the facts' release
because `checks.kimchi-extracted` fails when the committed facts are not the
pin's. `header.scan` is the release `scan.mjs` read in that same extraction. The
scanner verifies the Kimchi and pi NAR hashes, pi's version and Kimchi's direct
pi dependency against `sources.json` before producing `egressScan`.

### Refreshing the report

`checks.kimchi-egress-report.passthru.facts` reads the committed facts through
`lib.extracted.get` and `children`. `regenerate.sh` evaluates it with
`nix eval`, runs the generator, then formats with installed `treefmt`. Kimchi's
PR CI producer calls it after fact regeneration and commits its delta with the
facts. Before writing the delta patch, the producer builds
`checks.<system>.kimchi-egress-report`; a failure prevents artifact upload and
commit-back. The extracted-facts check also gates upload. The report check
compares parsed JSON with the committed report and prints a diff and the changed
field names on drift, including `header.scan`, with the
`packages/kimchi/extract/egress/regenerate.sh` fix command. No generator reads
`extracted.json` directly, as required by `checks.extracted-contract-guard`.

PR CI regenerates and commits both. To reproduce it locally on x86_64-linux,
where the CodeQL engine runs, regenerate the facts first and then the report
from the repository root, with Node and treefmt installed. `regenerate.sh`
itself builds nothing; it reads the committed facts:

```bash
nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate
packages/kimchi/extract/egress/regenerate.sh
git diff packages/kimchi/egress-report.json
```

The report diff is the review artifact. When the scanner changes, review its
`egressScan` delta and distinguish it from release changes in the pull request
body.

The extracted-facts planner selects Kimchi when its extraction derivation
changes, including edits to `scan.mjs`. Kimchi's package also declares
`passthru.extractedSelectionInput`, a fileset containing
`packages/kimchi/extract/egress/generate.mjs`, `report.mjs`, `regenerate.sh` and
`checks/references/kimchi-egress-report.nix`, so changes to report generation
select Kimchi even when extraction is unchanged. This input excludes docs, other
owners' files and committed `extracted.json` and `egress-report.json`; CI's
commit-back alone does not reselect the owner.

The same selection input includes `surface-judgments.json`, the judgment
packet/check scripts, Nix check and fixtures. The
[surface judgment mechanism](kimchi-surface-judgments.md) checks fingerprints
for the declared hosted LLM gateways after report validation and before patch
creation. A failure prevents facts upload while preserving a separate
`kimchi-judgments-${SYSTEM}` diagnostic artifact. CI never commits verdicts or
packet artifacts; its allowed patch paths remain the extracted facts and this
report. An unknown judgment is classified evidence, without becoming support for
its claim.

The generator refuses a missing `egressScan`, missing scanner fields and env
targets without an `environment` row. It reads no fields from the committed
report. The Kimchi extraction runs the scanner with pinned Node and TypeScript
on `extractionSources.kimchi` and `extractionSources.pi`, the original trees
before build or CodeQL patches. `kimchi.src` and the assembled CodeQL tree
contain patches and cannot replace those scanner inputs. The CodeQL engine runs
on x86_64-linux. The extraction sandbox supplies Nix with `nix-command` enabled
for `nix hash path`.

CI keeps scanner fields fresh through `egressScan`: commands, dependencies,
spawned executables, Go sites and hosts, path literals and `header.scan` are
regenerated with the CodeQL facts. `checks.kimchi-extracted` detects
scanner-fact drift; `checks.kimchi-egress-report` detects any report-field
drift. Commands, dependencies and spawned executables are outside the network
fact; Go is outside its JavaScript database; scheme-less paths have no network
fact equivalent.

### What the regex scanner reported that the fact does not

Measured on 2026-10-21 by running `scan.mjs` 1.0.0 over 1.17.0. The regex found
27 hosts the fact does not hold. 12 are AWS partition DNS suffixes in the
Bedrock chunk, from which the SDK builds endpoints at runtime, so no literal
names a whole host. The other 15 are not hosts Kimchi requests: user-agent
vendor names, a provider display name, `baseUrl.includes(...)` provider tests, a
prompt placeholder, an SVG namespace, `TERM_PROGRAM`, the ACP `_meta` key
`kimchi.dev`, the URL validator's metadata deny list, `gitRemote` and token
matching on `gitlab.com`, and test fixtures. The fact found `mistral.ai`, which
the regex's quote pairing missed, and 13 Kimchi call sites the callee-name match
missed (`fetchImpl`, `fetchFn`, `globalThis.fetch`, `new WS`, undici's proxy
agent), besides every pi call site.

### Known limits

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
