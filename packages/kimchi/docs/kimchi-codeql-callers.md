## Request callers and callbacks

`requestCallers` is one static x86_64-linux CodeQL fact. `RequestCallers.ql`
shares the `network` query pack, models, release database and query results;
`lib/request-evidence.nix` decodes it with `lib/request-callers.jq`. The package
merges it beside `requestGuards`. Only requests under `kimchi/src/` qualify,
using the same `ClientRequest`, library and target predicates as the network
queries. A call occurrence is identified by file, line **and column**. Thus the
two calls on `src/extensions/memory/backend.ts:192` remain distinct even though
`network` groups them. Carried dependencies are outside this fact.

Every row contains `callSite` (file, line, column, library), `functionSite`
(file, line, column), `kind`, `site` (file, line, column), `property`, `reason`
and `distance`. Locations retain the database's repository-relative `kimchi/`
prefix. Unused properties and reasons are null. Rows are deduplicated and sorted
by request location/library, distance, function location, kind, site, property
and reason. Each edge or boundary keeps its minimum distance across chains;
paths are never emitted. For a receiving member call, `site` starts at the
called property name (`then` in `f().then(cb)`), or the property expression
inside brackets. Other calls use the call's start. This also applies to
boundaries at receiving calls, keeping calls within one chain distinct.

- `enclosing`: `functionSite` and `site` identify the request's enclosing
  function; distance is zero.
- `caller`: `functionSite` is the reached callee and `site` is the call that
  resolves to it. Distance counts backward edges from the request function.
- `callback`: `functionSite` is the reached function value and `site` is the
  receiving call. `property` names an inline object argument's property, or is
  null for a direct argument. A computed property is `"<computed>"`.
- `boundary`: `functionSite` is the reached function; `site` identifies the
  stopping use or function, and `reason` explains the stop. At a callback use,
  `property` retains the inline object property's name (or `"<computed>"`),
  including at depth, recursion and registration boundaries; otherwise it is
  null.

Binding resolution follows function declarations, named imports (including
renaming) and immutable const aliases. Namespace member calls such as `ns.f()`
and const destructuring such as `const { f: renamed } = await import("./m.js")`
resolve through CodeQL's imported module and its exported bindings. The dynamic
import path must be a string literal; destructuring must bind a named property
directly to a variable. These forms resolve exported function declarations and
const function values without matching names across unrelated modules. Methods
resolve on object literals and const aliases of those objects, on a const-bound
`new` instance whose class binding resolves, and on `this` in that class's
methods. A `new C(...)` call also resolves to the constructor function when `C`
resolves to a source class through `boundClass`. These are declaration bindings,
never a search for matching function names. The shared helpers live in
`DeclarationValues.qll`; literal strings still follow only named imports and
const aliases, through the same const-initializer helper as function values.

Callbacks are syntax only: an arrow, function expression or binding-resolved
identifier directly in an argument, or as a property value in an inline object
argument (including nested literal value properties). An unrelated stored
options object creates no callback edge. For resolved Kimchi callees, traversal
continues through the function containing the receiving call, just as for
ordinary callers. This includes `new C({ reconnect })` when `C` resolves by
declaration binding, named import or const alias to a Kimchi source class.
Passing a callback does not prove that the recipient invokes it. Parameter reads
inside the recipient do not become caller edges.

Traversal remembers the current chain's function identities and stops before
revisiting one. The integer depth domain is explicitly limited to 0 through 4.
An edge at distance four is retained. If the function has no shorter route, a
possible fifth edge produces a boundary at distance four, naming that next call,
rather than disappearing. Other boundaries at uses count the observed edge;
stored and unresolved escapes use the distance of the reached function.

At Kimchi 1.26.0, `src/models.ts:207:21` reaches `runWizard` at
`src/setup-wizard/index.ts:36:8` at distance four. Its dynamically imported call
at `src/cli.ts:617:33` produces a `boundary` row with reason `depth`, distance
`4`, and null property, using those request, function and call locations with
the `kimchi/` prefix. It does not produce a fifth caller edge.

Boundary reasons:

- `depth`: a reached function at depth four has another caller or callback use.
- `recursion`: the next containing function is already in this chain; the edge
  is retained but traversal stops.
- `registration`: a callback's receiving callee cannot resolve to a Kimchi
  source function or, for `new`, a source class declaration. This includes SDK
  or framework methods such as `pi.on`.
- `stored`: a function value initializes a variable, object property or class
  member, or is assigned to a variable or property outside the callback forms. A
  const alias can have both a store boundary and resolved caller edges.
- `unreferenced`: no caller, callback or escaping value was found for this
  reached function. An exported entry point can have this boundary. A resolved
  call at module level also ends here. A request without an enclosing function
  gets this boundary at its own location instead of a fictitious function.
- `unresolved`: another function-value use, such as returning the function,
  falls outside the supported edge and store syntax. Its concrete location is
  preserved instead of being silently omitted.

Optional chaining does not change resolution: `client?.send()` and `ns?.f()`
resolve like `client.send()` and `ns.f()`. There is no data flow through
properties, spreads, coalescing (`??`), parameters, return values or mutable
module state. A concrete object method binding is the narrow property lookup
described above; it does not propagate an options property's value. Class
inheritance, dynamic receivers and prototype mutation are not resolved. Property
registrations and class member definitions can therefore have stored boundaries
even when some ordinary callers resolve. The worker's `{ fetch: fetchBounded }`
gives a callback edge at that call; `options?.fetch ?? globalThis.fetch`,
`fetchImpl` and `fetchFn` do not create additional edges. Spreads and stored
options objects are not expanded.

Rows are **reachability evidence only**, not conditions. They make no claim that
a request is enabled, disabled, default-on or dead. All-boundary evidence is
still evidence with explicit limits. Guards remain intraprocedural; resource
policy, registration precedence, judgments and the census are unchanged. No
model is called in CI.

### Fixture contract

`checks/kimchi-codeql-request-callers.nix` builds the fixture tree with the same
`codeql.databaseOf` and `network.resultsOf` used for release facts and applies
the same decoder. It compares whole rows against the hand-written
`checks/fixtures/request-callers/expected/requestCallers.json`. A failure prints
removed/added rows and directs the operator to both `callSite.file` and
`site.file`, plus the expected row ledger. A cross-file case may have its
request in `callers.ts` and its use in an import fixture or in `unrelated.ts` if
name matching regresses. Read those sources before fixing the query or expected
rows. Source comments name the incorrect implementation each case rejects.

The expected rows were authored from fixture source, never from the query. They
cover distinct columns, two callers with different local guards, renamed,
namespace and destructured dynamic imports, const aliases, a same-named negative
module, source constructor callers and callbacks, distinct chained call sites,
callback properties versus stored properties, registration, module storage,
mutual recursion, depth, exported entries, inline arrows/function expressions,
object/class methods, minimum distances and unsupported returned functions. See
the adjacent
[expected row ledger](../checks/fixtures/request-callers/expected/rows.md) for
every exact location and row. Function declaration locations exclude the
`export` keyword, as the pinned extractor's `fixExports` does.

The existing `request-evidence/report.test.mjs` also supplies synthetic caller
rows to the real report generator, checks columns and boundaries survive, and
reverses their order. Local Node checks establish the reader contract only. QL
compilation, fixture equality and real-release coverage must be settled by CI.
