# Verified public toolchain facts

Historical verified consumer revision 8563ca852ae083609f97fb52a46c0b07272897ee;
installed code came from portable batch 2d28787d. The supplied filtered source
artifact was
`/nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source`: 19
Python files + 15 Nix implementation files + generated flake/lock, 36 files
total. Its only dependency subtree was upstream StrictDoc and its locked
dependencies; upstream StrictDoc was pinned to
7cf8183498ec87be531499230602df33523ed058. This artifact is absent in the current
process filesystem. These historical input observations are not a current
artifact replay or future design authority. The
[normalized authoring evidence](normalized-authoring/README.md) separately
qualifies current checked-in public-library evaluation.

Public exports: devenvModules.nix-agentic-tools; lib.ai.strictdocGrammar {lib};
packages.<system>.strictdoc (same upstream package). Public ai.strictdoc
options: enable, package, grammars (target/elements),
scribeSource(installed/project). Installed mode supplies strictdoc,
strictdoc-grammar-extract Python runner, scribe, scribe-client, scribe-daemon.
Project mode includes repository-local code/board; do not use it for semantic
design/probes.

Grammar library public attributes are `check`, `dsl`, `emit`, `normalized`, and
`render`. The DSL already constructs normalized tagged attrsets: `el`; fields
`many`, `mk`, `one`, `raw`, `required`, `str`, `tag`; and `child`, `file`, `mk`,
`parent`, `raw` relations. Nix booleans apply to grammar attributes `required`
(emitted as `REQUIRED`) and `isComposite`; there is no Boolean document-field
constructor. Choice options remain strings. The `raw` constructors are
identities over normalized values and do not bypass checks or unwrap faithful
constructors. `render` checks normalized elements and passes the result to
`emit.grammar`, which composes denormalization and SGRA rendering. Supported
presentation metadata survives this path; arbitrary field metadata is not
accepted. See the [probe and controls](normalized-authoring/README.md).

There is no public semantic declaration API in this version. Do not inherit its
old project model. The reference flag's explicit strings do not establish the
user's requested Boolean document-field declaration, encode/decode, or metadata
contract; that gap remains for design review.

Normal consumer flow: declare grammars; generate:sgra writes artifact; start own
per-root scribe daemon with devenv up -d scribe; scribe-client
ping/info/show/check/reload and scribe mutations use its socket. Readiness needs
a bounded retry. The root/config/grammar and file inclusion are consumer-owned.
New documents currently import @repo; a grammar-loaded empty seed is needed
before first new. Node-per-document is current authoring behavior, not a
semantic ancestry constraint.

The installed runtime currently hardcodes guarded AUTHORED_BY/PARENT_FP field
names; loaded grammar must collectively declare both. New injects
AUTHORED_BY=llm; per-element declarations/requiredness are not both enforced by
that global guard. These temporary integration accommodations are NOT policies
to copy into the new design; removal is an end-of-plan obligation.

Observed native integration (existing neutral black-box probes, not claims about
upstream main): 10 nodes/11 docs and reload/cold restart work; serialized
individual writes; an RPC array can persist its first successful operation
before a second refusal; mixed Parent/Child cycle case was accepted; custom
target/visibility/cardinality are unimplemented. Classify native/integration
gaps rather than weakening desired validity. Do not claim existing serialized
writes establish multi-edit atomicity.

The supplied reference contract files are older drafts. The
reviewed-requirements packet overrides their blanket pending labels and
incorporates latest user direction. Exact sketches/signatures are intentionally
omitted to avoid anchoring independent interface design. No worker should
consult contract/surfaces.md or prior exploratory design.
