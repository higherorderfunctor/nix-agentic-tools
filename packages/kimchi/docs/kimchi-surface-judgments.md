# Kimchi surface judgments

`surface-judgments.json` records reviewed interpretations of measured evidence.
A red check means **ask a session to investigate and rejudge**. CI never calls a
model, rewrites a verdict or refreshes a recorded hash. A matching evidence hash
establishes that the reviewed evidence is current; reviewing the proposition,
scope and rationale remains a session's responsibility. A judgment cannot
replace a measured fact.

## Declared hosted LLM gateways

The hosted-gateway family is the distinct `region` keys in measured
`regionRegistry.fields` rows whose `field` is `llmBaseUrl` and whose value is
anything except `""`. This includes `<unresolved>`: a session can classify that
root with an explicit unknown record. The empty self-hosted placeholder is
outside the family. Giving it a value creates a new member. This is coverage of
static declarations, not runtime overrides, computed registries, callers,
requests or deployed services.

Every discovered root needs exactly one judgment. A new root fails as
unclassified. A judgment whose root disappears fails until a person removes the
record. Unknown satisfies classification coverage and has the same evidence
freshness requirement as supported or refuted; it never counts as supported. The
initial EU judgment is unknown because the client-derived URL does not establish
server availability. The US judgment supports direct URL construction only,
excluding effective configuration, callers, execution and availability.

The file's closed schema is `{schemaVersion: 1, judgments: [...]}`. Each
hosted-gateway record requires `id`, `claim`, `scope`, `packet`, `evidenceHash`,
`verdict` and `rationale`. IDs are unique descriptive lowercase kebab-case.
Verdicts are `supported`, `refuted` or `unknown`. Unknown requires nonblank
`missingEvidence`; other dispositions forbid it. Selectors and citations live in
the packet, without duplicate metadata fields. Unknown fields and versions are
refused.

## Network request occurrences

Every distinct request occurrence in `requestCallers` is a separate judgment
root, including two calls on the same line. The Kimchi 1.26.0 measurement is 29
roots and 583 caller rows. Enumeration reads the fact independently of verdicts;
it neither searches for extra network calls nor infers execution conditions.

Each request claim has exactly four nonblank string members:

- `default`: whether the request executes with the default configuration.
- `destination`: where it goes, including configuration and overrides.
- `disable`: the controls and precedence that prevent it.
- `trigger`: the runtime event and prerequisites that cause it.

There is one overall verdict and evidence hash. An `unknown` record leaves
runtime behavior unresolved: `missingEvidence` names the unreviewed defaults,
destinations, disabling controls and triggers. Unknown records pass coverage but
must remain current. Judging a request means reviewing source evidence for all
four claim parts, citing the relevant spans, and recording the resulting
verdict, rationale and evidence summary.

A request record contains `claim`, `evidence`, `evidenceHash`, `id`,
`rationale`, `scope`, `selector` and `verdict`, plus `missingEvidence` for
unknowns. It stores neither a packet nor decoded statement text. Its compact
`evidence` contains:

- `call`: the request call expression's original-byte SHA-256 hash.
- `root`: the SHA-256 hash of the request root's canonical JSON identity.
- `rows`: one SHA-256 digest of each normalized caller row's canonical JSON,
  sorted, preserving duplicates.
- `spans`: each explicit source citation's `{path, anchor, sha256}`, sorted by
  identity.
- `statement`: the request statement's original-byte SHA-256 hash.

`evidenceHash` hashes the canonical JSON of that summary. CI recomputes it from
the current facts and pinned tree. Request summary fields have a closed schema;
row/root digests and call/span/statement hashes must be lowercase SHA-256
values. The hosted-gateway records keep their full packets and existing hash
rules.

A request selector has `fact: {kind: "requestCallers", where: {request}}` and an
explicit `sources` array. The request citation is
`{path, anchor: {symbol, role: {kind: "call", callee, ordinal}}}`. Paths are
canonical repository-relative `src/...` paths. `symbol` is a chain of
`[name, ordinal]` pairs: function names/bindings, class names, method/accessor
names, constructor names and object property keys that bind functions. Prefixes
such as `function:`, `class:` and `method:` are owned by this code, not
TypeScript enum names. Only functions with bodies and class-like nodes establish
named owners; type-only signatures and annotations do not consume ordinals.
Equal names under the same named parent receive lexical ordinals. Anonymous
functions and control-flow statements do not add owner segments; a top-level
request uses the file owner, `[]`.

