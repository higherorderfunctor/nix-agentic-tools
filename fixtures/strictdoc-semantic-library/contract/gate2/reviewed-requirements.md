# Gate 2 reviewed requirements and authority

The user explicitly authorized Gate2 on2026-09-13 after a plain-language
behavior review. Scope is recommended public interfaces, supporting pluggable
libraries/backends, and experimental evidence. Gate3 production implementation
is NOT authorized. Deliver a recommendation for the next human review. Do not
request approval again merely because older contract copies say PENDING.

The user required independent design paths: an ideal public interface without
backend-research influence; separately, tooling research followed by an
interface designed with those tools in hand. Those paths MUST NOT see each
other's prompts, drafts, notes or outputs until comparison. This packet is
shared reviewed input, not either design.

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

## Validation boundaries, transactions and recovery

The user explicitly requires flexible consumer-selected validation boundaries:
daemon-enforced transactions, Git commit hooks, or both, including a transaction
followed by a commit. Serialized daemon writes are not proof of a
multi-operation transaction. Parallel agents editing parts of one change need a
deliberate way to group work and decide when extended rules validate.

Keep prior requirements while adding this flexibility. Rules describe validity
over the selected state/change and captured inputs; invocation/scheduling
changes when and over what candidate those rules run, not their mathematical
meaning. The reference strong transaction validates complete final candidates
and permits private incomplete staging. Semantic refusal leaves authored
files/observable state unchanged. Publication failure restores prior state or
explicitly blocks writes pending recovery; no false success. Do not claim a
sidecar transaction makes Scribe/files/Git atomic.

Invalid input remains inspectable and diagnosable. The reference repair policy
requires a valid complete result; consumer policy and boundary choices should
remain expressible rather than being hardcoded to this one repair strategy.
Raise genuine remaining ambiguities in the recommendation rather than dropping
earlier intent or treating tired paraphrases as cancellations.

## Layered public extension

Design ergonomic grammar-adjacent DSL/builder/option entry points,
whole-graph/document/change policy composition, and public pluggable
implementation/backends. Exact names and decomposition are OPEN. Existing
source/derive/check or OPA/database sketches are NOT approved interfaces or
architecture. Do not force everything into one module namespace or invent a
universal backend-native language.

Useful packaged backends/adapters must register through public consumer
interfaces. Consumers can use other libraries/programs and custom tools,
including identity acquisition or checks. Demonstrate an independently supplied
backend/tool and representative direct/lower-layer authoring. Equivalent layers
must yield equivalent decisions and meaningful diagnostics. Replace/disable
rules explicitly; conflicting definitions must not silently win by module order.
Unsupported capability must be explicit, never a silently dropped rule.

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

## Hard constraints and work discipline

No JVM. SQLite is strongly disfavored, not a hard ban; any case for it needs
compelling evidence. Python, Node (prefer Bun) and Rust are acceptable. Do not
select runtime solely from familiarity. No production implementation, merges, or
backend adoption without the next review.

Workers must NOT read existing grammar values, old semantics module,
docs/spec/plans, or the coordinator scratchpad. Only the supplied reviewed
packet, neutral reference cases and filtered public toolchain may inform design.
Tools can access the shared host; these are explicit context/read boundaries,
not a claimed filesystem sandbox.

Write every finding/output/progress milestone durably. Use gpt-6-astra with
explicit effort: high for design/research judgement/review, medium or low for
bounded mechanical extraction/experiments. Format edited Markdown/Nix with
treefmt. Use full standalone Bash strict mode. Never run broad flake
checks/package builds; any Nix builds are serial and coordinated with the
research lead. No messages to other humans or external writes.
