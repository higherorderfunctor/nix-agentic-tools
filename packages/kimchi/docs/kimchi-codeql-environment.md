## The environment fact from CodeQL

> **Last verified:** 2026-10-22 — `environment.variables` includes the carried
> pi-mcp-adapter; the reads fixture verifies its patched project-trust variable
> is attributed to the pi runtime; literal iteration tables resolve environment
> names, named reads follow known helper parameters, and launch analysis follows
> known helpers and rest copies.

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

### Two shapes kept out on purpose

The extractor at 1.17.2 did not read `const { X } = process.env` or a read
through `import { env } from "node:process"`. The database finds both: seven
names, `GIT_*` from `src/extensions/work-attribution/scope.ts`, `HOMEDRIVE` and
`HOMEPATH`, and `AWS_EXECUTION_ENV` from the bundled AWS SDK. `tsIncompatible`
in `EnvReads.qll` drops them so the committed fact is unchanged. They are real
reads; deleting that predicate adds them, and `rules.nix` reconciles unannotated
non-secret names without a row. That is a data decision, not a bug fix.

The database also reads four shapes the extractor missed that 1.17.2 does not
use (`process["env"]`, `(process.env as T).X`, `require("process").env` and an
alias of `process` itself), misses one it read (the namespace binding of
`import d, * as ns from "node:process"`, a statement 1.17.2 does not contain:
measured when biome merged two fixture imports into one), and reads pi-ai,
pi-tui and pi-agent-core whole where the extractor saw their `.d.ts` and
Kimchi's patch lines. On 1.17.2 both make no difference; a later release may
gain a correct name from them.

### Annotations

`extract/annotations.json`'s `environment` and `environmentIgnored` are not an
input of the transform. `rules.nix` applies them downstream, against
`environment.variables.<name>`, as it always did.

### The guard

`kimchi-codeql-environment-guard` runs the pack and transform over each tree
under `checks/fixtures/codeql-environment/`, laid out like the real source root
and extracted by `kimchi-codeql-create-database <dir> <tree>`. `reads` holds
seven read shapes absent from the pinned tree in one Kimchi file: bracket `env`,
an asserted environment, a process alias, bracket `globalThis.process`, literal
`require("process")`, a namespace process import, and `+=`; concatenation
remains unevaluated. The pinned release's byte identity covers its actual read
shapes, including pi's APP_NAME and bundled imports. The reads fixture also
holds the adapter's `KIMCHI_MANAGES_MCP_PROJECT_TRUST` read outside the
@earendil-works scope, attributed to `pi`. `overwrites` holds the launch-order
mix; `fail-shapes`, `fail-order` and `fail-sources` retain every refusal
assertion, with helper declarations merged into their case. The reads fixture
also checks a nested literal table with string/function alternatives and an
aliased environment passed through two helpers, alongside unrelated objects that
must add no names; fail-shapes refuses unknown and mixed elements, missing tuple
columns, mutation, spreads, sparse arrays and rest copies passed to unknown
functions. The overwrites fixture checks reads through helper forwarding,
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
  --slurpfile overwrites /tmp/LaunchOverwrites.json > /tmp/environment.json
jq -S .environment packages/kimchi/extracted/extracted.json | cmp - /tmp/environment.json
```

The fourth column of a reads row and the third of an overwrites row is the site,
`path:line`, for reading a result back; the transform ignores it. Measured on a
16-core x86_64-linux workstation: the reads query takes 27 to 90 s against the
1.17.2 database, the overwrites query about 30 s.

### Patches the tree does not carry

Kimchi patches the MCP SDK and client and playwright-core too, packages the
source root does not carry, so the queries never see their added lines. The
extractor read them as text. `source` refuses an added line in one of them that
names `env`, with the fix: carry the package. Joining a patch's `+` lines into a
file does not work here: CodeQL drops a file with any syntax error, and five of
the seven joined patches had none of their code extracted.
