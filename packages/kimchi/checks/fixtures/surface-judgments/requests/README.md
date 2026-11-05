# Request judgment fixtures

These fixtures run the production `check.mjs` with the selected-facts schema,
verdict schema, TypeScript parser, source-tree layout, and artifact gate used by
the Nix check. Their source and `requestCallers` rows are hand-authored
miniature inputs rather than a CodeQL extraction of the pinned Kimchi release.
They test the production reader; they do not claim to test CodeQL extraction.

The gateway fixtures and their expected diagnostics remain separate and
unchanged. Their selected facts now explicitly contain `requestCallers: []`.

## Frozen evidence

`base/` contains independent requests A and B. A cites only `enabled = true`
from `src/policy.ts`; B has no additional citation. `shapes/` contains request
occurrences, including anonymous functions within named owners, a nested named
function, constructors and methods, module code, duplicate names in different
blocks, same-line calls, a shared statement, and chained receiving members.

`citations/` supplies alternative frozen verdict inputs using the same base
facts and source tree. Each selects one narrow registration argument, keyed
array entry, resource property, initializer, precedence condition, or return.
Each has separate baseline, selected-edit, and adjacent-edit cases.

Packets and diagnostics were observed from the production checker and frozen as
literal JSON. No request expectation is calculated with imported production
hashing or resolution functions during the test. Independent Python
`hashlib.sha256` checks verify stored packet hashes and successful spans against
literal source bytes. The `invalid/` records are intentional forbidden or
unreadable citation inputs: their packet hashes were constructed independently
so rejection reaches the source resolver instead of stopping at recorded-hash
validation.

## Behavior coverage

Every case has a `rejects` description naming its incorrect implementation.
Changed and unchanged judgment IDs are asserted separately; row additions and
removals and statement edits also have frozen complete diff artifacts.

| Requirement                                                      | Cases                                                                                                                                                                                   |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Added occurrence                                                 | `request-added`                                                                                                                                                                         |
| Anonymous named owner, call-free insertion, JSDoc                | `request-anonymous-owner-call-free-insertion`, `request-jsdoc-inserted`, `request-named-owner-call-free-insertion`                                                                      |
| Callback, caller, boundary, metadata, and duplicate preservation | `request-boundary-added`, `request-callback-added`, `request-caller-added`, `request-caller-removed`, `request-row-multiplicity`, `request-same-call-second-library`, `request-typed-*` |
| Exact structural owners and enum-free identities                 | `request-anchor-shapes`, `request-enclosing-function-renamed`                                                                                                                           |
| Independent request and source changes                           | `request-added`, `request-citation-*-adjacent`, `request-statement-edited`, `request-unrelated-*`                                                                                       |
| Line shifts and display coordinates                              | `request-lines-deleted`, `request-lines-inserted`                                                                                                                                       |
| Narrow statement and explicit citations                          | `request-citation-*-selected`, `request-immediate-owner-unrelated-edit`, `request-same-function-unrelated-edit`, `request-statement-wrapper-edited`                                     |
| Refused input and actionable diagnostics                         | `request-fact-*`, `request-location-*`, `request-source-*`                                                                                                                              |
| Removed occurrence and manual removal                            | `request-removed`, `request-removed-record-by-hand`                                                                                                                                     |
| Repeatability and read-only checking                             | `request-read-only-and-repeatable`, `request-row-order`                                                                                                                                 |
| Same-line, shared-statement, and innermost chain resolution      | `request-chained-request-innermost`, `request-member-chain-sites`, `request-two-in-one-statement`, `request-two-on-one-line`                                                            |
| Unknown claims and four required parts                           | `request-claim-*`, `request-unknown-*`                                                                                                                                                  |

Request locations are refreshed for source mutations that move measured tokens.
The line-shift fixtures assert full display maps as well as unchanged packets.
The shape fixtures keep anonymous function starts distinct without introducing
anonymous owner segments. The call-free insertion includes `if`, `for`, and
`try` statements before those starts to reject ordinary punctuation ordinals.

The request-fact reader preserves typed metadata without becoming another
reachability validator. Typed distance, kind, and reason changes therefore
invalidate only A; malformed primitive types are whole-input refusals. The
boundary and callback cases use the ordinary producer meanings, including
`stored`, `onStart`, and the recorded distance.

`stability/` contains a request in a `deliverEvents` callback and billing/budget
requests reached by a `loginExtension` event registration. The cases
`request-unrelated-arrow-insertion` and `request-unrelated-event-insertion`
insert `[1, 2].map((n) => n * 2)` and `pi.on("session_shutdown", () => {})`
respectively. Matching fact coordinates move, but every packet must equal its
frozen baseline. These reject global function-start-token ordinals and
same-callee-only caller site ordinals.

`request-citation-file-missing` requires an incomplete packet and the full
`ANCHOR_MISSING` envelope for an absent file. The three
`request-location-file-missing-*` cases require whole-input `REQUEST_LOCATION`
failures for absent call, function and site files. The corresponding
`*-file-unreadable` cases use a regular file as a path component (`ENOTDIR`) to
exercise non-ENOENT read failures without depending on OS permission privileges.
All run through the ordinary artifact and verdict-immutability assertions.