The callee key includes call/new form and syntax spelling, without invocation
arguments or nested function/class bodies. Its zero-based ordinal counts
same-callee calls in the nearest named owner, through anonymous callbacks but
excluding other named owners. Thus unrelated call-free statements do not change
root identity. Renaming an owner removes the old root and discovers a new one.
Adding indistinguishable same-callee calls or same-name owners can change
ordinals and requires review. There is no line-based or similarity fallback.

The current request packet artifact includes `statement`, the exact decoded
UTF-8 bytes of the containing statement, and its span identity and hash.
Recorded evidence keeps only the statement hash; diagnostics report its old/new
hashes under `site: "request statement"`. The resolver stops at the nearest
statement before crossing a function, class or file. A return inside an if
selects that return; a request in an if condition selects the if. Concise arrow
bodies are refused rather than expanding to a surrounding declaration. Two
requests in the same statement share those statement bytes; the call hash binds
each summary to its invocation bytes and the root digest distinguishes records
even when all other evidence is identical.

Every selected caller row contributes a digest, including duplicates. The
current packet's `rows` object maps each digest to the full normalized row;
identical rows share one entry while the summary preserves their multiplicity.
Numeric locations are replaced by structural `functionSite` and `site`
identities. `library`, `distance`, `kind`, `property` and `reason` remain
evidence. The redundant per-row request anchor is omitted because the selector
already names that request. Function sites use the same named-owner chain and
`role: {kind: "owner"}`; anonymous functions inherit their named owner. Sites
use a callee role when the reported token is in a call's callee. Its key
includes callee spelling and the first string-literal argument, when present.
The ordinal counts only calls with that entire key. Thus adding
`pi.on("session_shutdown", ...)` does not move a `pi.on("session_start", ...)`
site.

Function-start tokens use `function-start`. An anonymous callback's key includes
its containing call's site role, argument position, and intervening property
names; an unrelated arrow passed to another call cannot shift it. Named starts
use their token spelling within their named owner. Other tokens use `token` and
their spelling. Residual ordinals remain for identical call keys, same-spelling
ordinary tokens, and anonymous starts without a containing call (for example a
returned arrow). Inserting an identical key earlier in the same named owner can
still move those rows and requires review. Same-name owners have the same limit.
These identities contain no source coordinates.

Facts must match the pinned source revision. Request coordinates match the exact
start **and end** of one call or new expression. `callSite.endLine` and
`callSite.endColumn` are required: a start alone cannot distinguish the outer
request in `getFetch()(url)` from the inner request in `fetch(u).then(cb)`.
CodeQL ends are inclusive and 1-based. TypeScript `getEnd()` is an exclusive,
0-based UTF-16 offset; the adapter converts `getEnd() - 1` to a line and column,
then adds one to both before comparing. Missing ends fail `REQUEST_FACT_INPUT`;
a range with no exact invocation fails `REQUEST_LOCATION`. Ends are only used to
select the invocation and never enter structural identities or packets. Function
coordinates match the original start or the start after export/default
modifiers, skipping JSDoc children and retaining async/visibility modifiers.
Site coordinates match exact token starts. The top-level sentinel resolves to
the file owner. Closed shape and primitive type validation happens before
adaptation; the adapter does not revalidate reachability, distance ranges or
reason consistency. Unmatched coordinates stop the entire input through the
existing failure path. Missing or unreadable source files named by fact rows
produce `REQUEST_LOCATION`; missing or unreadable citation files produce
`ANCHOR_MISSING` with an incomplete packet. Both retain the usual diagnostics
and artifacts.

Explicit request citations use
`{path, anchor: {symbol, role: {kind: "node", steps}}}`. Each `[key, ordinal]`
step selects a direct syntax child of the previous node, starting at the named
owner. Keys include `name:<spelling>`, callee keys, `bindings:<names>`, keyed
object entries `entry:id:<spelling>` or `entry:name:<spelling>`, and the fixed
labels `block`, `list`, `node` and `token` (all leaf tokens). JSDoc children are
skipped. These steps can select registration arguments, resource entries,
properties, return statements and precedence conditions. Final files, blocks,
functions, classes and their direct SyntaxList children are refused.
Intermediate nodes of those kinds are allowed. This is a node-kind restriction,
not a size guarantee: an accepted statement such as an `if` can still cover most
of a function. Reviewers choose spans proportional to the claim; there is no
byte limit. No TypeScript enum aliases enter persisted identities.

