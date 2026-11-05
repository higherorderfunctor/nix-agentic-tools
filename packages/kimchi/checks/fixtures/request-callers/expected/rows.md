# Expected request caller rows

This ledger renders the hand-written `requestCallers.json`; it is not query
output. All files are under `source/kimchi/src/` and all libraries are `fetch`.
`F` is `functionSite`; `S` is `site`; `d` is `distance`. A dash is JSON null.
The request and site filenames identify the participating cases; their source
comments state the wrong implementations.

| Request file:line:column | F file:line:column      | Kind      | S file:line:column      | Property  | Reason       | d   |
| ------------------------ | ----------------------- | --------- | ----------------------- | --------- | ------------ | --- |
| callbacks.ts:3:10        | callbacks.ts:2:1        | boundary  | callbacks.ts:9:32       | -         | stored       | 0   |
| callbacks.ts:3:10        | callbacks.ts:2:1        | boundary  | callbacks.ts:13:23      | -         | stored       | 0   |
| callbacks.ts:3:10        | callbacks.ts:2:1        | enclosing | callbacks.ts:2:1        | -         | -            | 0   |
| callbacks.ts:3:10        | callbacks.ts:2:1        | boundary  | callbacks.ts:11:1       | -         | registration | 1   |
| callbacks.ts:3:10        | callbacks.ts:2:1        | callback  | callbacks.ts:7:3        | fetchImpl | -            | 1   |
| callbacks.ts:3:10        | callbacks.ts:2:1        | callback  | callbacks.ts:11:1       | -         | -            | 1   |
| callbacks.ts:3:10        | callbacks.ts:6:8        | boundary  | callbacks.ts:6:8        | -         | unreferenced | 1   |
| callers.ts:3:10          | callers.ts:2:8          | boundary  | imported.ts:4:15        | -         | stored       | 0   |
| callers.ts:3:10          | callers.ts:2:8          | enclosing | callers.ts:2:8          | -         | -            | 0   |
| callers.ts:3:10          | callers.ts:2:8          | caller    | callers.ts:6:28         | -         | -            | 1   |
| callers.ts:3:10          | callers.ts:2:8          | caller    | callers.ts:9:3          | -         | -            | 1   |
| callers.ts:3:10          | callers.ts:2:8          | caller    | dynamic-import.ts:4:3   | -         | -            | 1   |
| callers.ts:3:10          | callers.ts:2:8          | caller    | imported.ts:6:3         | -         | -            | 1   |
| callers.ts:3:10          | callers.ts:2:8          | caller    | namespace-import.ts:4:3 | -         | -            | 1   |
| callers.ts:3:10          | callers.ts:5:8          | boundary  | callers.ts:5:8          | -         | unreferenced | 1   |
| callers.ts:3:10          | callers.ts:8:8          | boundary  | callers.ts:8:8          | -         | unreferenced | 1   |
| callers.ts:3:10          | dynamic-import.ts:2:8   | boundary  | dynamic-import.ts:2:8   | -         | unreferenced | 1   |
| callers.ts:3:10          | imported.ts:5:8         | boundary  | imported.ts:5:8         | -         | unreferenced | 1   |
| callers.ts:3:10          | namespace-import.ts:3:8 | boundary  | namespace-import.ts:3:8 | -         | unreferenced | 1   |
| class.ts:4:12            | class.ts:3:3            | boundary  | class.ts:3:3            | -         | stored       | 0   |
| class.ts:4:12            | class.ts:3:3            | enclosing | class.ts:3:3            | -         | -            | 0   |
| class.ts:4:12            | class.ts:3:3            | caller    | class.ts:7:5            | -         | -            | 1   |
| class.ts:4:12            | class.ts:6:3            | boundary  | class.ts:6:3            | -         | stored       | 1   |
| class.ts:4:12            | class.ts:6:3            | caller    | class.ts:12:3           | -         | -            | 2   |
| class.ts:4:12            | class.ts:11:8           | boundary  | class.ts:11:8           | -         | unreferenced | 2   |
| columns.ts:3:17          | columns.ts:2:8          | boundary  | columns.ts:2:8          | -         | unreferenced | 0   |
| columns.ts:3:17          | columns.ts:2:8          | enclosing | columns.ts:2:8          | -         | -            | 0   |
| columns.ts:3:38          | columns.ts:2:8          | boundary  | columns.ts:2:8          | -         | unreferenced | 0   |
| columns.ts:3:38          | columns.ts:2:8          | enclosing | columns.ts:2:8          | -         | -            | 0   |
| constructor.ts:3:10      | constructor.ts:2:1      | enclosing | constructor.ts:2:1      | -         | -            | 0   |
| constructor.ts:3:10      | constructor.ts:2:1      | callback  | constructor.ts:10:3     | reconnect | -            | 1   |
| constructor.ts:3:10      | constructor.ts:9:8      | caller    | constructor.ts:13:3     | -         | -            | 2   |
| constructor.ts:3:10      | constructor.ts:12:8     | boundary  | constructor.ts:12:8     | -         | unreferenced | 2   |
| depth.ts:3:10            | depth.ts:2:1            | enclosing | depth.ts:2:1            | -         | -            | 0   |
| depth.ts:3:10            | depth.ts:2:1            | caller    | depth.ts:6:3            | -         | -            | 1   |
| depth.ts:3:10            | depth.ts:5:1            | caller    | depth.ts:9:3            | -         | -            | 2   |
| depth.ts:3:10            | depth.ts:8:1            | caller    | depth.ts:12:3           | -         | -            | 3   |
| depth.ts:3:10            | depth.ts:11:1           | caller    | depth.ts:15:3           | -         | -            | 4   |
| depth.ts:3:10            | depth.ts:14:1           | boundary  | depth.ts:18:3           | -         | depth        | 4   |
| distance.ts:3:10         | distance.ts:2:1         | enclosing | distance.ts:2:1         | -         | -            | 0   |
| distance.ts:3:10         | distance.ts:2:1         | caller    | distance.ts:6:3         | -         | -            | 1   |
| distance.ts:3:10         | distance.ts:2:1         | caller    | distance.ts:9:3         | -         | -            | 1   |
| distance.ts:3:10         | distance.ts:5:1         | caller    | distance.ts:10:3        | -         | -            | 2   |
| distance.ts:3:10         | distance.ts:8:1         | caller    | distance.ts:13:3        | -         | -            | 2   |
| distance.ts:3:10         | distance.ts:12:8        | boundary  | distance.ts:12:8        | -         | unreferenced | 2   |
| entry.ts:3:10            | entry.ts:2:8            | boundary  | entry.ts:2:8            | -         | unreferenced | 0   |
| entry.ts:3:10            | entry.ts:2:8            | enclosing | entry.ts:2:8            | -         | -            | 0   |
| inline.ts:4:30           | inline.ts:4:24          | enclosing | inline.ts:4:24          | -         | -            | 0   |
| inline.ts:4:30           | inline.ts:3:8           | boundary  | inline.ts:3:8           | -         | unreferenced | 1   |
| inline.ts:4:30           | inline.ts:4:24          | callback  | inline.ts:4:3           | fetchImpl | -            | 1   |
| inline.ts:6:12           | inline.ts:4:64          | enclosing | inline.ts:4:64          | -         | -            | 0   |
| inline.ts:6:12           | inline.ts:3:8           | boundary  | inline.ts:3:8           | -         | unreferenced | 1   |
| inline.ts:6:12           | inline.ts:4:64          | callback  | inline.ts:4:3           | -         | -            | 1   |
| method.ts:4:12           | method.ts:3:3           | boundary  | method.ts:3:3           | -         | stored       | 0   |
| method.ts:4:12           | method.ts:3:3           | enclosing | method.ts:3:3           | -         | -            | 0   |
| method.ts:4:12           | method.ts:3:3           | caller    | method.ts:8:3           | -         | -            | 1   |
| method.ts:4:12           | method.ts:7:8           | boundary  | method.ts:7:8           | -         | unreferenced | 1   |
| nested.ts:3:10           | nested.ts:2:1           | enclosing | nested.ts:2:1           | -         | -            | 0   |
| nested.ts:3:10           | nested.ts:2:1           | callback  | nested.ts:7:3           | fetchImpl | -            | 1   |
| nested.ts:3:10           | nested.ts:6:8           | boundary  | nested.ts:6:8           | -         | unreferenced | 1   |
| recursion.ts:3:3         | recursion.ts:2:1        | enclosing | recursion.ts:2:1        | -         | -            | 0   |
| recursion.ts:3:3         | recursion.ts:2:1        | caller    | recursion.ts:7:3        | -         | -            | 1   |
| recursion.ts:3:3         | recursion.ts:6:1        | boundary  | recursion.ts:4:3        | -         | recursion    | 2   |
| recursion.ts:3:3         | recursion.ts:6:1        | caller    | recursion.ts:4:3        | -         | -            | 2   |
| top-level.ts:2:1         | top-level.ts:2:1        | boundary  | top-level.ts:2:1        | -         | unreferenced | 0   |
| unresolved.ts:3:10       | unresolved.ts:2:1       | boundary  | unresolved.ts:6:10      | -         | unresolved   | 0   |
| unresolved.ts:3:10       | unresolved.ts:2:1       | enclosing | unresolved.ts:2:1       | -         | -            | 0   |

`imported.ts:4:15` is the alias store; `imported.ts:6:3` is its call edge for
`callers.ts:3:10`. `unrelated.ts` contributes no rows: its same-named helper has
a different binding. The unrelated `callbacks.ts:9:32` property has only a
stored boundary, never a callback edge.

`dynamic-import.ts:3:9` binds `renamed` to the exported helper using a literal
module path; its call at `4:3` must not disappear. `namespace-import.ts:2:1`
imports the same module namespace, whose member call at `4:3` must also resolve.
Their enclosing functions at `2:8` and `3:8` have no further uses. These four
rows extend the `callers.ts:3:10` case; none of its earlier rows change.

`constructor.ts:3:10` is enclosed by `reconnect` at `2:1`. The property
shorthand at `10:18` is an argument to `new Receiver` at `10:3`, whose const
alias at `8:7` binds the source class at `5:1` (constructor at `6:3`). The
callback edge therefore reaches `connect` at `9:8`, then its caller at `13:3`,
then the unreferenced entry at `12:8`. There is no registration boundary at
`10:3`.
