# Request judgment fixtures

`base/` is the shared source tree, selected facts, and verdict baseline. Each
case patches that baseline and runs the production `check.mjs`. These miniature
inputs exercise the reader, not CodeQL extraction.

Baseline evidence uses independent Python `hashlib.sha256`. Row and root digests
hash sorted-key compact JSON; call and statement digests hash their literal
UTF-8 bytes. An `evidenceHash` a case sets hashes the summary with its span ids
expanded from the shared `spans` table. The runner never computes request
expectations with production functions. Assertions inspect selected digests,
statement text, row details, changed span identities, failure codes, and
independent request hashes. Every run checks the artifact gate and verifies
verdict bytes remain unchanged.

`src/chained-fetch.ts` selects the inner `fetch(u)` at 2:10–2:17;
`src/returned-fetch.ts` selects the outer `getFetch()(url)` at 3:10–5:3. Their
baseline statement and evidence assertions reject start-only selection.
`src/stability.ts` supplies delivery callback and billing event caller rows.
Unrelated arrow and event insertions must preserve their evidence.

`request-added` appends a second call after a return on the same line. Its
measured fact remains a request root; this checker does not infer reachability.