Editing call/statement/citation bytes, adding/removing a
caller/callback/boundary row, or changing selected metadata invalidates that
request's summary. Caller bodies are not implicit spans. Unrelated requests,
caller bodies and source edits do not change other packets unless they share
selected statement/citation bytes or change a selected structural identity. Line
shifts outside evidence only update display coordinates after facts are
regenerated. The original source buffers, canonical JSON and sha256 rules below
apply to both families. Request row digests sort lexically; gateway rows sort by
canonical JSON. Both preserve multiplicity. Release hashes, absolute paths,
timestamps and numeric coordinates never enter request packets.

## Evidence packet

A hosted-gateway packet contains exactly `schemaVersion: 1`, `selector`, `rows`
and `spans`. The selector accepts only `regionRegistry.fields`, one nonempty
region key and `field: "llmBaseUrl"`, plus an explicit `sources` list of
declaration citations. It returns **all** matching rows and preserves
multiplicity. It cannot filter by value, line, position or historical row count.
Newly discovered roots get candidate packets with `sources: []`; the mechanism
does not invent a claim or verdict.

Each selected row preserves `region`, `field` and `value`, replacing `file` and
`line` with `site: {path, anchor}`. The closed relevant-row schema refuses new
coordinates or origins until a location adapter exists. Fact line numbers are
not compared with source lines: `kimchi-extracted` enforces freshness, while
displayed citations always come from the resolved current anchors.

Each span is `{path, anchor, sha256}`. Citations are the structural union of
selected rows' property sites and explicit source selectors, deduplicated by
identity. Repeated explicit source selectors are invalid. Only `src/regions.ts`
and these structural roles are produced:

- `REGIONS :: property([region, "llmBaseUrl"])` selects the final property
  assignment through two direct named property assignments. Names may be
  identifiers or decoded string literals. The one top-level exported
  `const REGIONS` initializer can unwrap `as` and `satisfies` only. Every direct
  member of `REGIONS` must be a named property assignment to a plain object
  literal. Inside each region, spreads and computed property names fail with
  `SOURCE_INPUT` naming the region and construct; wrapped members also fail.
  Named methods, shorthand properties and accessors are allowed: the measured
  query includes their named fields, using `<unresolved>` for nonliteral values.
  Resolving a selected property still requires a direct property assignment.
  Every same-named member counts toward uniqueness, so an assignment beside a
  same-named accessor or method, which can override it at runtime, is ambiguous.
  A lone accessor or method is missing. This scan includes regions without
  measured gateway rows, so unsupported registry structure cannot hide a root.
- `searchUrl :: declaration` selects the complete top-level exported named
  function. All same-name declarations count, including overload signatures: an
  overloaded name is ambiguous.

Zero matches fail as missing; multiple matches fail as ambiguous. There is no
line-offset or first-match fallback. Resolution uses TypeScript against
`ciPackages.<system>.kimchi.passthru.extractionSources.kimchi`, the pinned
original release tree, rather than the patched package or CodeQL tree.

The decoder is `TextDecoder("utf-8", {fatal: true, ignoreBOM: true})`: invalid
UTF-8 is refused and a BOM is retained. The span is
`[node.getStart(sourceFile, false), node.getEnd())`. UTF-16 positions are
converted to UTF-8 byte offsets by measuring the preceding decoded text, then
the original buffer is sliced. Leading trivia and trailing separators outside
the node are excluded. Internal whitespace, comments, punctuation and names are
included. Bytes are never reprinted, trimmed or normalized.

