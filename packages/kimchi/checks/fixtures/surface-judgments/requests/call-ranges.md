# Exact request invocation ranges

These cases reject start-only invocation selection. Source lines below refer to
`src/requests.ts` in each fixture's `sources.json`. Facts and packet structures
are hand-written; packet and statement hashes use independent Python
`hashlib.sha256`, not the packet resolver. Existing fixtures' new end fields
were observed with TypeScript against their edited source maps and frozen as
input.

`returned-fetch`:

```text
function getFetch() { return fetch; }
function returned() {
  return getFetch()(
    url
  );
}
```

The request range is **3:10–5:3**, including the outer closing parenthesis. The
inner `getFetch()` instead ends at **3:19**. The expected root is
`src/requests.ts`, symbol `[["function:returned", 0]]`, role
`{ "callee": "call:getFetch()", "kind": "call", "ordinal": 0 }`. The exact
statement is `return getFetch()(\n    url\n  );`.

`chained-fetch`:

```text
function chained() {
  return fetch(u).then(cb);
}
```

The request range is **2:10–2:17**, including the inner closing parenthesis. The
outer `.then(cb)` ends at **2:26**. The expected root is `src/requests.ts`,
symbol `[["function:chained", 0]]`, role
`{ "callee": "call:fetch", "kind": "call", "ordinal": 0 }`. The exact statement
is `return fetch(u).then(cb);`.

CodeQL line/column values are 1-based, and ends are inclusive. TypeScript
`getEnd()` is an exclusive 0-based UTF-16 offset. Convert `getEnd() - 1` to its
line/column, then add one to each. Both successful cases assert the entire
hand-written baseline packet, its hash, the root and the exact statement. The
failed cases affect only `request-chained-fetch`.

| Case                         | Input / source                  | Expected                      | Wrong implementation rejected                           |
| ---------------------------- | ------------------------------- | ----------------------------- | ------------------------------------------------------- |
| `request-bad-end-column`     | Chained, endColumn 0            | `REQUEST_FACT_INPUT`          | Accepting a zero or negative end column                 |
| `request-bad-end-line`       | Chained, endLine 0              | `REQUEST_FACT_INPUT`          | Accepting a zero or negative end line                   |
| `request-chained-fetch`      | Chained, 2:10–2:17              | No failures; unchanged packet | Choosing the outermost invocation                       |
| `request-end-after-close`    | Chained, endColumn 18 (the dot) | `REQUEST_LOCATION`            | Rounding or accepting an exclusive column               |
| `request-end-before-close`   | Chained, endColumn 16 (`u`)     | `REQUEST_LOCATION`            | Rounding or subtracting one twice                       |
| `request-missing-end-column` | Chained, endColumn absent       | `REQUEST_FACT_INPUT`          | Accepting legacy start-only facts                       |
| `request-missing-end-line`   | Chained, endLine absent         | `REQUEST_FACT_INPUT`          | Defaulting a missing end line                           |
| `request-returned-fetch`     | Returned, 3:10–5:3              | No failures; unchanged packet | Choosing the innermost invocation or ignoring end lines |
| `request-wrong-end-line`     | Chained, endLine 3              | `REQUEST_LOCATION`            | Ignoring the end line                                   |

Mutation checks replace exact range selection with innermost and outermost
start-only selection, respectively. Each positive fixture then fails with
`UNCLASSIFIED_ROOT` and `REMOVED_ROOT`, proving it detects the wrong invocation.
