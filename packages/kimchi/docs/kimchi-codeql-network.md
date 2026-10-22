## Kimchi network fact

> **Last verified:** 2026-10-22 — Kimchi 1.17.2; `network` is measured on
> x86_64-linux by `ql/network` with the `ql/models/{sdk,undici}` packs through
> `runQueries`; a modeled request is an invocation of its row's own callee and
> takes its library from that row; a host constant reaches a `hostname` by value
> flow; the fixture's minified chunk is one the extractor skips without the
> flag.
>
> **Settled — do not relitigate.** Each was measured on the 2.27.3 bundle and
> rejected:
>
> - **A `byFieldName` join** pairing each unreached `baseUrl` literal with every
>   SDK call site whose target reads `baseUrl`. It recovered 35 of pi's 71
>   catalog hosts, as a cross product: 47 literals by 6 call sites, 288 rows.
> - **A typeModel for esbuild's `__require`.** A models-as-data path starts from
>   a package or `global`, and `__require` is a module-local variable.

### The pipeline

`lib/network.nix` builds the query pack and the two model packs, runs them on
the release database with `codeql.runQueries`, and reshapes the result with
`lib/network.jq`. On x86_64-linux, the kimchi package's `passthru.extracted`
adds it to `extract.mjs`'s output as `network`. Every CodeQL fact joins there,
from `codeqlFacts`. Other hosts carry no CodeQL facts, and the declaration lists
x86_64-linux only. `extractedRules.results.network.entries` is the fact. The
regenerate command builds the database and runs the queries, so kimchi's update
script now does too on update.yml's runner, with no check cache: the engine
customization, the database, the pack compile (1m54s on CI) and an evaluation
with `--ram=8192` (53.8 s).

```text
{callSites: [{readBy, file, line, library, bundledModule,
              targets: [{kind, value, host, origin}]}],
 unattributed: [{readBy, file, line, value, host}]}
```

- **`readBy`** is `kimchi` or `pi`. **`file`** and **`origin`** are relative to
  Kimchi's tree (`src/...`) or to its `node_modules` (`@earendil-works/...`).
  **`line`** only: a minified chunk puts many call sites on one line, and they
  share a row per library.
- **`library`**: `fetch`, `node-http`, `websocket`, `axios`, `undici`,
  `sdk:<package>` for another modeled package, or `sdk:<class>` for a
  `new C({baseURL})` matched by option name, because a bundle inlines the SDK
  and its import is gone. Any such class matches, a non-client one included,
  except `new this.constructor({...})`, which names no class.
- **`bundledModule`**: the esbuild `__commonJS` key enclosing the call, such as
  `node_modules/undici/index.js`. It means a dependency pi inlined.
- **`unattributed`**: URL literals no call site reads. The regex-scan inventory
  stays in the fact, but these literals are not attributed to any call site.

### Target kinds

`url` is a string with a scheme, `host` a scheme-less host literal joined after
`://` or that is a target's whole value (`hostname: "h"`, or `hostname: HOST` by
value flow from `const HOST = "h"`), `env` a `process.env` read (its value is
the name). When none of them reaches any target, the target is classified
instead: `argument` (a parameter's name), `property` (a property's name) or
`dynamic` (the expression's text, which CodeQL truncates in the middle with
`...`). A target read from a Kimchi config key is `property` or `dynamic`: the
fact does not name the config path.

Origins are taint flow: an origin influences the target and is not proof that it
is the whole of it. A wrapper takes every caller's origins. Kimchi's
`src/utils/http.ts:90` (`fetchWithRetry`) carries 11 targets, from the regions
table, `src/update/github.ts` and the npm registry. Two flow steps
over-approximate. `ComputedKeyRead` reads every property for `REGIONS[region]`,
so one call lists both regions' hosts. `ObjectSpreadAlias` aliases each spread
operand, which is where `app.kimchi.dev` was lost before. Both are global
`AdditionalFlowStep`s, so they change any query that runs in the same
evaluation.

### Models, and why there is a bridge