Rows sort by canonical JSON, preserving duplicates. Source selectors and spans
sort by the canonical `{path, anchor}` identity; property `keys` stay ordered.
Canonical JSON recursively sorts object keys with locale-independent string
ordering and uses UTF-8 `JSON.stringify`, without insignificant whitespace or a
trailing newline. SHA-256 is written as `sha256:` plus lowercase hexadecimal.
The stored gateway packet's own hash is validated before comparison with current
evidence, as is the recorded summary hash for requests. Recorded `rows`,
`selector.sources` and `spans` must already be in canonical order; otherwise
`VERDICT_INPUT` names the judgment and array. Gateway row and span contents are
checked by their hash and current-evidence comparison, without a separate
structural schema.

Changing a selected value, adding a matching fact row, renaming a cited symbol,
or editing or reformatting bytes inside a cited span invalidates evidence. For
hosted gateways, inserting or deleting lines outside spans updates
`display.json` coordinates without changing hashes, even if fact lines have not
yet been refreshed. Unselected rows, unrelated requests, unrelated source bytes,
release identity, tool versions, absolute paths, timestamps, root inventory,
judgment prose and numeric coordinates are excluded. Adding a root fails
coverage while existing packets remain current.

## Diagnostics and artifacts

`checks.<system>.kimchi-surface-judgments.passthru.packets` succeeds for
recognized evidence/input failures and records `ok: false`. The separate
`checks.<system>.kimchi-surface-judgments` derivation runs fixtures, prints the
diagnostics and fails when status is unsuccessful. Tool crashes and filesystem
failures remain ordinary build failures. Neither derivation accesses the network
or writes its inputs.

The packet output contains `current.json` (complete packets and hashes, new-root
candidates, or explicit incomplete results without a complete hash), `diff.json`
(old/current hashes, row multiset changes and span changes), `display.json`
(one-based current numeric citations, exclusive ends), `diagnostics.txt` and
`status.json` (classification counts and ordered failure codes). Missing
baselines are `recorded: null`. For requests, `current.json` also contains the
compact `evidence` summary; full rows live at `packet.rows[<digest>]`. Request
row changes in `diff.json` and diagnostics list added/removed digests, including
duplicate counts, rather than repeating row bodies. Valid classified unknowns
are counted separately. Failures sort by judgment id, then code; invalid records
suppress dependent errors while independent records continue. Whole-input
failures emit diagnostics and status without placeholder current packets or
differences.

Every failure uses this envelope. Substitutions containing newlines are JSON
escaped; hashes are complete, or `absent`, `unavailable` or `unresolved`:

```text
FAIL kimchi-surface-judgments [<CODE>]
Judgment: <id>
Claim: <claim>
Changed: <detail>
Evidence hash: old=<old>; new=<new>
Packets: nix build .#checks.<system>.kimchi-surface-judgments.passthru.packets --out-link /tmp/kimchi-judgment-packets
Inspect: /tmp/kimchi-judgment-packets/current.json; /tmp/kimchi-judgment-packets/diff.json; /tmp/kimchi-judgment-packets/display.json
Fix: <action>
A red check means: ask a session to investigate and rejudge. CI does not update verdicts or hashes.
```

The complete catalogue follows. Each action names
`packages/kimchi/surface-judgments.json`, the only verdict file to edit.

