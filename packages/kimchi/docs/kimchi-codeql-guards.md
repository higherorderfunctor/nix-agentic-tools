## Resource definitions, region registry and request guards

`lib/request-evidence.nix` reads three queries in `ql/network` from the same
`network.resultsOf` result derivation as the network fact. The existing query
runner, SDK/undici models and release database are shared. The package merges
`resourceDefinitions`, `regionRegistry` and `requestGuards` beside `network` and
`environment`; each is a static x86_64-linux fact. No additional release
database or source parser is involved. Compilation and release results require
CI.

`ResourceDefinitions.ql` reads object elements of the exported
`STATIC_RESOURCE_DEFINITIONS` array in `src/resources/definitions.ts`. Each row
contains `id`, `defaultEnabled`, `restartRequired`, `file` and `line`. Ids
follow string literals and const declaration bindings, including named ES
imports, without a global name fallback. Boolean declarations remain booleans;
absent properties are null, and nonliteral values are `"unresolved"`. An
unresolved id is `"<unresolved>"`. Missing restart declarations are not inferred
to be false. Dynamic discovery of hooks and packages is outside this static
inventory.

`RegionRegistry.ql` reads the exported `REGIONS` object and `DEFAULT_REGION` in
`src/regions.ts`. `fields` lists each region key, field name, literal string
value and field location. `defaultRegion` lists the default value and its
location. Empty strings are preserved, including self-hosted placeholders.
Nonliteral string values are `"<unresolved>"`; computed field names, spreads,
non-object regions and dynamically constructed registries are not expanded.
TypeScript `as const satisfies` wrappers are unwrapped with
`getUnderlyingValue`. These are declarations, not the result of region selection
or env overrides.

`RequestGuards.ql` uses `Network.qll`'s `ClientRequest`, library classification
and target predicate. Each row carries a `callSite` (file, line, column,
library, bundledModule), `guardSite` (file, line, column), `sourceKind`, `key`,
`outcome`, `conditionOutcome` and `scope: "intraprocedural"`. A
`ConditionGuardNode` must dominate that request's basic block. The source and
test must be in the request's own function. Value flow follows local aliases; a
test with another possible local source is omitted, since possible flow is not
necessary flow.

Recognized sources are named `process.env` reads, one- or two-level property
reads on the result of Kimchi's `src/config.ts` `loadConfig`, and boolean
results of `src/resources/store.ts` `isResourceEnabled` with literal or
imported-constant ids. Helpers are direct function declarations or named ES
imports (including renamed imports), resolved by binding and file, not callee
spelling. Config parameters and arbitrary objects named `config` do not qualify.
This models reads of parsed configuration, not config parsing or override
precedence.

Recognized tests are direct truthiness or a single `!` in an `if`, including
early return/throw. `outcome` is the source's required `truthy`/`falsy` value;
`conditionOutcome` is the boolean outcome of the whole `if` condition. Thus
`if (!enabled) return` requires source truthy and condition false. An early
throw caught before a request does not necessarily guard that request.
Comparisons, compound conditions, unknown keys, transformed booleans and
unresolved sources/polarities produce no guard rows. Neither callbacks nor
interprocedural helpers nor `enabledExtensionFactories` registration propagate
guards. Conditions are necessary locally, never sufficient for execution.

Rows are sorted and use only repository-relative paths. Guard locations retain
the database's `kimchi/` prefix to distinguish carried dependencies under
`kimchi/node_modules/`; inventory locations are relative to Kimchi's source.
Columns distinguish individual calls that the existing network fact groups on
one line. The report attaches evidence to its grouped network row but explicitly
limits each condition to the listed call column; it does not extend a guard to
other calls on that line. No evidence means **no modeled local guard**.

### Fixture contract

`checks/kimchi-codeql-request-evidence.nix` runs the same pack and transform on
`checks/fixtures/request-evidence/source` using `codeql.databaseOf`. It diffs
all three facts against hand-written `expected/*.json`. Expected values were
read from the fixture source, never obtained from the query. Each source case's
comment names the incorrect implementation it rejects.

In `src/requests.ts`, the only expected guards are:

| Call line:column | If line:column | Kind     | Key               | Source outcome | Condition outcome |
| ---------------- | -------------- | -------- | ----------------- | -------------- | ----------------- |
| 9:5              | 8:3            | resource | tools.search      | truthy         | true              |
| 17:3             | 16:3           | resource | tools.search      | truthy         | false             |
| 24:3             | 23:3           | resource | tools.search      | falsy          | false             |
| 31:3             | 30:3           | env      | TOKEN             | truthy         | false             |
| 40:5             | 39:3           | config   | telemetry.enabled | truthy         | true              |
| 57:5             | 56:3           | env      | ONLY_FIRST        | truthy         | true              |

All are `fetch`, `intraprocedural`, with both files `kimchi/src/requests.ts` and
`callSite.bundledModule: null`. No rows are expected for the sibling request
(51), second request (59), plain request (64), computed key (69), comparison
(70), callback (76), caught throw (85), alternative source (91), unrelated
config (97), ambiguous config/env receivers (103, 105), mutable id (112), or
`src/shadowed.ts:6`. Resources are `tools.search / false / true` at
definitions.ts:5 and `hooks.local / true / null` at :6; the imported id comes
from resources/ids.ts:1. Region fields are
`eu: id=eu, label=Europe, webAppUrl=https://eu.example` at regions.ts:3 and
`local: id=local, label=Local, webAppUrl=""` at :4; the default is `local` at
:6. Changing a default changes the expected resource row.

`node packages/kimchi/checks/fixtures/request-evidence/report.test.mjs` supplies
these hand-written facts to the real generator, tests explicit absence and
polarity, preserves legacy fields, and reverses input order. It verifies only
the reader boundary; QL compilation, fixture results and release rows remain CI
checks.