The javascript library models global `fetch`, node-fetch, `http`/`https`,
WebSocket and `ws`, axios, got and others as `ClientRequest`. It has no undici
model at all (`grep -rln undici` over javascript-all 2.10.4 finds nothing). A
models-as-data row alone never makes a `ClientRequest`: `request-forgery` rows
only become `RequestForgery::Sink`s. `ModeledClientRequest` in
`ql/network/Network.qll` bridges them: an invocation of the callee a
`request-forgery` row names, whose argument or a member of it one or two levels
deep is that row's sink, becomes a `ClientRequest`. After that, a library needs
only rows. The sink alone is not enough: an options object handed to the SDK and
to a logger is one sink node, and both calls would match. For the same reason
`sdk:<package>` is the matched row's package, not one read from the sink.

- **`ql/models/undici`**: the `undici.Dispatcher` type (every agent, pool and
  client class, `getGlobalDispatcher`, `compose`), its per-call `origin`, the
  top-level `request`/`fetch`/`stream`/`pipeline`/`connect`/`upgrade`, the
  origin-bound constructors, the proxy URLs, and `EventSource`/`WebSocket`.
- **`ql/models/sdk`**: `openai`, `@anthropic-ai/sdk`, `@google/genai`, the
  Bedrock runtime client and the MCP transports. A package name containing a dot
  must be single-quoted inside the row
  (`"'@modelcontextprotocol/sdk/client/sse.js'"`). Unquoted, it matches nothing,
  without an error.

### Bundles and minified chunks

The release database already sets
`CODEQL_EXTRACTOR_JAVASCRIPT_ALLOW_MINIFIED_FILES=true` (`kimchi-codeql.md`).
Without it the extractor skips 46 pi files, which include every bundle chunk.
The bundle is minified without renaming identifiers, so the global `fetch` still
matches by name. esbuild's own module shapes are not imports. Two
`ModuleImportNode::Range`s cover them: `__require("https")` and
`__toESM(require_x())` of a `__commonJS({"node_modules/<pkg>/...": ...})`
factory. Each matches the helper under its own name or as an imported alias.
They must be `overlay[local?]` and syntactic only, or compilation fails with
`Declaration is annotated overlay[local] but depends on global entity`. Other
bundlers (Bun's compiled kimchi binary, rollup, webpack) would need their own
ranges.

### What the fact does not reach

pi's provider catalog (`groq_default={...baseUrl:"https://api.groq.com/..."}`)
reaches its SDK clients only through runtime model selection. Those URLs stay in
`unattributed`, and the SDK call sites read `property baseUrl`. Go
(`tools/proxy-helper`) is outside a javascript database.

### The fixture check

`kimchi-codeql-network` builds a database of `checks/fixtures/network` with
`codeql.databaseOf`, which lays it out as the release tree, so `readBy`, the
`node_modules` include and the minified flag hold too. It requires the fact's
rows to equal `checks/fixtures/network-expected.txt`. That file has one line per
target. The source cases share one file, with a separate module for the local
`fetch` negative; the three bundle chunks retain helper and minified shapes. Its
negative controls are a docs-only URL, a browser-only URL, a module-local
`fetch` in `src/` and in the minified chunk, and
`new this.constructor({baseURL})`. Each must appear only as an unattributed
literal. A host constant joined into a URL's path is no host. Options objects
also handed to `console` or an imported logger must yield the SDK's row and not
the logger's, and one handed to two SDKs a row per SDK, each with its own
package. `chunk-minified.js` averages over 200 characters a line, so the
extractor skips it without the flag (measured: files averaging 173 were kept,
231 skipped), and its 5 rows go. The expected lines name fixture line numbers,
so reformatting a fixture file means regenerating them. biome leaves the chunks
under `node_modules` as they are.

### Running it without Nix

`codeql:kimchi-db` creates the database, and the query loop in
`kimchi-codeql.md` can then run `ql/network/NetworkCallSites.ql` on it, without
the model packs. The pack directories have no qlpack.yml, as `mkModelPack`
writes it. For the full rows, give CodeQL one model pack holding both
directories' `*.model.yml`, with `library: true`,
`extensionTargets: {codeql/javascript-all: "*"}`, `--additional-packs` and
`--model-packs`, as `customizePackage` does. Measured locally with 6 threads:
the query compiled in 93 s and evaluated on the release database in 51 s.
