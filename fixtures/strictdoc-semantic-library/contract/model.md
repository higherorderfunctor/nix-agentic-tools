# Neutral fixture model

Status: **PROPOSED — pending user review.** This is a Gate 1 behavior draft, not
an approved semantic specification or implemented engine.
[Decisions](decisions.md) records the choices requiring approval;
[scenarios](scenarios.md) supplies their examples. No scenario outcome becomes
an approved test expectation merely because this document or a test is written.

## Established constraints

The entire native Parent/Child traceability graph must be a DAG. Multiple roots
are allowed; Child authoring is enabled. The selected hierarchy is a forest,
without an added connectedness requirement. Hooks can schedule evaluation but
cannot change validity. These user constraints apply even where today's public
runtime does not enforce them completely.

This retained consumer fixture lives inside the repository and uses native
devenv, a filtered public toolchain dependency, and the normal shared host and
Nix store. It has no fixture flake or private-store/offline harness. The
semantic backend remains unknown; no JVM is permitted, and SQLite is not the
default. The fixture author uses public exports and diagnostics, without
inspecting library implementation.

## Vocabulary and small corpus

| Symbol | Proposed declaration                    | Purpose                                                                  |
| ------ | --------------------------------------- | ------------------------------------------------------------------------ |
| `BAR`  | Parent `P`, Child `Q`                   | Bridge owning both endpoint declarations                                 |
| `BAZ`  | Parent `R`, Child `Q`                   | Resolvable wrong target, reused role contexts, unrestricted connectivity |
| `FOO`  | Required `FLAG`; Parent `H`, Parent `R` | Hierarchy and visibility examples                                        |

`FLAG` has literal SDoc values `false` and `true`. The existing public grammar
API can express these as required single-choice strings. Interpreting them as
open and closed is a proposed semantic decision, not an existing boolean
constructor. Missing or different values are input errors, never implicit open
values.

Every element explicitly declares required string `UID`; without that
declaration, a native `new` can write a node that cannot be addressed even when
its RPC request contains `uid`. This was discovered through generated documents
and public mutation diagnostics.

The installed Scribe interface requires grammar declarations for `AUTHORED_BY`
and `PARENT_FP`. `AUTHORED_BY` may be a required string populated by Scribe;
`PARENT_FP` may be optional. They are runtime accommodations, not the neutral
model's proposed history policy. Any influence these fields have on native
acceptance must be recorded separately.

The base forest is small enough to read directly:

```text
F0 false
├── F1 false
│   └── F1a false
└── F2 true
    ├── F2a false
    └── F2b false

G0 false
└── G1 false

I0 false

Z0 : BAZ
```

Every drawn hierarchy edge is authored on its child as `Parent H` targeting the
parent. `Z0` is outside the hierarchy. `M` is a fresh BAR used by separate
bridge scenarios. `F2b` makes inside-to-inside visibility testable without
introducing a native cycle. Document placement and nesting do not define
ancestry. Scenario-specific nodes use the same three types and explicit fields.

Prefer one readable forest corpus and a few small native-valid relation/bridge
examples. Recreate each scenario from its named base; do not accumulate the
illustrative `R` and BAR declarations. Future negative semantic cases should be
mutations from those bases, not silently accepted invalid examples in the
baseline corpus.

## Authored relations and normalized connectivity

Selectors include grammar identity, owner element, native type, and role. For
example, `(fixture, FOO, Parent, R)` differs from `(fixture, BAZ, Parent, R)`.
The latter is a positive control for selector scope, not a second declaration of
the FOO rule.

| Authored declaration           | Parent-to-child connectivity |
| ------------------------------ | ---------------------------- |
| Child `C` owns `Parent H -> P` | `P -> C`                     |
| BAR `M` owns `Parent P -> U`   | `U -> M`                     |
| BAR `M` owns `Child Q -> D`    | `M -> D`                     |

A bridge remains `U -> M -> D`; it is not flattened to `U -> D`. Retain owner,
target, native type, role, model context, and diagnostic source location. A
reverse-role label does not manufacture a reciprocal authored relation.

Proposed restrictions: FOO `H` and `R` target FOO; BAR `P` and `Q` target FOO.
Every FOO has at most one `H` parent. Every completed BAR has exactly one `P`
and one `Q`. Other roles neither become hierarchy edges nor count toward `H`
parent cardinality. The total graph can therefore have multiple native parents
while its `H` projection remains a forest.

## Proposed visibility, stated independently of an evaluator

For FOO `R`, origin means the declaration owner and target means its declared
endpoint. Require one shared `H` root. Follow the unique undirected hierarchy
path from origin to target: ascent is unrestricted; descent may visit a closed
endpoint but may expand a closed node only if the original origin lies in that
closed node's subtree, including the closed node itself. No step uses another
role. This explicitly permits exiting an origin's closed compartment and
reaching peers inside that same compartment.

For BAR, origin is its `P` endpoint and target is its `Q` endpoint. Require a
downward `H` path, using the same origin-sensitive expansion rule. A closed
start may expand; a closed endpoint reached externally may be visited without
expanding. An open node behind an intervening closed ancestor stays hidden.

These are concrete proposals, not settled meanings of closure. A global
adjacency relation with every closed node's outgoing edges removed would change
the proposed closed-origin behavior. Implementations must preserve approved
visit/expand and origin rules, or report an unsupported capability.

## Native constraints can mask semantic questions

A BAR whose two endpoints are `U` creates `U -> M -> U`. It violates the
established DAG constraint regardless of whether a semantic traversal admits a
zero-length path. Similarly, `C Parent R -> C` is a self-cycle; an ancestor's
Parent `R` link to its own hierarchy descendant closes a native cycle. Such
cases cannot demonstrate independent traversal rejection through Scribe.

Use sibling origins/targets or downward BAR paths for native-valid semantic
truth rows. Keep equal-endpoint cases as native-cycle coverage; an isolated
zero-length traversal question remains a proposed mathematical convention, not
an independently observable Scribe acceptance requirement.

## Proposed external protection

A fixture-owned provider supplies a complete identified baseline snapshot. For
each listed UID, freeze its modeled authored record: element type, `FLAG` when
present, and its owned modeled relations. Compare relation sets independently of
declaration ordering; exclude file location, reverse display labels, and runtime
bookkeeping fields. UIDs must continue to exist. Incoming relations owned
elsewhere are not implicitly frozen. Changing a protected FOO's `FLAG` or owned
`H` relation and deleting a protected UID therefore violate the proposed policy.

This ownership-based projection is deliberately explicit and pending review. A
protected node can gain incoming connectivity unless another rule forbids it. A
superseding relation grants no deletion or revision exception. The fake provider
proves external acquisition and comparison only; it does not establish Git
baselines, merge bases, cross-revision identity, or hashing semantics.
