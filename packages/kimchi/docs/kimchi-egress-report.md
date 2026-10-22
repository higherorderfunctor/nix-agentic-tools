## Kimchi egress report

> **Last verified:** 2026-10-21 — the report's network fields come from the
> committed `network` and `environment` facts through `generate.mjs`; `scan.mjs`
> 2.0.0 writes only the fields the facts do not cover;
> `checks.kimchi-egress-report` ties the report to the facts.

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
own: `src/...` for Kimchi, `@earendil-works/...` for pi. The scanner's fields
keep its `kimchi/` and `pi/` labels.

`header.facts` is the release in `sources.json`. It names the facts' release
because `checks.kimchi-extracted` fails when the committed facts are not the
pin's. `header.scan` is the release `scan.mjs` read, and it can trail.

### Why the scanner keeps six fields

The `network` fact is a JavaScript database's, so Go is outside it. It holds URL
literals and host literals that reach a target, and no scheme-less path
literals, so `urlPathLiterals` has no equivalent. Spawned executables are not
network requests to it. `commands` and `dependencies` are not network facts.

### The update cycle

Kimchi's update script runs `generate.mjs` after it regenerates the facts, so
every bump refreshes the fact fields and `checks.kimchi-egress-report` stays
green. It runs from the repository root, as the regenerate command does. The
scanner's fields change only when the operator asks for a scan, because it needs
the release trees. The generator refuses a report that lacks a scanner field,
and an env target with no `environment` row.

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
