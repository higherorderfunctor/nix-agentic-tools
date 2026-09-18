# Readable constraint DSL: Gate 2 recommendation

Use declaration references and named constraints. Keep `g = grammar.dsl` for
existing native constructors, introduce `s = schema` for typed declarations, and
introduce **new** `c = constraint` for deferred graph predicates. All new names
remain proposed. The complete source is [recommended.nix](../recommended.nix);
it is evaluated by an isolated prototype, not installed or enforced by Scribe.

## What the reader sees

The source starts with the visible obligations of BAR: Parent P and Child Q each
require exactly one FOO endpoint, and a record constraint compares the two
endpoint targets. It then declares unrestricted BAZ and FOO with ordered
UID/Boolean FLAG fields, FOO-owned target predicates, reusable H forest and
Boolean boundary visibility. The global native all-role DAG and explicit
baseline projection stay visible.

`self` and `elements.FOO` identify a declaration. `rel.owner` and `rel.target`
identify runtime records. `c.isNodeType rel.target self` compares the target's
type to that declaration; `c.sameNodeType rel.owner rel.target` compares
endpoint types; `c.eq rel.owner rel.target` compares record identity. Nix `==`,
`&&` and `if` do not become runtime operations. A raw Boolean callback result is
rejected; `c.constant true` expresses an intentional constant.

Fields remain lists to preserve grammar order; handles are keyed by the declared
field title. Parent ownership and direction stay distinct:
`FOO owns Parent H -> parent` becomes parent → FOO, while BAR's Parent P/Child Q
remain upper → BAR → lower. A reverse label never creates an authored reverse
edge.

## Small lesson cases

These rows state the reviewed semantics. The evidence column distinguishes what
this bounded packet executes from future runtime obligations.

| Lesson             | Declaration and input                                                     | Decision and diagnostic                                                                                                         | Evidence here                                                                                              |
| ------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Target             | FOO R targets FOO; F1a R → F2 versus F1a R → Z0:BAZ                       | G01 satisfied; G02 violated, expected FOO/actual BAZ, contextual selector and both endpoints                                    | Executed two local target entry implementations with equal contextual findings                             |
| Scope              | BAZ Z0 owns Parent R → I0                                                 | G03 unaffected by FOO's same-spelled R rule                                                                                     | Executed with restrictive G02 control                                                                      |
| Cardinality        | BAR M has P → F0 and no Q                                                 | Q count violated with observed 0; endpoint path blocked by Q count ID                                                           | Executed final-snapshot count/path controls; no batch mutation execution                                   |
| Forest             | H selected, multiple/isolated roots; BAR adds another native parent to F2 | Valid H forest; BAR is not an H parent. Two distinct H parents or selected cycle violate                                        | Declaration lowering executed; forest validator is a contract case                                         |
| Boolean visibility | F1a R → closed F2 versus F2a below it                                     | T01 permits the closed endpoint; T02 identifies boundary F2 and original origin F1a                                             | Executed path function over supplied valid forest                                                          |
| Bridge             | M P → F0, Child Q → F2 versus F2a                                         | T06 permits endpoint; T07 reports first blocked boundary. Both cardinalities remain explicit                                    | Executed record path and cardinality rules over supplied valid forest                                      |
| Preservation       | Baseline S1 captures I0 FLAG=false; candidate FLAG=true                   | E01 reports baseline identity and old/new FLAG; complete empty S0 permits this change                                           | Lowering executed; preservation decision is a handwritten contract case                                    |
| Native tailoring   | Intermediate STATEMENT has Parent P/Child Q, no path rule                 | Endpoint counts/types and all-role DAG apply; no common-hierarchy policy inferred                                               | [native-tailoring.nix](../native-tailoring.nix) checked/rendered; no runtime enforcement                   |
| Alternative        | BAR UPPER/LOWER are UID fields                                            | Resolve both explicitly and require FOO; selected path plus explicit union-DAG virtual connectivity if retaining bridge meaning | [field-alternative.nix](../field-alternative.nix) lowered; resolver/runtime is a handwritten contract case |

Ascent is unrestricted. Descent may target a closed node; it may expand that
node only when the **original origin** is in that boundary's subtree, including
itself. Nested boundaries retain the original origin. Changing a boundary or
ancestry therefore requires rechecking unchanged references. Other native roles
cannot create H ancestry. Calling the native DAG check remains a requirement
declaration, not evidence that the known named-role integration gap is solved.

The preservation projection explicitly includes existence, element identity,
selected field presence/values and owned relation facts as sets. Incoming
relations, location and runtime bookkeeping are excluded. There is no implicit
supersession exception. Independent providers still pass through the same public
captured-input/result boundary; the readable DSL does not create a privileged
shipped route.

