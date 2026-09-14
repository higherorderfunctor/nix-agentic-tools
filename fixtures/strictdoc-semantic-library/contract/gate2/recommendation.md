**Recommend a policy library beside the existing grammar DSL, backed first by
Python with rustworkx and StrictDoc's own parsing/native checks.** Offer OPA as
an optional public adapter for consumers who want Rego. Do not require a
database or a universal query language. Start with complete evaluation; add
incremental maintenance only against that correctness reference.

This is the final Gate 2 recommendation, **not approval or implementation of
Gate 3**. Every new signature/option is proposed. The [contract](interface.md),
[complete Nix declaration](recommended.nix),
[playbooks and coverage](playbooks.md), and [findings](findings.md) make the
recommendation reviewable. The [reviewed requirements](reviewed-requirements.md)
override older pending labels in the reference packet.

A consumer should be able to write this beside its native element declaration
(excerpt from the proposed contract; `p`, `g` and `foo` are library/element
bindings in the complete example):

```nix
p.element {
  native = g.el "FOO" {} {
    fields = [
      (g.field.required (g.field.str "UID"))
      (g.field.required (g.field.one "FLAG" ["false" "true"]))
    ];
    relations = [
      (g.rel.parent "H" "H_back")
      (g.rel.parent "R" "R_back")
    ];
  };
  policies = self: [
    (p.targets {
      id = "reference/R-target";
      select = self.parent "R";
      allowed = [foo];
    })
  ];
}
```

Here `R` is scoped to this grammar, owning element and Parent direction. It does
not constrain another element's `R`. The wrapper returns native grammar data and
separate policies; it does not insert semantic keys into StrictDoc's grammar
format. A plain descriptor has the same supported meaning as the helper.

The consumer wiring has three responsibilities. `ai.strictdoc.policy` names the
model and bundles to apply, including graph, document and change rules.
`ai.policyRuntime` registers implementations and input tools and explicitly
assigns rule contracts to them. `ai.validation.boundaries` selects daemon
transactions, staged-tree commit checks, or both. These are proposed module
conveniences over the same library contract, not three compulsory services.

Dependencies explain what a rule needs. A target check needs resolved candidate
records. Visibility also needs a valid selected forest. A preservation rule
needs a complete captured baseline. A document approval rule can read the whole
model and immediate before state. Missing data blocks dependent checks; neither
file placement nor the set of touched records limits semantic scope.

For the reference visibility rule, a closed endpoint remains reachable from
outside, but its interior does not. An origin already inside may reach peers or
leave; a closed start counts as inside. A move or closure rechecks affected
unchanged links over the selected forest. These helpers encode explicit consumer
choices, not meanings imposed on every field or native relation.

Package the descriptor/schema machinery, contextual handles, useful target,
forest, visibility, endpoint and preservation helpers, and adapters. Consumers
choose their grammar, selected roles, closure meaning, frozen projection, main
ref, identity authority, approval rules, supersession exceptions and validation
boundaries. Shipped and independent adapters register the **same descriptors**;
no package name grants authority or selects an implementation automatically.

The independent designs substantially agree on behavior and layering. These are
the exact differences worth adjudicating, rather than a choice between two
unrelated architectures:

| Issue                    | Ideal design                                           | Tool-informed design                                               | Recommendation                                                                                                                                                      |
| ------------------------ | ------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Adjacent authoring       | `p.attach` plus explicit handles                       | `c.element`/`c.grammar` bind `self`                                | Use the adjacent wrapper; preserve separate plain bundles and selectors. Mostly ergonomics.                                                                         |
| Implementation selection | Contract kind plus explicit registry assignment        | Raw rule embeds `backend` and `entry`                              | Prefer contract-to-entry binding; direct native programs declare their own contract. Ordinary helpers do not hardcode the graph adapter.                            |
| Record identity          | `(model namespace, UID)`                               | `(grammar, UID)` within model; projection key omits model          | Use `(model, UID)`; retain grammar on records and selectors. Freeze resolver/schema details before implementation. Material cross-grammar difference.               |
| Forest helper            | View plus forest-validity rule; target checks separate | View/bundle also supplies target prerequisites                     | View plus membership/forest rule; explicit authored target rules remain visible. Document expanded IDs.                                                             |
| Native DAG               | Required model/integration capability                  | Explicit `nativeDAG` descriptor plus boundary prerequisites        | An inspectable required rule across all Parent/Child roles, implemented via qualified native reuse. Neither a silent capability label nor a removable prerequisite. |
| Group completion         | Explicit sealing; readiness optional policy            | Example requires coordinator after all participants ready          | Core revisioned staging and authorized seal; all-ready is an optional group policy. No timeout-implied readiness.                                                   |
| Tailoring                | Example includes a selected requirement hierarchy      | Separates familiar tailoring from optional hierarchy path          | Keep native Parent/Child tailoring; apply the reference downward-path rule only where that hierarchy was deliberately modeled.                                      |
| Field alternative        | Endpoint/path parity; union DAG discussed              | Example requests virtual union DAG                                 | Support both explicitly; union edges remain derived and do not confer native exports or owned-link projection equivalence.                                          |
| Runtime delivery         | Backend-neutral, intentionally undecided               | Python/rustworkx first; optional OPA; four registration categories | Adopt the measured direction; embed runner details in public registrations initially, without mandating separate runtime services.                                  |

Sources: frozen [ideal design](alternatives/ideal/design.md) and
[Nix](alternatives/ideal/examples.nix), frozen
[tool-informed design](alternatives/tool-informed/design.md) and
[Nix](alternatives/tool-informed/examples.nix). Their
[freeze](provenance/ideal-freeze.json)
[records](provenance/tool-informed-freeze.json) attest independent inputs; the
second design's v2 edit updated evidence only.

