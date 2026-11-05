# Request judgment fixtures

`base/` is the shared source tree, selected facts, and verdict baseline. Each
case patches that baseline and runs the production `check.mjs`. These miniature
inputs exercise the reader, not CodeQL extraction.

Compact baseline evidence was derived from the former literal normalized rows
and source spans with independent Python `hashlib.sha256`. Row digests hash
sorted-key compact JSON; statement digests hash the literal UTF-8 statement. The
runner never computes request expectations with production functions. Assertions
inspect selected digests, statement text, row details, changed span identities,
failure codes, and independent request hashes. Every run checks the artifact
gate and verifies verdict bytes remain unchanged.

`src/chained-fetch.ts` selects the inner `fetch(u)` at 2:10–2:17;
`src/returned-fetch.ts` selects the outer `getFetch()(url)` at 3:10–5:3. Their
baseline statement and evidence assertions reject start-only selection.
`src/stability.ts` supplies delivery callback and billing event caller rows.
Unrelated arrow and event insertions must preserve their evidence.

See [coverage.md](coverage.md) for the retained cases and removed-case mapping.

`request-added` appends a second call after a return on the same line. Its
measured fact remains a request root; this checker does not infer reachability.
