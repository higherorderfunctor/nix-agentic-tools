# Kimchi surface judgments

`surface-judgments.json` records reviewed interpretations of measured evidence.
A red check means **ask a session to investigate and rejudge**. CI never calls a
model, rewrites a verdict or refreshes a recorded hash. A matching evidence hash
establishes that the reviewed evidence is current; reviewing the proposition,
scope and rationale remains a session's responsibility. A judgment cannot
replace a measured fact.

## Declared hosted LLM gateways

The bounded family is the distinct `region` keys in measured
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

The file's closed schema is `{schemaVersion: 1, judgments: [...]}`. Each record
requires `id`, `claim`, `scope`, `packet`, `evidenceHash`, `verdict` and
`rationale`. IDs are unique descriptive lowercase kebab-case. Verdicts are
`supported`, `refuted` or `unknown`. Unknown requires nonblank
`missingEvidence`; other dispositions forbid it. Selectors and citations live in
the packet, without duplicate metadata fields. Unknown fields and versions are
refused.

## Evidence packet

A packet contains exactly `schemaVersion: 1`, `selector`, `rows` and `spans`.
The selector accepts only `regionRegistry.fields`, one nonempty region key and
`field: "llmBaseUrl"`, plus an explicit `sources` list. It returns **all**
matching rows and preserves multiplicity. It cannot filter by value, line,
position or historical row count. Newly discovered roots get candidate packets
with `sources: []`; the mechanism does not invent a claim or verdict.

Each selected row preserves `region`, `field` and `value`, replacing `file` and
`line` with `site: {path, anchor}`. The closed relevant-row schema refuses new
coordinates or origins until a location adapter exists. Fact line numbers are
not compared with source lines: `kimchi-extracted` enforces freshness, while
displayed citations always come from the resolved current anchors.

Each span is `{path, anchor, sha256}`. Citations are the structural union of
selected rows' property sites and explicit source selectors, deduplicated by
identity. Repeated explicit source selectors are invalid. Only `src/regions.ts`
and these structural roles are accepted:

- `REGIONS :: property([region, "llmBaseUrl"])` selects the final property
  assignment through two direct named property assignments. Names may be
  identifiers or decoded string literals. The one top-level exported
  `const REGIONS` initializer can unwrap `as` and `satisfies` only. Every direct
  member of `REGIONS` must be a plain object literal; a wrapped member fails
  with `SOURCE_INPUT`, so unsupported registry structure cannot hide a root.
- `searchUrl :: declaration` selects the complete top-level exported named
  function. All same-name declarations count, including overload signatures: an
  overloaded name is ambiguous. A unique declaration needs a body.

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
The stored packet's own hash is validated before comparison with current
evidence. There is no additional recorded-packet consistency policy.

Changing a selected value, adding a matching fact row, renaming a cited symbol,
or editing or reformatting bytes inside a cited span invalidates evidence.
Inserting or deleting lines outside spans updates `display.json` coordinates
without changing hashes, even if fact lines have not yet been refreshed.
Unselected rows, unrelated requests, unrelated source bytes, release identity,
tool versions, absolute paths, timestamps, root inventory, judgment prose and
numeric coordinates are excluded. Adding a root fails coverage while existing
packets remain current.

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
baselines are `recorded: null`. Valid classified unknowns are counted
separately. Failures sort by judgment id, then code; invalid records suppress
dependent errors while independent records continue.

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
| `FACT_INPUT`        | `invalid regionRegistry.fields input at <JSON-pointer>: <reason>`                                                                        | Correct the regionRegistry producer or source pin, run `nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate`, then investigate and rejudge `packages/kimchi/surface-judgments.json`. |
| `RECORDED_HASH`     | `recorded packet hashes to <computed-recorded-hash>, not its recorded evidenceHash <recorded-hash>`                                      | Inspect the recorded packet edit and current evidence, then deliberately update the reviewed record in `packages/kimchi/surface-judgments.json`.                                                    |
| `REMOVED_ROOT`      | `removed root <region>: no nonempty llmBaseUrl declaration remains; removed rows=<rows>`                                                 | Inspect the removed evidence and remove this judgment by hand from `packages/kimchi/surface-judgments.json`.                                                                                        |
| `SOURCE_INPUT`      | `cannot resolve source evidence in src/regions.ts: <reason>`                                                                             | Correct the pinned source or structural resolver, regenerate facts if the source changed, then investigate and rejudge `packages/kimchi/surface-judgments.json`.                                    |
| `UNCLASSIFIED_ROOT` | `unclassified root <region>: a nonempty llmBaseUrl declaration has no judgment; added rows=<rows>`                                       | Review the candidate packet and add one scoped judgment or explicit unknown record to `packages/kimchi/surface-judgments.json`.                                                                     |
| `VERDICT_INPUT`     | `invalid verdict input at <JSON-pointer>: <reason>`                                                                                      | Correct the named input in `packages/kimchi/surface-judgments.json`, inspect the emitted evidence, and rerun the check.                                                                             |

Schema reasons are the literal strings `invalid JSON`,
`unsupported schemaVersion`, `unknown field`, `missing field`,
`invalid type or value`, `duplicate judgment id`, `duplicate judgment root`,
`unsupported selector` and `duplicate source citation`. Source reasons are
`invalid UTF-8`, `TypeScript parse error <code> at <line:column>` and
`unsupported structural shape at <anchor>`. A file-level verdict failure uses id
`<verdict-file>` and claim `<unavailable: verdict input could not be read>`. An
unclassified root uses id `<unclassified:<region>>` and claim
`No claim is recorded for hosted gateway <region>.`. Deleted roots have
`new=absent`; new roots have `old=absent`; anchor failures have
`new=unresolved`. `RECORDED_HASH` compares the stored hash with the recomputed
recorded-packet hash.

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
Review the exact proposition and its boundary; name missing evidence for an
unknown. Deliberately edit the verdict file, copying a current packet and hash
only as part of that review. There is no accept/update operation. Then run:

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
the census, replace its report or broaden fact queries.
