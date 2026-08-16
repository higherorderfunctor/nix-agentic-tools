## ai.\* Pool Composition and Collision Semantics

> **Last verified:** 2026-08-15 (commit pending — B4 now also governs every
> generated `ai.programs.*` runtime-override leaf; null inherits and non-null
> wins without acquiring keyed-pool tombstone semantics). Prior: 2026-08-15
> (commit pending — proxied MCP declarations now carry explicit managed-unit
> ownership: a used root declaration owns one shared proxy, runtime declarations
> own directly, reused ownership keys fail, and unused root proxies do not
> materialize). Prior: 2026-08-15 (commit pending — all six normalized keyed
> pools now support per-runtime replacement and null tombstones; the former
> root↔runtime collision assertion is deleted, and definition provenance now
> rejects two packages claiming one key at the same root or runtime scope,
> including claims hidden by whole-option priority in a combined evaluation).
> Prior: 2026-08-15 (commit pending — the list-shaped instructions exception
> retired in favor of keyed rules). If you add a normalized pool or change its
> cross-level merge, null behavior, or package ownership rule and this fragment
> is not updated in the same commit, stop and fix it.

### Keyed-pool rule

The six normalized keyed pools are:

- `agents`
- `environmentVariables`
- `lspServers`
- `mcpServers`
- `rules`
- `skills`

Every root and per-runtime declaration uses `attrsOf (nullOr <valueType>)`. For
a capable runtime, composition is:

```nix
lib.filterAttrs (_: value: value != null) (rootPool // runtimePool)
```

This ordering is load-bearing:

1. root entries are portable defaults;
2. a same-key runtime entry replaces the root entry **wholesale**;
3. a same-key runtime null is a tombstone that suppresses the inherited entry;
4. null is filtered only after precedence, so it cannot disappear before doing
   that work.

Entries are atomic across levels. Records are never recursively merged. A second
runtime with no same-key entry continues to inherit the root value; keep that
positive control beside every per-pool negation test.

The old `mergeWithCollisionCheck` helper and its root↔runtime assertions were a
veto layered over data that already used the correct `root // runtime`
precedence. They are intentionally gone. A root and runtime same-key pair is no
longer a collision.

Unsupported per-runtime options remain absent. Root fanout to an unsupported
runtime degrades to `{}` before merging, based on the app record's
`supportedPools` list.

### Managed-proxy ownership exception

An MCP pool entry with `proxy.enable` has a managed systemd unit in addition to
its client value. The pool value still follows ordinary atomic replacement and
null negation, but the unit needs one unambiguous owner:

- a used top-level proxy declaration owns one shared unit and fans out only its
  lowered credential-free client entry;
- a runtime-scoped proxy declaration owns its unit directly; and
- the MCP server key is also the unit ownership key, so two proxy declarations
  may not reuse it across scopes. Use different keys even when the declarations
  are byte-identical.

This is not a return of the retired root↔runtime pool collision assertion. A
top-level proxied entry may still be replaced by an ordinary non-proxied runtime
entry or suppressed by null. The failure applies only when two declarations both
claim the same managed-proxy identity. A top-level owner inherited by no enabled
capable runtime is not materialized. The shared owner aggregator dynamically
discovers every runtime option subtree carrying the internal normalized-MCP
capability marker. Do not infer capability from the `mcpServers` name alone: the
generic public `mkAiApp` factory permits an unrelated same-named native option
when the normalized pool is unsupported.

### Package ownership rule

Two repo packages may not claim the same key in the same pool and scope. This is
checked independently at root and at every per-runtime scope, so these are
different ownership slots:

```text
ai.skills.example
ai.claude.skills.example
```

