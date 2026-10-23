## The environment fact from CodeQL

> **Last verified:** 2026-10-23 — fixed names resolve through CommonJS property
> assignments and destructured reexports, literal callback arrays and object
> tables, and declared, arrow and function-expression key helpers. Unresolved
> computed reads fail extraction unless their site is reviewed; stale site rows
> and changed occurrence counts fail the same transform.

`extracted.json`'s `environment` surface is one fact the CodeQL database
produces. `extract/environment.nix` runs the two-query pack
`packages/kimchi/ql/environment/` through `runQueries` and
`extract/environment.jq` over the decoded result sets; `package.nix` splices
that surface into the raw `extract.mjs` writes. The engine builds on
x86_64-linux only, which is the one system every row of `extracted/facts.json`
declares, so `passthru.extracted` exists on that system alone and
`kimchi-extracted` wires no other host.

### What the queries answer

`EnvironmentReads.ql` lists every named read of `process.env` with the runtime
that reads it: `kimchi/src/**` is `kimchi`, carried dependencies under
`kimchi/node_modules/` are `pi`. Here `pi` names the harness runtime and its
extensions, including pi-mcp-adapter, rather than only the @earendil-works
packages. The process object is `NodeJSLib::process()`, so the global under any
name, `globalThis.process`, and a default or namespace import of `process` all
count, and local flow follows aliases, `??` and `||` fallbacks, parameter
defaults and `const { env } = process`. Named reads also follow the environment
through known callees at the corresponding argument index, including aliases and
multiple helper calls; unrelated object arguments are not environment sources. A
computed name is evaluated by a QL copy of the extractor's `stringConstant`:
literals, templates, `.toUpperCase()`, identifiers followed through their
declarators, assignments to uninitialized bindings, and ES imports (minified
`export{a as K}` included), and a by-name fallback for a constant with no
reachable initializer, two strata deep, that fails when same-named constants
disagree. pi's `APP_NAME` takes `kimchi/package.json`'s `piConfig.name`, as at
runtime. `+` is not folded, a `delete` operand is not a read, `+=` and `??=`
are. For-of bindings never use the global by-name fallback: their names come
from dense literal arrays, including a destructured tuple column and nested
iteration. All table uses must belong to the traced definitions and loop
domains; escaping or mutated tables, sparse arrays, spreads and unresolved
elements fail. A `typeof key === "string"` conditional permits function
alternatives only when they are function literals or direct declared helpers
returning function literals.

`LaunchOverwrites.ql` names the variables `entry.ts` fixes on every launch, by
the rules `launchOverwrites` applied: top-level statements in order, entering
blocks and both arms of an if with an else, for writes and their refusals alike;
writes through `process.env` spelled out only; reads in function declarations
and in functions handed `process.env` counted first, a parameter's computed key
evaluated like any other and refused when it cannot be. Known declared helpers
may forward the environment through more helpers, local aliases and named object
patterns with rest bindings. Those names count as reads before a later write;
forwarding a rest copy to an unknown consumer still fails. There is a failure
for every shape that makes the order unknowable. "After it suspends" follows the
extractor's children-first walk by end position, not the control-flow graph,
which would accept `if (c) { await 0 } else { process.env.X = "1" }`.

Either query emits `fail` rows instead of guessing; the transform fails on any,
naming each, and the `extracted` build fails with it.

### Reads beyond the former TypeScript extractor

