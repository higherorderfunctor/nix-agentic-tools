## The environment fact from CodeQL

> **Last verified:** 2026-10-22 — environment facts include destructuring and
> named process imports; std-env CI-provider tuple keys resolve per row with
> their `||` fallback.

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
declarators and ES imports (minified `export{a as K}` included), and a by-name
fallback for a constant with no reachable initializer, two strata deep, that
fails when same-named constants disagree. pi's `APP_NAME` takes
`kimchi/package.json`'s `piConfig.name`, as at runtime. `+` is not folded, a
`delete` operand is not a read, `+=` and `??=` are. For-of bindings never use
the global by-name fallback: their names come from dense literal arrays,
including a destructured tuple column and nested iteration. All table uses must
belong to the traced definitions and loop domains; escaping or mutated tables,
sparse arrays, spreads and unresolved elements fail. A `typeof key === "string"`
conditional permits function alternatives only when they are function literals
or direct declared helpers returning function literals.

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
`AWS_EXECUTION_ENV`. The former `tsIncompatible` filter dropped those names
solely to match the deleted TypeScript extractor. No compatibility filter
remains.

The bundled std-env CI-provider table indexes a for-of tuple with
`row[1] || row[0]`. The query resolves literal numeric tuple columns and
evaluates the fallback separately for each row: `CIRCLECI` is the key for
`["CIRCLE", "CIRCLECI"]`, while `["GITHUB_ACTIONS"]` uses `GITHUB_ACTIONS`. A
comma expression around the literal table contributes its final operand. Other
literal-index uses of a tuple, including its returned metadata, do not make the
table escape.

Measured on the pinned Kimchi 1.19.1 database after this resolution, 63 computed
environment-read sites still have no resolved name and emit no refusal. These
include dynamic helper parameters and SDK constants initialized by assignments.
This measurement counts sites, including separate reads of a name also resolved
elsewhere. No general computed-key refusal is added.

The database also recognizes bracket `env`, asserted environments,
`require("process").env`, and process aliases. Refusals tied only to the former
extractor's inability to distinguish a shadowed `process` or read nested
destructuring have been removed. The overwrite analysis still establishes writes
only through `process.env` spelled out.

### Annotations

`extract/annotations.json`'s `environment` and `environmentIgnored` are not an
input of the transform. `rules.nix` applies them downstream, against
`environment.variables.<name>`, as it always did. Ordinary new names need no
annotation. The std-env table's `INPUT_AZURE_STATIC_WEB_APPS_API_TOKEN` matches
the shared secret classifier, so its required `controls` row records that
std-env tests its presence for CI-provider detection.

### The guard

`kimchi-codeql-environment-guard` runs the pack and transform over each tree
under `checks/fixtures/codeql-environment/`, laid out like the real source root
and extracted by `kimchi-codeql-create-database <dir> <tree>`. `reads` holds
seven read shapes absent from the pinned tree in one Kimchi file: bracket `env`,
an asserted environment, a process alias, bracket `globalThis.process`, literal
`require("process")`, a namespace process import, and `+=`; concatenation
remains unevaluated. The release query covers its actual read shapes, including
pi's APP_NAME and bundled imports. The reads fixture also holds the adapter's
`KIMCHI_MANAGES_MCP_PROJECT_TRUST` read outside the @earendil-works scope,
attributed to `pi`. `overwrites` holds the launch-order mix; `fail-shapes`,
`fail-order` and `fail-sources` exercise the retained refusal classes, with
helper declarations merged into their case. The reads fixture also checks a
nested literal table with string/function alternatives and an aliased
environment passed through two helpers, alongside unrelated objects that must
add no names; fail-shapes refuses an unresolved iteration key and rest copies
passed to unknown functions. The positive reads fixture copies std-env's 58-row
provider table and checks its 58 environment keys. The overwrites fixture checks
reads through helper forwarding, aliases and rest copies before writes. A new
shape goes into one of these trees, not into a mutant of the real source: a
real-tree mutant costs a database build each.

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
  --slurpfile overwrites /tmp/LaunchOverwrites.json > /tmp/environment.json
jq -S .environment packages/kimchi/extracted/extracted.json | cmp - /tmp/environment.json
```

The fourth column of a reads row and the third of an overwrites row is the site,
`path:line`, for reading a result back; the transform ignores it. Measured on a
16-core x86_64-linux workstation: the reads query takes 27 to 90 s against the
1.17.2 database, the overwrites query about 30 s.

### Patches the tree does not carry

Kimchi 1.19.1 patches the MCP client and playwright-core too, packages the
source root does not carry, so the queries never see their added lines. The
extractor read them as text. `source` refuses an added line in one of them that
names `env`, with the fix: carry the package. Joining a patch's `+` lines into a
file does not work here: CodeQL drops a file with any syntax error, and the
earlier seven-patch experiment left five joined patches with none of their code
extracted.