`checks/module-eval.nix` reads each option's `definitionsWithLocations`, keeps
repo-origin definitions, groups files under `packages/<name>/` as one package
owner, and reports keys with more than one owner. Consumer inline config is
`<unknown-file>` and is not treated as a package claim. Because
`definitionsWithLocations` is exposed after whole-option priority filtering, the
production guard aggregates the all-active evaluation with isolated evaluations
for every pool-contributing integration. A package claim hidden by another
package's `mkForce` in the combined tree therefore remains visible in its
isolated probe. Keep that activation inventory aligned when a package starts
writing a normalized pool.

Both production backend trees have clean checks. Fixtures prove every pool fails
at root and runtime scope, priority-shadowed claims still fail, two files under
one package remain one owner, root and runtime scopes remain independent, and
two different keys pass.

This provenance check is separate from runtime replacement. It catches two
packages competing within one scope; it does not mistake a root default and a
runtime replacement for two owners.

### Where repo modules contribute

Repo modules write `ai.<runtime>.<pool>`, never the root `ai.<pool>`. The root
level belongs to consumers as the portable default surface. A separate
`rootPoolViolations` provenance guard enforces that boundary. Per-runtime null
now lets a consumer undo an inherited root entry, but consumers should not have
to retract package wiring that silently fanned out beyond the package's runtime
ownership.

Package-generated entries normally use a whole-entry `mkDefault`, so an explicit
consumer value or null at that same per-runtime key wins through ordinary
module-system priority before root/runtime composition happens. Do not put
recursive defaults only on fields below a `nullOr` entry boundary: Nix must
choose the null or record branch before those leaf priorities can arbitrate, and
reports the option as both null and non-null instead of honoring the tombstone.

Always-on process defaults such as the sandbox-safe SSH command still use the
internal callback channel instead of writing a hidden normalized-pool
definition. That keeps module plumbing out of the consumer-owned override pool
and out of the package provenance guard.

### Non-pool composition exceptions

- `ai.context` is one content record per level. Root and runtime content
  concatenate root-first into one runtime-named artifact.
- `ai.hooks` is an event map whose matcher-group lists append shared-first.
  Event keys identify additive lifecycle streams, not replaceable pool items.
- `ai.shell`, normalized `ai.settings` fields, and generated
  `ai.<runtime>.programs.<pkg>` leaves are nullable scalars. `resolveOverride`
  interprets runtime null as **inherit**, not delete; a non-null runtime scalar
  wins.

Do not generalize keyed-pool tombstones to these surfaces without redesigning
and testing their distinct composition contracts.

### Implementation

`lib/ai/ai-common.nix:mergePool` owns the shallow merge and post-merge null
filter. `lib/ai/app/mkBackendTransform.nix` calls it once for every supported
pool and hands only the filtered `merged*` values to package callbacks. For MCP,
`lib/ai/mcpProxy.nix:lowerClientEntries` first lowers proxy declarations at each
scope while preserving null tombstones; only those client views cross the
root/runtime merge. `lib/ai/sharedOptions.nix` separately aggregates explicit
proxy owners, rejects reused keys before the module system can collide, and
emits only unique active units.

`hmTransform.nix` and `devenvTransform.nix` are thin backend selectors; do not
duplicate pool logic into them.

### Adding a normalized pool

1. Declare root and per-runtime values as `attrsOf (nullOr <valueType>)`.
2. Add the capability to each consuming app record's `supportedPools`.
3. Route root and runtime values through `mergePool` before any translation or
   emission.
4. Add the pool to `normalizedPoolNames` in `checks/module-eval.nix` so package
   ownership is checked at root and every runtime scope.
5. Test null-drop with a second-runtime inheritance control, wholesale same-key
   replacement, package collision diagnostics via `lib.hasInfix`, and a
   different-key package control.

### Debugging

For a missing emitted entry, inspect both levels before the callback:

```bash
nix eval .#homeConfigurations.<host>.config.ai.<pool>
nix eval .#homeConfigurations.<host>.config.ai.<runtime>.<pool>
```

A runtime null at the key is an intentional deletion. For a package collision,
the check diagnostic names the exact option path and all contributing module
files; move one contribution to a distinct key or establish a single package
owner rather than changing root/runtime precedence.