## Composition and singleton behavior

[composition.nix](../composition.nix) supplies an external `c.on` callback and a
direct normalized equivalent. They have exactly the same rule, context and
identity as the adjacent constraint. Independent contributions remain lists
until conflicts are checked; schema declarations also contribute individually,
so keyed schema construction does not license merging independent modules with
`//` first. Equivalent definitions retain all origins; conflicting definitions
reject. Explicit digest-guarded replacement/disable is checked against the
original set and must preserve dependencies.

Compound predicates lift nested hierarchy inputs and validity/count dependencies
into the rule, so a nested visibility consumer cannot outlive a disabled forest.
Required native DAG descriptors also retain the known all-role contract, empty
config, model scope, candidate input and required capabilities; an always-true
replacement cannot preserve the reference invariant merely by retaining its ID.
Unknown custom-contract compatibility remains future work.

A relation predicate quantifies over existing authored occurrences; an empty
selection can satisfy it. Cardinality quantifies over every owner record's
collection, including zero. A record predicate sees each relevant record.
`c.only` requires an explicit exactly-one declaration and records its
dependency; it adds no hidden cardinality. A failed count blocks the record
path. Replacing the count with a weaker guarantee is rejected. Generic predicate
interpretation and arbitrary custom-contract dependency compatibility remain
outside this bounded implementation.

## Creation defaults and batches: contract examples only

A Boolean literal default is `s.default.literal false`; a string literal default
is `s.default.literal "false"`. They are not interchangeable. A proposed
identity script default uses
`s.default.script { argv = [ "/configured/bin/git-identity-default" ]; timeoutMs = 1000; }`;
this path is illustrative, not a packaged executable. Its successful payload
fragment is `{ "status": "ok", "value": "" }` for an empty string. The complete
proposed provider envelope also carries the protocol and request ID; failures
use a structured error response. Nonzero exit, timeout, malformed output or
wrong typed value is a provider error. Authored identity is data, not
authentication.

Fill only fields still absent on newly created records after ordered operations.
Preserve explicit false/empty values and reject supplied invalid data rather
than replace it. Do not backfill existing records. Resolve each provider once
per prepared candidate; a real write publishes that candidate without replaying
mutations or rerunning defaults. A later separate invocation is a new
preparation.

B01 creates M and then its required P/Q relations in one private ordered batch.
B03 removes Q=F2 and adds Q=F1, or reverses those operations; validity concerns
the final one-Q state. B02 stops without Q and refuses publication. These are
future authoring integration contracts; the runtime probe checks their final
snapshots only. Dry-run and publication share preparation, complete
native-plus-semantic validation and stable base checking. Native/semantic
refusal discards the unpublished candidate. Publication failure retains
restoration or recovery-required handling. Validators may write derived
caches/scratch keyed by actual inputs but cannot mutate authoritative
candidates, baselines or accepted state.

## Evidence and limits

The Nix probe forces serialized output, calls the actual allowlisted native
grammar checker and renderer, and exercises valid/invalid semantic option types
and references. It is not a parse-only demonstration. The JSON carries finite
IDs instead of closures or recursive builders. Boolean metadata retains
encode/decode, presence, multiplicity, typed default and digest; the native
grammar stays `SingleChoice(false, true)`. The Python decoder rejects missing,
multiple, unknown, empty, TBD and TBC values. Native acceptance of TBD/TBC would
not override semantic typing.

Target parity uses two small local entry implementations named shipped-style and
independent. They share an explicit input prerequisite for model-qualified
NodeRefs, duplicate identities and owner/target resolution, then perform
separate selection/membership checks. Missing owners cannot become an empty
selected set. A later input error retains earlier target findings. The local
result validator checks typed RuleResult/Finding structures and evaluation
identity before aggregation; its supported subjects are NodeRefs and its
locations use integer coordinates. They are **not shipped runtime code or
process-transport integration**. Findings match after accounting for the
deliberately different producer IDs. Forest validity is a supplied prerequisite
fixture; paths do not prove forest extraction/validation. No preservation
implementation, field resolver, default provider, batch engine, native runtime
validation, caching, publication or Scribe integration is claimed. The generic
predicate IR is lowered and checked but not interpreted by this harness.

The production path still needs real public Nix-to-Scribe negative controls,
unchanged-state/reload evidence, complete native all-role DAG conformance,
semantic metadata transport, default acquisition, batch isolation and shared
candidate publication. No later gate is started here.

## Review choices

Review the vocabulary and readability, path-derived identity spelling/escaping,
and whether to expose a generic predicate IR immediately or keep it an
implementation boundary. The proposed constructor names and schema tags remain
open. Typed Boolean intent, creation-only defaults, one-invocation batches and
checked composition are accepted direction, not reopened choices.
