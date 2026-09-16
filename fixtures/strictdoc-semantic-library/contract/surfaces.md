# Public authoring surfaces for review

**Proposed semantic APIs, existing native grammar underneath.** The 2026-09-15
handoff replaces the older upper policy-wrapper design and public transaction
lifecycle. Exact names remain provisional; [interface](gate2/interface.md) is
the current detailed contract. This document describes configuration surfaces,
not installed semantic exports.

## Existing native surface

Supplied public source findings identify
`lib.ai.strictdocGrammar { inherit lib; }`, exporting `check`, `dsl`, `emit`,
`normalized`, `render`; the devenv module `devenvModules.nix-agentic-tools`; and
`packages.${system}.strictdoc`. Public `g.field.str`, `g.field.one`,
`g.field.many`, `g.field.required`, `g.el`, `g.rel.parent` and `g.rel.child`
remain native constructors. `render` validates before emission; direct `emit`
does not itself validate. Native fields are ordered; an empty native relations
collection lowers to null/absence, not `[]`.

No schema/constraint/default/semantic transport is an existing export. Native
`singleChoice` has `choices`, not semantic Boolean/default keys. Native grammar
Booleans configure requiredness/compositeness. The new semantic layer must lower
to accepted native options without adding unknown keys. Preserve plain native
authoring and explicit UID declarations. Generated grammar, daemon startup and
observed readiness are separate steps, documented in setup alongside the
canonical examples.

## Proposed readable surface

`g = grammar.dsl` is existing native authoring; `s = schema` is a new semantic
schema/type layer; `c = constraint` is a new typed constraint-description DSL.
Functions below are proposal spelling synchronized to the public DSL vocabulary,
not installed APIs:

```nix
{ grammar, schema, constraint }:
let
  g = grammar.dsl;
  s = schema;
  c = constraint;
in
s.grammar "reference" ({ elements, views, ... }: {
  elements.FOO = self: {
    fields = [
      (g.field.required (g.field.str "UID"))
      (s.field.boolean "FLAG" {
        required = true;
        default = s.default.literal false;
      })
    ];
    relations.H.parent.reverseRole = "H_back";
    relations.R.parent = {
      reverseRole = "R_back";
      constraints.targetType = rel: c.isNodeType rel.target self;
    };
  };
  views.H = c.forest {
    nodes = elements.FOO;
    edges = [ elements.FOO.relations.H.parent ];
  };
  views.visibility = c.boundaryVisibility {
    hierarchy = views.H;
    closed = node: c.fieldValue node elements.FOO.fields.FLAG;
  };
})
```

This is a surface fragment, not the complete canonical reference policy: it
deliberately omits BAR, baseline, other constraints and the required all-role
native DAG declaration. Use the companion complete source for the assembled
example. A field has ordered native lowering plus separately identified semantic
metadata. Constraint callbacks return tagged descriptions; raw Nix
`true`/`false` where a predicate is expected must fail. Defaults accept actual
typed values, not predicate expressions.

Named relation constraints quantify over existing occurrences.
`cardinality = c.exactly 1` checks all owner collections, including empty ones.
BAR's P/Q counts precede its record-level path predicate;
`c.only record.relations.P.parent` requires the explicit singleton guarantee,
and visibility `canDescend` checks the upper/lower targets. Preserve native
upper → BAR → lower connectivity. A common hierarchy is optional policy for
other native tailoring consumers.

External `c.on elements.FOO.relations.R.parent { targetType = rel: ...; }` uses
the same mechanism and contextual identity as adjacent constraints. Independent
contributions are lists, so keyed authoring cannot erase duplicate/conflict
evidence before composition. No initial fluent/functor sugar is required. Type
references and runtime node references remain distinct; owner/target names
describe authored relations, parent/child describe normalized direction.

## Common configuration and extension

The common layer is fully Nix-configurable. Schema assembly returns
`{ elements; views; normalized; rendered; }`; handles are not serialized.
`normalized` contains checked native `grammar`, `semanticTypes` and `bundle`
declaration/rule/view lists. Common configuration adds inputs, implementation
registrations and explicit bindings. Metadata fields use
`{ field; native; semantic; default; }`; schema `/v1` identifies the version,
with a digest over schema and ordered fields. Defaults lower to
`{literal = value;}` or `{script = {argv; timeoutMs;};}`. Consumer DSLs may emit
their own versioned contract/config and implement it in Python, Rego, Rust, Bun
or another enabled tool through the same JSON invocation route. Shipped helpers
have no private evaluator privileges. The generic host need not know a forest or
predicate algorithm; selected implementations honor the named contract or reject
unsupported capabilities.

| Surface                            | Responsibility                                                                                                                             |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Semantic schema/types              | Validate declarations, retain field/type/default identity, emit native grammar and semantic metadata.                                      |
| Constraint DSL                     | Bind finite contextual declarations and symbolic subjects; lower predicates, counts, views and explicit dependencies.                      |
| Direct normalized rule/view        | Declare versioned meaning, config, scope, inputs, prerequisites and required capabilities.                                                 |
| Checked composition                | Deduplicate equivalent definitions with provenance; explicit digest-guarded replacement/disable; reject conflicts and broken dependencies. |
| Implementation/source registration | Identify artifact, schema, runner and capability; capture inputs or evaluate through common JSON.                                          |
| Capture integration                | Select one Scribe atomic batch, a standalone fixed snapshot or a Git staged tree; no public multi-call transaction framework.              |
| Structured result helpers          | Build satisfied/violated/blocked/error results with contextual findings, causes and useful evidence.                                       |

Model/document/change rules retain before, candidate, baseline and captured
facts as distinct inputs. Model-wide dependencies are not reduced to the edited
element because authoring is adjacent. Preservation explicitly compares
existence, element/type, selected field presence/values and owned relations;
alternate projections remain consumer policy. Independent field/custom endpoint
representations must state their resolution, traversal and any virtual union-DAG
policy without claiming native export parity.

## Defaults and runtime boundary

A semantic field may declare a typed literal or runtime script default. Apply
only to newly created records still absent after ordered explicit operations;
never backfill existing records. Preserve false/empty, treat invalid supplied
data as error and distinguish successful empty script value from failure.
Resolve once before validation, never during Nix evaluation or again at
publication. Identity defaults author data, not authentication.

A Scribe invocation prepares one private candidate from a stable base, defaults,
freezes final bytes/paths/membership and effective inputs, completes
native/semantic validation, then reports dry-run or publishes exactly it.
Validators read fixed authority and may write identified derived caches.
Ordinary refusal discards private state; actual publication failure restores or
blocks. A Git refusal preserves the edited index/worktree. C1–C4 in
[interface](gate2/interface.md) and [closing plan](gate2/closing-plan.md) retain
qualification requirements.
