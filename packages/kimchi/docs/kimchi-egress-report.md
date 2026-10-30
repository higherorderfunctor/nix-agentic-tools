## Kimchi egress report

> **Last verified:** 2026-10-29 (commit d5f613ea) — the report's network fields
> come from the `network` and `environment` facts, read through `lib.extracted`,
> by `generate.mjs`; `scan.mjs` 2.0.0 writes only the fields the facts do not
> cover; the drift check compares parsed JSON; regeneration uses installed
> `treefmt`.

`packages/kimchi/egress-report.json` is the review artifact for the pinned
release's network surface. It has two writers, and `header.provenance` names the
writer of each field. Both scripts live in `dev/skills/kimchi-egress-report/`
and share `scripts/report.mjs`, whose `FACT_FIELDS` and `SCAN_FIELDS` are the
one list of who writes what.

### Field provenance

| Field               | Writer         | Source                                                         |
| ------------------- | -------------- | -------------------------------------------------------------- |
| `endpointVariables` | `generate.mjs` | `network` env targets, each joined with its `environment` row  |
| `hosts`             | `generate.mjs` | `network` target hosts and `unattributed` URL literals         |
| `networkCallSites`  | `generate.mjs` | `network.callSites`, sorted                                    |
| `commands`          | `scan.mjs`     | TypeScript AST over the Kimchi and pi trees                    |
| `dependencies`      | `scan.mjs`     | Kimchi's `package.json` and `sources.json`                     |
| `goCallSites`       | `scan.mjs`     | regex over `tools/proxy-helper`                                |
| `goHosts`           | `scan.mjs`     | regex over `tools/proxy-helper`                                |
| `spawnCallSites`    | `scan.mjs`     | TypeScript AST over Kimchi's tree, callee names                |
| `urlPathLiterals`   | `scan.mjs`     | AST over Kimchi's tree, regex over pi's `dist` and the Go tree |

A host's `files` are where its literal sits; its `callSites` are the call sites
it reaches, empty for a literal no call site reads. File labels are the fact's
own: `src/...` for Kimchi, and `@earendil-works/...` or `pi-mcp-adapter/...` for
pi and its adapter. The scanner's fields keep its `kimchi/` and `pi/` labels.

`header.facts` is the release in `sources.json`. It names the facts' release
because `checks.kimchi-extracted` fails when the committed facts are not the
pin's. `header.scan` is the release `scan.mjs` read, and it can trail.

### Refreshing the report

`checks.kimchi-egress-report.passthru.facts` reads the committed facts through
`lib.extracted.get` and `children`. `regenerate.sh` evaluates it with
`nix eval`, runs the generator, then formats with installed `treefmt`. Kimchi's
PR CI producer calls it after fact regeneration and commits its delta with the
facts. The check compares parsed JSON with the committed report and prints a
diff on drift. No generator reads `extracted.json` directly, as required by
`checks.extracted-contract-guard`.

The generator refuses missing scanner fields and env targets without an
`environment` row. Scanner fields change only on an operator-requested scan:
commands, dependencies and spawned executables are outside the network fact; Go
is outside its JavaScript database; scheme-less paths have no fact equivalent.

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