| Code                | `Changed:` detail                                                                                                                        | `Fix:` action                                                                                                                                                                                       |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ANCHOR_AMBIGUOUS`  | `ambiguous anchor <anchor>: expected one match, found <count>; candidates=<display-locations>; span old=<old-span-hash>; new=unresolved` | Make the structural citation unique without line offsets, then rejudge `packages/kimchi/surface-judgments.json`.                                                                                    |
| `ANCHOR_MISSING`    | `missing anchor <anchor>: expected one match, found 0; span old=<old-span-hash>; new=unresolved`                                         | Inspect the source change; correct the citation only after reviewing its meaning, then rejudge `packages/kimchi/surface-judgments.json`.                                                            |
| `EVIDENCE_CHANGED`  | `selected evidence changed: rows removed=<rows>; rows added=<rows>; spans=<span-differences>`                                            | Investigate every listed change, then update the claim, scope, rationale, verdict, recorded packet and evidenceHash as warranted in `packages/kimchi/surface-judgments.json`.                       |
| `FACT_INPUT`        | `invalid regionRegistry.fields input at <path>: <reason>`                                                                                | Correct the regionRegistry producer or source pin, run `nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate`, then investigate and rejudge `packages/kimchi/surface-judgments.json`. |
| `RECORDED_HASH`     | `recorded packet hashes to <computed-recorded-hash>, not its recorded evidenceHash <recorded-hash>`                                      | Inspect the recorded packet edit and current evidence, then deliberately update the reviewed record in `packages/kimchi/surface-judgments.json`.                                                    |
| `REMOVED_ROOT`      | `removed root <region>: no nonempty llmBaseUrl declaration remains; removed rows=<rows>`                                                 | Inspect the removed evidence and remove this judgment by hand from `packages/kimchi/surface-judgments.json`.                                                                                        |
| `SOURCE_INPUT`      | `cannot resolve source evidence in src/regions.ts: <reason>`                                                                             | Correct the pinned source or structural resolver, regenerate facts if the source changed, then investigate and rejudge `packages/kimchi/surface-judgments.json`.                                    |
| `UNCLASSIFIED_ROOT` | `unclassified root <region>: a nonempty llmBaseUrl declaration has no judgment; added rows=<rows>`                                       | Review the candidate packet and add one scoped judgment or explicit unknown record to `packages/kimchi/surface-judgments.json`.                                                                     |
| `VERDICT_INPUT`     | `invalid verdict input at <path>: <reason>`                                                                                              | Correct the named field of the record in `packages/kimchi/surface-judgments.json` and rerun the check; its packet will be emitted once the record is valid.                                         |

Schema reasons are the literal strings `invalid JSON`,
`unsupported schemaVersion`, `unknown field`, `missing field`,
`invalid type or value`, `duplicate judgment id`, `duplicate judgment root`,
`duplicate source citation` and `non-canonical <array> array for judgment <id>`.
Source reasons are `invalid UTF-8`,
`TypeScript parse error <code> at <line:column>` and
`unsupported structural shape at <anchor>` or
`region <region> contains unsupported <construct>: use named property assignments with identifier or string-literal names`.
A file-level verdict failure uses id `<verdict-file>` and claim
`<unavailable: verdict input could not be read>`. An unclassified root uses id
`<unclassified:<region>>` and claim
`No claim is recorded for hosted gateway <region>.`. Deleted roots have
`new=absent`; new roots have `old=absent`; anchor failures have
`new=unresolved`. `RECORDED_HASH` compares the stored hash with the recomputed
recorded-packet hash.

Request input adds two codes to the same envelope and uses the same packet
inspection command:

| Code                 | `Changed:` detail                                                                                                                                | `Fix:` action                                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REQUEST_FACT_INPUT` | `invalid requestCallers input at <path>: <reason>`                                                                                               | Correct the requestCallers producer or source pin, run `nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate`, then investigate and rejudge `packages/kimchi/surface-judgments.json`.              |
| `REQUEST_LOCATION`   | `cannot adapt requestCallers location at <path>: expected one <target> at <location>, found <count>; regenerate facts against the pinned source` | Align requestCallers with the pinned source using `nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate`, then inspect the candidate packets and rejudge `packages/kimchi/surface-judgments.json`. |

A request source read failure has Changed text
`cannot adapt requestCallers location at <path>: cannot read source <source-path> (<filesystem-code>); regenerate facts against the pinned source`
under `REQUEST_LOCATION`, or
`missing anchor <anchor>: cannot read source <source-path> (<filesystem-code>); span old=<old-span-hash>; new=unresolved`
under `ANCHOR_MISSING`. The existing Fix text for each code applies. Request
anchors select at most one node, so only gateway anchors can be ambiguous.

Request fact reasons are `missing field`, `unknown field` and
`invalid type or value`. Location targets are `request call`,
`enclosing function` and `source token`. These whole-input failures have
`new=unavailable`.

Request coverage reuses `REMOVED_ROOT` with
`removed request root <root>: no requestCallers occurrence remains; removed rows=<rows>`
and `UNCLASSIFIED_ROOT` with
`unclassified request root <root>: a requestCallers occurrence has no judgment; added rows=<rows>`.
The existing fixes apply. Candidate ids are
`<unclassified:request:<canonical-root>>`; their claim is
`No four-part claim is recorded for request <root>.`. Valid recorded request
claims render as canonical JSON on the `Claim:` line. Removed records must be
deleted by hand.