The backend choice rests on capability and measured cost, not Python
familiarity. The [actual programs](research/experiments/scripts/finalists.py)
compare three implementations against an independently normalized NetworkX path
oracle. V2 includes ten literal Parent and ten literal Child expectations,
boundary and selector changes, and subtree moves: 30 evaluator comparisons plus
four other capability records. These establish useful graph-library, Rego and
recursive Datalog routes, not 44 integrated acceptance cases or complete
diagnostics. [Results](research/experiments/results/finalists.json),
[rustworkx API](https://www.rustworkx.org/apiref/rustworkx.PyDAG.html).

The bounded full-evaluation medians below include adapter construction; OPA also
includes CLI startup/JSON. Versions: rustworkx 0.18.1 on CPython 3.13.15, Cozo
memory 0.7.6, OPA 1.20.2. Each cell has one query over a synthetic graph; these
are not all-rule Scribe latencies.

| Nodes / shape | Python/rustworkx |     Cozo memory |         OPA CLI |
| ------------- | ---------------: | --------------: | --------------: |
| 1,000 deep    |          1.96 ms | budget exceeded |        47.01 ms |
| 1,000 wide    |          0.86 ms |        20.07 ms |     1,425.98 ms |
| 10,000 deep   |         75.14 ms | budget exceeded |       369.16 ms |
| 10,000 wide   |         10.03 ms |       242.03 ms | budget exceeded |

The eight-second budget covers three runs plus controls; it is not a per-run
latency. Full ownership projection, Scribe parsing, providers, Git and
publication are absent. The tiny ten-query Bun/Wasm workload's 0.24 ms warm
median and 2.53 ms load are a different measurement.
[Cost script](research/experiments/scripts/cost_probe.py),
[raw costs](research/experiments/results/cost.json),
[Wasm samples](research/experiments/results/opa-bun.json).

OPA earns an optional adapter because the executed Rego itself expresses
origin-sensitive traversal and runs under Bun/Wasm; a separate host traversal
service is unnecessary. Require strict CLI built-in errors and complete,
validated outputs. `graph.reachable_paths` has separate SDK requirements, and
path diagnostics still need implementation.
[Actual Rego](research/experiments/scripts/policy.rego),
[OPA graph documentation](https://www.openpolicyagent.org/docs/policy-reference/builtins/graph).
Cozo's public callbacks work, but its deep-query costs, old recorded release and
blocked memory read behind a writer weaken its default case. Its transactions
are not a Scribe publication solution.
[Lock result](research/experiments/results/cozo-lock.json),
[pinned lock implementation](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-core/src/storage/mem.rs#L40),
[release](https://github.com/cozodb/cozo/releases/tag/v0.7.6).

Native StrictDoc already supplies parsing, endpoint resolution, Parent/Child
connectivity, multiple roots/parents, and the documented compliance/adaptation
pattern. **The proven gap is named-role cycle coverage.** At pinned 0.28.3,
Parent-only, Child-only and mixed named cycles pass while unroled counterparts
fail. The callback forwards `edge=None`; all-role lookup requires `.all`.
[Native controls](research/experiments/results/native.json),
[pinned forwarding source](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph_database.py#L56),
[bucket behavior](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph/many_to_many_set.py#L43).

Explicit all-role selection makes the existing detector reject the tested mixed
cycle. Prefer repairing/reusing that path over a permanent duplicate native
validator. Source hashes also match the packet's observed upstream main; main
was not separately executed. Scribe still needs complete-candidate validation
and refusal/reload integration.
[Scope probe](research/experiments/scripts/native_scope_probe.py),
[result](research/experiments/results/native-scope.json),
[source verification](provenance/native-source-verification.json),
[upstream tailoring example](https://github.com/strictdoc-project/strictdoc/blob/b56ebb266c0a58f016c3be6ed5337c8a9833be0e/docs/strictdoc_01_user_guide.sdoc#L2347).

Retain the explicit [v2 corrections](research/evidence-corrections-v2.md): v1
did not test a selected Child hierarchy or unchanged protected content under a
nonempty baseline. V2 corrects both. OPA's 1,000-wide cost rose from about 268
to 1,426 ms; the old result must not be substituted. The
[composed replay](research/experiments/results/combined-v2.json) passed on the
producer's existing host dependencies; I inspected, but did not rerun it.

Separate later
[runtime-pairing evidence](runtime-pairing/outputs/host-probe-result.json) shows
CPython 3.14.6, StrictDoc 0.28.3 and rustworkx 0.17.1 load together on
x86_64-linux using StrictDoc's interpreter and a temporary combined-closure
`PYTHONPATH`. CLI dependency imports and synthetic normalization/DAG/path
controls pass; native parser/validator integration was not exercised. Earlier
benchmark versions/results are unchanged. [C4](interface.md) still requires
production packaging/platform/native integration qualification. Other entry
conditions remain: schemas, capture, trusted facts and publication/recovery. No
Scribe, authentication, file/Git atomicity or incremental guarantees follow.

At the next human gate, settle three choices:

1. Accept this public shape: adjacent helpers, plain contracts, public
   registrations, explicit bindings, and independently selected validation
   boundaries.
2. Accept Python/rustworkx plus native StrictDoc reuse as the first
   implementation direction, with OPA optional and full evaluation as the
   initial reference.
3. Confirm the first slice is a real target-type refusal through Scribe, with
   unchanged bytes/held state and reload evidence; require the listed schema,
   capability and publication plan before that implementation begins. Grouped
   daemon and staged-tree hooks remain required later deliveries.

Detailed repository projections, trust providers, UI, group readiness presets,
crash protocol and optimization can be decided at their implementation slices;
they are not universal lifecycle rules. Preserve the
[closing plan](closing-plan.md): remove generic Scribe's repository field
policy, leave no `AUTHORED_BY`/`PARENT_FP` content anywhere in final neutral
fixture scope, express repository policy through public extensions, and verify
every human/steering recipe before landing. Keep these materials out of the SDoc
canon. This package stops at Gate 2 review.
