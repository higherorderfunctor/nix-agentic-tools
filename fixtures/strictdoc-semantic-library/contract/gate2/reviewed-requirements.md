# Gate 2 reviewed requirements and authority

The user explicitly authorized Gate2 on2026-09-13 after a plain-language
behavior review. Scope is recommended public interfaces, supporting pluggable
libraries/backends, and experimental evidence. Gate3 production implementation
is NOT authorized. Deliver a recommendation for the next human review. Older
contract copies marked PENDING do not revoke the recorded Gate 2 authorization.

The 2026-09-15 user handoff authorizes this revision and supersedes conflicting
lifecycle, Boolean-gap and old authoring requirements. See
[scope reconciliation](scope-reconciliation.md). The original independent
design/research comparison is retained history, not a research restart. Current
exact names remain proposed; accepted behavioral direction does not imply Gate 3
authorization.

## New semantic types and creation defaults

Add a distinct validated semantic-type option layer above existing native
normalization. Emit both native grammar and identified/versioned semantic
metadata through the common engine payload. Defaults and predicates refer to the
same grammar/element/field identity. Boolean encode/decode is canonical
false/true; presence, scalar multiplicity and invalid input remain distinct from
false. Native string-list snapshots may remain; native grammar `required` and
`isComposite` are not document Boolean types. Reject unknown Boolean text,
including native placeholder values when encountered, rather than silently
coercing it.

Literal or runtime-script defaults fill only still-absent fields on records
newly created in the current invocation after ordered explicit operations.
Preserve false/empty; invalid supplied values are not replaced. Successful empty
script values differ from empty/malformed/nonzero/timeout failure. Resolve once
per candidate; no Nix evaluation-time acquisition, existing-record backfill or
publication replay. Keep default teaching simple and separate from
semantic-backend invocation. See the exact proposed [interface](interface.md).

## Native model and extended policies

- Reuse StrictDoc's existing graph/traceability model and native checks where
  possible. The user expects much of multiple-root/acyclic Parent/Child behavior
  to be native; distinguish native guarantees, custom role-selected hierarchy
  constraints and integration gaps at specific revisions. One-node-per-document
  is this consumer's packaging, not the semantic model's definition of ancestry.
- Native Parent and Child authoring are both allowed. Preserve authored owner,
  target, type, role and model context. Parent/Child direction determines
  connectivity; reverse display names do not manufacture authored edges. The
  complete native graph must remain acyclic. Extra relations do not
  automatically become the chosen hierarchy.
- Selected relationships may restrict target types. Selector names are
  contextual, not globally unique strings. Selected hierarchy edges form several
  independent trees, with at most one selected parent per record; other native
  parents can exist under other roles.
- The neutral reference cases use explicit false/open and true/closed. From
  outside, a closed boundary itself can be targeted but its interior cannot be
  traversed. From inside that boundary, an origin can reach internal peers or
  leave; a closed start counts as inside. Other nested boundaries still apply.
  The selected visibility connection stays in one tree and uses only its chosen
  hierarchy. Closing or moving records must revalidate affected unchanged
  relationships. No arbitrary depth limit.
- The reference bridge is a record owning Parent to an upper endpoint and Child
  to a lower endpoint. Keep the record as part of connectivity, upper -> bridge
  -> lower. Its reference policy requires one of each endpoint and a downward
  hierarchy path under the same boundary rules. Equal endpoints already violate
  the no-loop constraint.
- Lean into StrictDoc's documented familiar tailoring/compliance-matrix pattern
  when useful: an intermediate compliance/adaptation statement owns a Parent
  link to a standard or user requirement and a Child link to project/immutable
  OTS requirements. This is a preferred example, NOT a restriction on the
  semantic layer. Also support alternative consumer representations, including
  node fields and custom logic; plan representative examples of both approaches.

## Consumer policy, identity and external state

Everything domain-specific is consumer-defined. The library can ship useful
opinionated helpers and backend adapters, but they must plug in through the same
public consumer interface available to others. Do not hardcode FOO/BAR/BAZ or
this repository's future policies into the engine.

The motivating protection use cases include LLM changes to documents committed
to main, consumer-defined supersession, and human-authored/protected documents
requiring HITL. The user plans separate SSH identities for LLM and human and a
future TUI/web UI approval path. The engine must be able to consume
identity/external facts and enforce consumer policy. Do not treat untrusted
request labels as authenticated identity, implement SSH key management/TUI
tonight, or read users' private keys. Exact policies/projections are consumer
choices, not a universal engine rule.

The neutral reference protection example freezes listed records'
existence/type/flag/owned links, excluding incoming links owned elsewhere, file
placement and temporary runtime bookkeeping. Supersession grants no implicit
exception unless a consumer defines one. This example exercises extension
capability; it does not settle the user's eventual repository lifecycle model.

External executable/tool acquisition (e.g. Bash) is a valid extension route.
Distinguish complete empty results from errors, timeouts, malformed or
incomplete results. An evaluation uses coherent identified inputs; do not
silently mix snapshots or pass checks missing before/baseline inputs. Reference
timing captures a snapshot per evaluation, with later source changes affecting a
later evaluation; distinguish this from a latest-at-publication guarantee.

## Validation boundaries, atomic batches and recovery

One Scribe invocation carries an ordered list of operations, applied to one
private candidate. Repeated operations retain order; one write is a
one-operation batch. Create-then-edge must work. Public cross-call
begin/stage/seal/abort, participants, readiness and related coordination
machinery are removed from the initial requirement. Consumer
before/baseline/change comparisons remain evaluation-time inputs; a generic
lifecycle framework is unnecessary.