Request sources reuse `SOURCE_INPUT` with
`cannot resolve source evidence in <path>: <reason>`. In addition to invalid
UTF-8 and parse errors, reasons are
`request call has no supported containing statement at <citation>` and
`unsupported broad evidence node at <citation>`. Statement/citation failures
have `new=unresolved` and produce incomplete packets without evidence hashes.
Missing explicit anchors and schema failures use the existing catalogue and
fixes. Request evidence failures specialize these messages:

| Code               | `Changed:` detail                                                                                             | `Fix:` action                                                                                                                                                                                                                                                                                                                                         |
| ------------------ | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EVIDENCE_CHANGED` | `selected evidence changed: rows removed=<digests>; rows added=<digests>; spans=<span-differences>`           | Investigate every listed change, then update the claim, scope, rationale, verdict, recorded evidence summary and evidenceHash as warranted in `packages/kimchi/surface-judgments.json`. Read current rows in `current.json`; read removed rows in the previous commit's packet artifact or use the recorded digest list and git history of the facts. |
| `RECORDED_HASH`    | `recorded evidence summary hashes to <computed-recorded-hash>, not its recorded evidenceHash <recorded-hash>` | Inspect the recorded evidence summary edit and current evidence, then deliberately update the reviewed record in `packages/kimchi/surface-judgments.json`.                                                                                                                                                                                            |

For request coverage failures, `<rows>` in the messages above likewise contains
row digests. Every span difference names its citation identity (or
`request call` or `request statement`) and its old/new hash; absent sides are
null. Both request `EVIDENCE_CHANGED` and `REMOVED_ROOT` fixes direct sessions
to read current rows by digest from `current.json` and removed rows from the
previous commit's packet artifact, or use the recorded digest list and git
history of the facts. Removed row bodies are not stored in the current packet.

## Investigating and rejudging

PR CI regenerates facts, regenerates and checks the report, builds packets,
materializes diagnostic artifacts, then runs the judgment gate before patch
creation or facts upload. The independent always-uploaded artifact is named
`kimchi-judgments-${SYSTEM}` and cannot match `*-extracted-${SYSTEM}`. On gate
failure the producer prints
`gh run download ${RUN_ID} -n kimchi-judgments-${SYSTEM}`. Download that
artifact to inspect the evidence from the failed producer. Infrastructure
failure before packet production can leave no artifact.

Alternatively, regenerate facts before rebuilding packets locally on
x86_64-linux. Building locally against stale committed facts can differ from the
producer's evidence. From the repository root:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate
nix build .#checks.x86_64-linux.kimchi-surface-judgments.passthru.packets \
  --out-link /tmp/kimchi-judgment-packets
cat /tmp/kimchi-judgment-packets/diagnostics.txt
cat /tmp/kimchi-judgment-packets/diff.json
cat /tmp/kimchi-judgment-packets/current.json
cat /tmp/kimchi-judgment-packets/display.json
```

Investigate every changed row and span against the original pinned source.
Review the exact proposition and its boundary; for requests, review all four
claim parts and add narrow source citations for their evidence. Name each
unresolved part in missingEvidence and keep the overall verdict unknown. An
observed packet is evidence freshness, not a supported runtime claim. Rejudging
edits only `packages/kimchi/surface-judgments.json`. The fixture suite uses its
own gateway and request verdict baselines under
`checks/fixtures/surface-judgments/` and local expectations, which do not change
when live claims or verdicts are reviewed. Deliberately edit the live verdict
file, copying the current request selector, evidence summary and hash (or the
hosted-gateway packet and hash) only as part of that review. There is no
accept/update operation. Then run:

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
nix build .#checks.x86_64-linux.kimchi-surface-judgments --no-link
```

Verdict and packet/check edits select Kimchi through its declared
`extractedSelectionInput`. Documentation and generated facts/report do not.
Producer commit-back paths remain exactly `packages/${OWNER}/extracted` and, for
Kimchi, `packages/kimchi/egress-report.json`; the collector applies those facts
patches. Verdicts and packet artifacts are read-only check inputs and diagnostic
outputs respectively, never commit-back outputs. This mechanism does not migrate
the census or replace its report. It extends `requestCallers.callSite` with
`endLine` and `endColumn` so the resolver matches each request by its exact call
range.