Destructuring `process.env` and a named `env` import from `node:process` count
as real reads. Kimchi 1.19.1's `src/extensions/work-attribution/scope.ts:35`
reads `GIT_DIR`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` through
an object pattern; the carried pi bundle also reads `HOMEDRIVE`, `HOMEPATH` and
`AWS_EXECUTION_ENV`.

The bundled std-env CI-provider table indexes a for-of tuple with
`row[1] || row[0]`. The query resolves literal numeric tuple columns and
evaluates the fallback separately for each row: `CIRCLECI` is the key for
`["CIRCLE", "CIRCLECI"]`, while `["GITHUB_ACTIONS"]` uses `GITHUB_ACTIONS`. A
comma expression around the literal table contributes its final operand. Other
literal-index uses of a tuple, including its returned metadata, do not make the
table escape.

Helpers whose parameter names the environment key contribute the names of
literal or constant call arguments at that parameter index. This includes
`boolEnv` and `nonEmptyEnv` in `src/oauth-config.ts:63-70`, `parseEnvInt` in
`src/shared/env-int.ts:7`, and pi's `getProviderEnvValue`. Declared functions,
arrow bindings and function-expression bindings share this rule. Parameter
forwarding through known helpers is followed to its call arguments, including
jiti’s boolean-to-JSON reader. A helper site resolves completely only when all
terminal call arguments resolve. `nonEmptyEnv` also receives a region template
at `src/oauth-config.ts:85`, so its literal calls contribute names while that
read remains unresolved. Uninitialized bundled bindings assigned string literals
also resolve, including `AWS_LAMBDA_FUNCTION_NAME` and `_X_AMZN_TRACE_ID` in
`bedrock-converse-stream.js:24`.

A computed environment read that resolves to no name and has no existing refusal
emits a `fail` row through `readFailure`. Extraction accepts it only when its
exact review key has a non-blank `reason` and its occurrence count matches
`sites` under `annotations.json`'s `environmentUnresolved`. A new unresolved key
fails with its review key and source location. A listed key that is no longer
unresolved also fails, asking to delete the stale row. Existing refusals cannot
be waived by these annotations.

A review key combines the module path, nearest named function (including through
anonymous callbacks), and the key expression's AST kind. Generated
eight-character chunk hashes are removed from filenames; a root
`dist/<module>.js` shares `<module>.ts`'s key. Function names distinguish the
helpers even when minified parameter names change. Identical helper reads,
including TypeScript and compiled JavaScript copies, share one annotation.
Columns distinguish occurrences in query diagnostics, so an additional
unresolved read in an already accepted helper changes its count and fails
review. Moving lines or changing a chunk hash needs no edit; changing the
function or key kind requires review. These are site reviews, not package-wide
exceptions.

A review row is either a genuinely dynamic key or an evaluator limitation whose
reason names the fixed names it leaves out. Two rows are limitations: the region
template in `oauth-config.ts` (`KIMCHI_OAUTH_CLIENT_ID_US` and `_EU`, missing
from the fact) and the AWS `fromEnvSigningName` template
(`AWS_BEARER_TOKEN_BEDROCK`, listed through another site). Fixed names resolve
through CommonJS property assignments and the existing unique by-name constant
fallback using a destructured property's exported name. That fallback also
follows bundled literal assignments. Literal arrays passed through element
callbacks contribute their names when every element is a string literal. An
object table indexed by a runtime key contributes all its values only when every
property value is a string literal. These cover the pinned Google
certificate-config constant, AWS profile reexport, PR-cost CI array, steer table
and bug-report arrow helper without naming those constants in the query.

The database also recognizes bracket `env`, asserted environments,
`require("process").env`, and process aliases. The overwrite analysis
establishes writes only through `process.env` spelled out.

### Annotations

The transform reads `extract/annotations.json`'s `environmentUnresolved` map of
review keys to `{reason, sites}` rows. Its stale-row comparison happens here
because raw query sites are absent from the variable fact reconciled downstream.
`rules.nix` applies `environment` and `environmentIgnored` downstream, against
`environment.variables.<name>`. Ordinary new names need no annotation. The
std-env table's `INPUT_AZURE_STATIC_WEB_APPS_API_TOKEN` matches the shared
secret classifier, so its required `controls` row records that std-env tests its
presence for CI-provider detection.

### The guard

`kimchi-codeql-environment-guard` runs the pack and transform over each tree
under `checks/fixtures/codeql-environment/`, laid out like the real source root
and extracted by `kimchi-codeql-create-database <dir> <tree>`. `reads` holds
seven read shapes absent from the pinned tree in one Kimchi file: bracket `env`,
an asserted environment, a process alias, bracket `globalThis.process`, literal
`require("process")`, a namespace process import, and `+=`. Concatenation
remains unevaluated and is refused in `fail-shapes`. The release query covers
its actual read shapes, including pi's APP_NAME and bundled imports. The reads
fixture also holds the adapter's `KIMCHI_MANAGES_MCP_PROJECT_TRUST` read outside
the @earendil-works scope, attributed to `pi`. `overwrites` holds the
launch-order mix; `fail-shapes`, `fail-order` and `fail-sources` exercise the
retained refusal classes, with helper declarations merged into their case. The
reads fixture also checks a nested literal table with string/function
alternatives and an aliased environment passed through two helpers, alongside
unrelated objects that must add no names; fail-shapes refuses an unresolved
iteration key and rest copies passed to unknown functions. Fixtures supply an
empty annotation map, so the release's site reviews neither exempt fixture reads
nor become stale rows in fixture transforms. The positive reads fixture uses two
rows from std-env's provider table: `["GITHUB_ACTIONS"]` and
`["CIRCLE", "CIRCLECI"]`, checking two environment keys. It also checks literal
and constant helper arguments and a binding assigned a string literal before its
computed read. The overwrites fixture checks reads through helper forwarding,
aliases and rest copies before writes. A new shape goes into one of these trees,
not into a mutant of the real source: a real-tree mutant costs a database build
each.

### Running it without Nix

```bash
devenv tasks run codeql:kimchi-db        # once per pin
state=.devenv/state/codeql/kimchi
for q in EnvironmentReads LaunchOverwrites; do
  "$state/engine/bin/codeql" query run --database="$state/db" \
    --additional-packs=packages/kimchi/ql --output="/tmp/$q.bqrs" \
    "packages/kimchi/ql/environment/$q.ql"
  "$state/engine/bin/codeql" bqrs decode --format=json "/tmp/$q.bqrs" \
    | jq --sort-keys 'map_values(.tuples |= sort)' > "/tmp/$q.json"
done
jq -S -n -f packages/kimchi/extract/environment.jq \
  --slurpfile reads /tmp/EnvironmentReads.json \
  --slurpfile overwrites /tmp/LaunchOverwrites.json \
  --slurpfile annotations packages/kimchi/extract/annotations.json > /tmp/environment.json
jq -S .environment packages/kimchi/extracted/extracted.json | cmp - /tmp/environment.json
```

The fourth column of a reads row and the third of an overwrites row is the site,
`path:line`, for reading a result back; unresolved reads also carry the column
so separate occurrences remain separate rows. The transform uses these rows to
check reviewed occurrence counts and includes locations in failure messages.

### Patches the tree does not carry

Kimchi 1.19.1 patches the MCP client and playwright-core too, packages the
source root does not carry, so the queries never see their added lines. The
extractor read them as text. `source` refuses an added line in one of them that
names `env`, with the fix: carry the package. Joining a patch's `+` lines into a
file does not work here: CodeQL drops a file with any syntax error, and the
earlier seven-patch experiment left five joined patches with none of their code
extracted.