Capture a stable base, mutate privately, materialize creation defaults, freeze
candidate bytes/paths/deletions/membership and effective inputs, run complete
native and configured semantic validation, then return dry-run report/diff or
publish exactly that candidate. No hidden dry-run followed by replay or provider
rerun. Final-state counts, graph invariants and affected unchanged references
cannot be rejected merely because intermediate operations were incomplete. Audit
premature prechecks and stale derived indexes. Full validation is not a demand
for full rebuild on every operation.

Dry-run means no publication, not zero filesystem activity.
Mutation/default/native/semantic failure discards private state without document
rollback. Files, held graphs, readers, indexes and exports cannot observe
rejected speculative state. A stale base refuses. Publication failures restore
before or block further writes explicitly; success requires file/model
agreement. Qualify crash and external-reader scope rather than promise general
multi-file crash atomicity.

Validators receive identified immutable authoritative inputs read-only; derived
caches, scratch and diagnostics may be written and may survive rejection. Keys
cover actual computation dependencies, including
metadata/policy/versions/captured inputs when relevant. Cold/warm results must
agree; corruption rebuilds or errors. A cache never substitutes for the
accepted-state pointer. Declare actual extension trust/isolation assumptions;
read-only JSON alone does not enforce arbitrary host restrictions.

Git staged-tree checks remain a separate consumer-selected boundary, alone or
after Scribe publication. Capture the actual index tree with explicit
before/main and bind any reused receipt to exact inputs. Refusal retains already
edited index/worktree. A later commit refusal does not undo a published Scribe
batch. Rules preserve meaning across scheduling choices.

Invalid input remains inspectable. Reference repair requires complete final
validity; alternative admission is explicit consumer policy and cannot hide
invalidity or missing inputs. Preserve restore/reload/failure controls and
useful partial diagnostics.

## Layered public extension

The common semantic configuration must be fully Nix-configurable and
backend-agnostic. Consumer DSLs emit versioned contracts and register
implementations through the same public JSON route as shipped helpers; native
Python/Rego programs need not become a universal Nix expression language. Design
ergonomic grammar-adjacent DSL/builder/option entry points,
whole-graph/document/change policy composition, and public pluggable
implementation/backends. Use proposed schema/type `s` and new constraint DSL `c`
with finite declaration references, symbolic runtime subjects, explicit
predicate operators, cardinality and checked singleton dependencies. Reject
accidental raw Nix Boolean predicate returns. Preserve named graph operations,
ordered fields and keyed handles. Exact names and decomposition are OPEN.
Existing source/derive/check or OPA/database sketches are NOT approved
interfaces or architecture. Do not force everything into one module namespace or
invent a universal backend-native language.

Useful packaged backends/adapters must register through public consumer
interfaces. Consumers can use other libraries/programs and custom tools,
including identity acquisition or checks. Demonstrate an independently supplied
backend/tool and representative direct/lower-layer authoring. Equivalent layers
must yield equivalent decisions and meaningful diagnostics. Replace/disable
rules explicitly; conflicting definitions must not silently win by module order.
Unsupported capability must be explicit, never a silently dropped rule. Preserve
structured RuleResult/Finding, one result per invoked rule,
satisfied/violated/blocked/error distinctions, aggregate/admission separation
and contextual witnesses. Keyed module contributions must retain duplicate
evidence before checked composition.

Incremental/full evaluation must agree for identical inputs. Policy and
external-source changes can invalidate results without SDoc edits. Cache/index
data are disposable. Measure capability and cost honestly; executable escape
hatches do not guarantee free incremental maintenance, termination or
deterministic providers.

## End-of-plan obligations to track now, implement later

- After the final qualification gate and before folding this work back into
  trial: fix generic Scribe to remove mandatory repository-specific field
  policy. Neutral fixtures must contain NO AUTHORED_BY or PARENT_FP
  declarations/content. Do not disguise the same policy by merely renaming
  fields. Relocate historical evidence/notes out of fixture scope if needed to
  meet the final clean-fixture boundary. Repository policy must be expressed
  through public consumer extension mechanisms, including tools if appropriate.
- For ALL behavior families, prepare recipes/playbooks beyond test fixtures:
  readable human Markdown and content suitable for inclusion in generated agent
  steering. Include native Child-tailoring and alternative field/custom-logic
  styles. Gate2 can draft honest design examples and a coverage/delivery plan;
  final runnable recipes must be verified against implementation before landing
  after the last gate. Steering module placement is deferred. Do not move the
  material into SDocs yet.
- No WORK/MECH/DEC nodes, no edits under docs/spec or docs/plans. Eventually
  this repository may adopt SDocs as truth after machinery exists; do not
  reproduce the old drifting corpus during design.

## Runtime constraints and review boundary

No JVM. SQLite is strongly disfavored, not a hard ban; any case for it needs
compelling evidence. Python, Node (prefer Bun) and Rust are acceptable. Do not
select runtime solely from familiarity. Production implementation and backend
adoption require the next review.

The Gate 2 recommendation builds on the reviewed packet, neutral reference cases
and public toolchain evidence. Distinguish proposed contracts, evaluated
lowering and source findings from installed APIs and runtime enforcement. Later
implementation must qualify the integration before claiming these capabilities;
completing the recommendation does not authorize a later gate.
