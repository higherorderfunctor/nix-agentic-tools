# files engine

## Boundary and caller schema

The file schema and engine rules below are the contract of the files engine.
[The ai-module design](DESIGN.md) defines its owner, generic options and backend
lowering. The generic `ai.files` option owns the map; runtime producers forward
their entries through the layer-1 helper.

| Option           | Nix type                                                                                   | Default     | Meaning                                                                                                           |
| ---------------- | ------------------------------------------------------------------------------------------ | ----------- | ----------------------------------------------------------------------------------------------------------------- |
| `_contentPrio`   | `int`, internal, read-only                                                                 | computed    | The strongest `content` definition priority, read without evaluating content.                                     |
| `enable`         | `bool`                                                                                     | `true`      | Suppress this entry while retaining its previous ownership for retirement.                                        |
| `content.text`   | `nullOr str`                                                                               | `null`      | Literal UTF-8 bytes, including `""`.                                                                              |
| `content.source` | `nullOr path` **or** store-path string                                                     | `null`      | File or directory to read; strings are paths, never literal content.                                              |
| `content.value`  | `nullOr (attrsOf anything)`                                                                | `null`      | Structured root map; child maps merge by Nix option priority.                                                     |
| `content.run`    | `nullOr lines`                                                                             | `null`      | Strict Bash body whose stdout is the file bytes at activation; secrets stay out of the store.                     |
| `executable`     | `nullOr bool`                                                                              | `null`      | Impose execute bits on a copy or native link; `null` preserves source execute bits.                               |
| `format`         | `enum ["json" "markdown" "raw" "toml" "yaml"]`                                             | `"raw"`     | Value renderer and, for `rw`, document codec. Markdown and raw carry bytes unchanged.                             |
| `method`         | `enum ["ro" "rw" "symlink"]` or submodule `{ devenv; hm; }` with both enum fields required | `"symlink"` | Delivery per backend; the two-field form expresses differing reader behavior.                                     |
| `mode`           | `nullOr (strMatching "0?[0-7]{3}")`                                                        | `null`      | Exact permissions on an owned copy; `ro` requires owner read permission for later reconciliation.                 |
| `recursive`      | `bool`                                                                                     | `false`     | Expand a source directory into leaves at any depth; otherwise a directory source is one native directory symlink. |
| `requires`       | `listOf package`, internal                                                                 | `[]`        | Derivations built before delivery, never read: their string context rides on each delivered leaf after the walk.  |

`requires` accepts packages and exposes context-bearing store paths, preserving
build dependencies without traversing recursive derivation metadata.

The submodule keeps text/source/value/run as nullable sibling options. After
each sibling merges its own definitions, normalization walks the siblings from
the lowest numeric `options.content.<field>.highestPrio`, skips a priority whose
siblings are all null, and selects the non-null sibling there. It rejects two
non-null alternatives tied at that winning priority; weaker alternatives are
neither compared nor evaluated. Thus explicit `source` replaces default `text`,
and explicit `text` replaces default `source` without changing the generated
definition. An enabled entry needs one winner; disabled entries need no content.
`method` resolves after option merging. Empty `value = {}` is valid and can
retire previously declared keys. `run` needs no per-file ordering switch: the
backend supplies its provider edge.

All validation is forced when normalizing a module's `files` map, before
building a plan. For each enabled entry this includes every declared option
except discarded content alternatives, and both fields of a backend-specific
`method`, even when only one backend's plan is requested. Store-path strings
under `content.source` must start with a Nix store object path
(`/nix/store/<32-character hash>-<name>`) and may name a child within it only
when no child segment is `.` or `..`; Nix path values remain valid. Invalid
source strings fail the option type check, which names
`files."<path>".content.source`. Message templates below are exact; `<path>`,
`<method>`, and `<format>` are interpolated with the offending values. Errors
from Nix's enum or `strMatching` type checker name the option path for malformed
enum and mode strings.

| Refused input                                                                                           | Evaluation error                                                                                             |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Empty, absolute, repeated slash, `.` or `..` target segment                                             | `files."<path>": target must be a normalized relative path without empty, . or .. segments`                  |
| Enabled entry with no non-null content field                                                            | `files."<path>": set one of content.text, content.source, content.value, content.run`                        |
| Two non-null content fields at the winning priority                                                     | `files."<path>": content alternatives tie at priority <priority>: <fields>`                                  |
| `content.value` with markdown/raw                                                                       | `files."<path>": content.value requires json, toml or yaml format`                                           |
| `method = rw` with markdown/raw                                                                         | `files."<path>": rw requires json, toml or yaml format`                                                      |
| `recursive` without a directory source                                                                  | `files."<path>": recursive requires content.source to be a directory`                                        |
| `recursive` with `rw`                                                                                   | `files."<path>": rw cannot be recursive`                                                                     |
| `content.run` with symlink                                                                              | `files."<path>": content.run requires ro or rw method`                                                       |
| `mode` with symlink                                                                                     | `files."<path>": mode requires ro or rw method`                                                              |
| `mode` and non-null `executable` together                                                               | `files."<path>": mode and executable cannot both be set`                                                     |
| `ro` mode without owner read permission                                                                 | `files."<path>": ro mode must grant owner read permission`                                                   |
| Expanded leaf duplicates another leaf or explicit target, or a directory target contains another target | `files."<path>": destination overlaps "<other>"`                                                             |
| Two or more runtimes declare one destination at layer 1 (an `enable = false` entry counts as a claim)   | `files."<path>": runtime owners <a> and <b> claim one destination` (all owners, sorted, joined with " and ") |
| Recursive `ro` source with a symlink that resolves to a directory (a copy has no file bytes for it)     | `files."<path>": recursive ro source contains a directory symlink at "<leaf>"`                               |

For `rw`, text/source/run bytes must decode as the selected codec's root map;
failure is a runtime error naming the path and codec, before changing disk.
`content.value` must be JSON-compatible Nix data for all three codecs;
unsupported values fail evaluation with
`files."<path>": content.value must contain only null, booleans, numbers, strings, lists and string-keyed maps`.
TOML additionally rejects nulls with
`files."<path>": TOML cannot represent null at "<key path>"`. Empty maps are
allowed. YAML documents containing anchors or aliases fail at runtime with an
error naming the file path before the document or state is changed. A raw or
markdown source can use `symlink` or `ro`; its tag does not imply a formatter.

## Normalized plan and ownership

`normalize` takes the effective map, backend, stable namespace and the runtime
owner claims ([layer 1](DESIGN.md#layer-1-runtime-file-overrides)) and emits one
sorted plan. It resolves backend-specific methods, validates paths, renders
`value` with the selected codec, and recursively walks `source` directories with
`builtins.readDir`. Regular files and symlinks become leaves under
`<target>/<relative leaf>`. A symlink is never followed, so a `symlink` entry
delivers a directory symlink as one native link to its source path, as Home
Manager's recursive link does; `ro` refuses it. Every leaf carries its full
root-relative path, source, method, format, and permissions. A recursive walk
preserves path values or store-string context in its child sources, so
serialized plans retain store references. A non-recursive directory symlink is
one path. Sources are probed only when `recursive = true`, so a derivation
source is never built at evaluation; a non-recursive directory given to `ro` is
refused by the engine at runtime (`source must be a file`). Collisions are
checked after expansion, including ancestor/descendant overlaps. The plan
contains no per-consumer writer or ledger declaration.

The desired owned set is derived entirely from enabled map entries: each `ro`
leaf owns its **full relative path**, and each `rw` document owns its path plus
the declared key paths. Native backends own `symlink` entries. `enable = false`
and an empty map contribute no new copy ownership. The engine unions this
desired set with the previous state, so a former copy remains discoverable at
N→0. A disabled owner forwards no entries, and the always-imported backend
module still emits prune; the stable namespace lets that empty plan drain the
same state. If the integrator removes the module itself, there is no activation
to drain; module registration is therefore a documented integration invariant,
not an extra file option.

State lives at
`${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/files/ai.json` for HM
and `$DEVENV_STATE/nix-agentic-tools/files/ai.json` for devenv. The base fixes
the namespace to `ai`. Schema version 1:
`{ "version": 1, "files": { "relative/path": { "method": "ro|rw", "format": "...", "digest": "sha256 hex", "mode": "actual octal mode", "created": false, "keys": {"/nested/key": "sha256 of canonical value"} } } }`.
`digest` is the last installed whole-file byte digest for `ro` and `rw`; `rw`
also uses JSON Pointer encoded `keys`. `created` records whether files first
made a copy, for both `ro` and `rw`. Native links have no state entry. Entries
are keyed by complete relative path, never basename or directory ledger. A run
that ends owning nothing deletes the state file instead of saving empty `files`,
so an absent state file means nothing is owned and generated prune of an empty
map skips the engine. State and backups share a directory enforced to mode
`0700` before any state or backup write, including when the directory already
exists. Backup contents and modes remain unchanged. State itself is private mode
`0600`, written with atomic replacement under a namespace lock immediately after
each successful file mutation. An invalid version, path, or state symlink fails
closed. Only the engine writes this state.

State version 0 has the same `files` payload as version 1. Under the lock, the
engine validates version 0, changes only its version to 1, validates again, and
atomically saves it before reconciling destinations. Missing state begins at
version 1 and is not written until something is owned. A second load of version
1 does not rewrite the state. Missing or unsupported versions and malformed
payloads are refused before destination mutation; future migrations append to
the ordered chain.

## Legacy ownership import

Owners whose earlier writers kept their own ownership ledgers declare them in
`ai.<owner>.legacyLedgers` (`{ codec; ledger; path; }`) outside their enable
gate (runtimes through ungated `migrationConfig`), so a disabled owner still
drains them; `git grep legacyLedgers` lists every declaration. The backend
passes the list as `--legacy-plan` and the old state root as `--legacy-state`:
HM `${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools`, devenv
`$DEVENV_STATE/nix-agentic-tools`. `ledger` is relative to that root. `path` is
the root-relative container of a `dir` ledger's units (`.` for root filenames)
or the document a `json` ledger describes. A `dir` ledger is TSV, one
`<name>\t<sha256 of the bytes last written>` line per unit; a `json` ledger is
`{"managed_paths": [[segment, ...], ...], "version": 1}`.

Before creating the final state directory or taking its lock, the engine renames
`<legacy-state>/files2` to `<legacy-state>/files` when only the first exists.
When both exist, `files` wins and `files2` stays untouched; when neither exists,
the move creates nothing.

| Step               | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| When               | Inside reconciliation, under the namespace lock, after loading state and its version chain, before any retirement or write. Both phases run it; prune runs first, so HM retires an imported copy before `checkLinkTargets`.                                                                                                                                                                                                                                            |
| Trigger            | A listed ledger file exists. It is not a state version: a ledger can coexist with version 1 state after a crash between saving state and deleting the ledger.                                                                                                                                                                                                                                                                                                          |
| Order              | Ledgers sorted by `ledger`; within one ledger, units sorted.                                                                                                                                                                                                                                                                                                                                                                                                           |
| Skip               | Ledger file absent. A path already in state (state wins, which makes a re-run idempotent). A unit whose destination is absent. A `dir` unit whose destination is a symlink (a native link, not a copy). A `dir` unit name containing `/` or starting with `.`.                                                                                                                                                                                                         |
| Refuse             | A ledger that is not a regular file; a ledger or unit path that is not root-relative; an undecodable `dir` ledger; a `json` ledger that is not version 1 with distinct nonempty string-list addresses; a destination that is neither a regular file nor (for `dir`) a symlink; a `json` document that does not parse with the JSON codec (leading `//` lines accepted); symlinked parents. The run fails before saving anything for that ledger, and the ledger stays. |
| `dir` unit → state | Path `<container>/<name>`. Entry `{ method = "ro"; format = "raw"; digest = <witness if 64 hex, else on-disk digest>; mode = <on-disk mode>; created = true; keys = {}; }`.                                                                                                                                                                                                                                                                                            |
| `json` → state     | Path = container. Entry `{ method = "rw"; format = "json"; digest = <on-disk digest>; mode = <on-disk mode>; created = false; keys = { <JSON Pointer of each recorded address present in the document> = <key digest of its value>; }; }`.                                                                                                                                                                                                                             |
| Commit             | Validate the merged state, save it atomically, then delete the ledger file. A crash between the two re-imports nothing new (paths already in state) and deletes the ledger next time.                                                                                                                                                                                                                                                                                  |
| Leave              | `<ledger stem>.bak/` backup directories and `materialize/lock`: user data and an inert lock.                                                                                                                                                                                                                                                                                                                                                                           |
| Then               | Ordinary reconciliation: an imported path the plan no longer declares retires (copy removed, backup if edited; `rw` keys removed, native keys kept); a declared one follows the overwrite rule. A disabled owner passes an empty plan and the same legacy list, so its old copies drain.                                                                                                                                                                               |

| Case                                                                | Result                                                                                         |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `dir` copy edited locally before the import                         | Witness ≠ disk: the first overwrite or retirement backs it up.                                 |
| `dir` line whose witness is not 64 hex digits, or a `json` document | The on-disk bytes become the baseline; the first owned change is not backed up.                |
| Owner's configured directory changed since the ledger               | The ledger name or container no longer matches; it is not imported and its files stay on disk. |
| Two ledgers list one path                                           | The first in ledger order wins; the later ledger is still deleted.                             |

## Backend lowering and order

[The ai-module design](DESIGN.md#backend-graph-and-execution) defines the
backend graph and delivery phases. Both backends lower through `ai.files` and
the shared activation graph. The engine never records, validates or retires
native symlinks. A backend removes its old native link before apply writes a
`ro` or `rw` copy; apply refuses any link still at that path. Prune retires an
owned copy before native linking. Native collision handling belongs to the
backend.

## Runtime engine and codecs

Python is used for path-safe filesystem operations, document parsing, hashing,
atomic writes, and cross-format merge. It is one executable with `--plan`,
`--root`, `--state`, `--phase prune|apply`, and for the one-time legacy import
`--legacy-plan` / `--legacy-state` (always passed together); backend shells
supply roots and call it, setting `FILES_BASH` for `run` content. A lock
serializes runs for a namespace. It validates both plan and persisted state on
entry, rejects absolute/traversal paths, walks each existing parent with `lstat`
(never follows a symlink), and refuses non-regular copy destinations. It creates
missing real parent directories but removes no parent directory: unrelated
siblings survive. It writes the backup before a destructive change, mutates one
destination, then atomically replaces the state file. There is no journal or
rollback. If a process stops between the file change and state write, one
destination may differ from the recorded image. A later run applies the ordinary
overwrite rule when the document still parses under its recorded format. A
stopped `rw` format conversion may leave new-format bytes with the old format in
state; parsing then fails closed and requires operator repair. A new `rw` file
published before its state update can be adopted on rerun, but its `created`
provenance is lost, so retirement keeps the emptied file. Prune never renders
`content.run`. A desired path's parents are checked after retirement of obsolete
owned paths, so an owned file can become a directory parent; unmanaged files and
remaining symlinked parents are still refused.

One engine mutation function applies the overwrite rule to every owned path:
`current == desired` → retain the current file without backup; a regular file
whose bytes equal the desired file's and whose permissions alone differ →
restore the desired mode without backup, since a git checkout rewrites a
committed copy at `0644` and a backup would preserve nothing;
`current == last installed` or `current` absent → mutate without backup;
otherwise back up, then mutate. It compares full file images, including bytes,
permissions, and type, for writes, removal, mode changes, and format conversion.
An `rw` merge selects keys to change, then applies this rule once to the whole
document. A local edit to native keys therefore gets a backup when an owned key
changes; an unchanged declaration retains local formatting without a backup.
Backups use content-addressed files under the namespace state directory, named
with a bounded namespace prefix and a digest of the full relative path, byte
digest, and mode. Reusing an existing name verifies its full image. Content and
mode are preserved. No destination backup is overwritten. If a path unexpectedly
becomes a symlink or special file, fail closed rather than copying through it.
When switching from `rw` to `ro` or `symlink`, retract declared keys first; if
native keys leave a document, refuse the whole-file takeover and name the path
rather than destroy them. A retired `rw` document is deleted only when all three
hold: `created = true`, no key remains after retirement, and the codec preserved
no comments; otherwise the remaining document stays on disk, unowned, and a
switch to `ro` or `symlink` at that path is refused naming the path. For
`ro → rw`, prune retains the old regular file; apply parses it with the old
structured codec, or with the target codec when the old format is keyless, then
merges declared keys while retaining all others. Ownership transfers from
whole-file `ro` to key-owned `rw`; `created` carries forward whether files
originally created the `ro` file. Apply makes the transferred copy writable:
target `mode` wins; otherwise use `0700` for `executable = true`, `0600` for
`false`, or `0600` plus the previous execute bits for `null`. `symlink` to a
copy requires the backend to remove its old link before apply. `rw` to `rw` with
format change parses the old format using previous state, retracts old declared
keys, then writes the new codec. If native keys cannot be represented by the new
codec, fail without replacing the old document. A `ro` format change re-renders
from the new declaration even if its content option is unchanged; a `symlink`
format change uses native linking. A `rw` format switch refuses documents with
preserved comments when the target codec cannot carry them without loss.

A codec has `parse(bytes) -> root map`, `serialize(root map) -> bytes`, and
`empty() -> root map`. JSON uses Python `json`, accepting and preserving leading
full-line `//` comments as a prefix. TOML uses `tomlkit` to preserve existing
comments and key ordering. YAML uses `PyYAML` `safe_load`/`safe_dump`; comments
are not preserved, so YAML `rw` is allowed only for documents whose comment loss
is acceptable. All codecs require a root map; parsing errors abort before any
file or state mutation. Rendering `content.value` uses the same pinned Python
codec tool at build time for TOML/YAML and `builtins.toJSON` for JSON; no
import-from-derivation read-back occurs at evaluation. The normalized plan
retains original declared `value` for `rw` and carries a `content.rendered`
store path for the encoded bytes. The runtime engine reads those bytes and
parses them with the selected codec. YAML anchors and aliases are refused before
merge because they share containers whose mutation could also change a native
key.

The merge algorithm flattens maps to leaf key paths; a scalar or list is one
atomic leaf, and list elements are never individually owned. Empty maps declare
no leaf and do not claim an empty table. Existing empty maps still count as
native keys during retirement and block whole-file takeover or replacement by a
scalar. An empty map substituted for an owned leaf stays native when that leaf
retires. At apply: remove `previous.keys - desired.keys` deepest first, pruning
only empty parent maps; then set all desired leaves, creating needed parent
maps. Both operations use the document overwrite rule: a newly claimed existing
key is adopted when identical; a differing value changes the document and its
backup depends on the full current image. A map-to-scalar change replaces that
subtree at the declared address; if replacement would erase undeclared
descendants, refuse with a path-specific conflict. Native siblings at any depth
remain. A single guarded replace refuses a destination that changes during
publication. A malformed document is never overwritten. Mode is `ro`: default
`0444` (or `0555` when executable), source execute bits preserved when
`executable = null`; `rw`: new document default `0600` plus source execute bits
when `executable` is null, or `0700` when executable is true; existing mode is
preserved when both `mode` and `executable` are null. Explicit `mode` always
wins.

## Transition matrix

`H` means HM's prune / `home.file` / apply order above; `D` means devenv's guard
/ `files` / apply order. `S` is an engine state entry and `∅` is none. `R` is a
real file, `L` a native link, and `M` a merged document. The overwrite rule `O`
applies to owned copies, including their retirement.

| Old → desired event                    | HM result / engine state                                                   | devenv result / engine state |
| -------------------------------------- | -------------------------------------------------------------------------- | ---------------------------- |
| absent → `symlink`                     | H: `L` / `∅`                                                               | D: `L` / `∅`                 |
| absent → `ro` (`O`)                    | H: `R` / `S(ro)`                                                           | D: `R` / `S(ro)`             |
| absent → `rw` (`O`)                    | H: `M` / `S(rw, keys)`                                                     | D: `M` / `S(rw, keys)`       |
| `symlink` → `symlink` change or format | H: native link updated / `∅`                                               | D: native link updated / `∅` |
| `ro` → `ro` change or format (`O`)     | H: new `R` / new `S`                                                       | D: new `R` / new `S`         |
| `rw` → `rw` change or format (`O`)     | H: old keys retired, desired keys merged / new `S`                         | D: same / new `S`            |
| `symlink` → `ro` (`O`)                 | H: native link removed, new `R` / `S(ro)`                                  | D: same                      |
| `symlink` → `rw` (`O`)                 | H: native link removed, new `M` / `S(rw)`                                  | D: same                      |
| `ro` → `symlink` (`O`)                 | H: `R` retired before native link, `L` / `∅`                               | D: same                      |
| `ro` → `rw` (`O`)                      | H: retain `R` through prune; merge, make writable / `S(rw, keys, created)` | D: same                      |
| `rw` → `symlink` (`O`)                 | H: keys retired, deletable `M` removed, `L` / `∅`                          | D: same                      |
| `rw` → `ro` (`O`)                      | H: keys retired, deletable `M` replaced by `R` / `S(ro)`                   | D: same                      |
| `symlink` → removed or disabled        | H: native link removed / `∅`                                               | D: native link removed / `∅` |
| `ro` → removed or disabled (`O`)       | H: `R` removed / `∅`                                                       | D: same                      |
| `rw` → removed or disabled (`O`)       | H: owned keys removed, native keys retained; deletable `M` removed / `∅`   | D: same                      |

No-op changes retain the current bytes, including local whitespace; state may
adopt that full image for later comparisons. At N→0 the plan is empty; prune
still runs, retires every owned copy and deletes the state file, and no apply is
generated. A disabled owner has the same result: it forwards no entries. An
explicit `ro` mode must include the owner read bit because retirement compares
the current bytes with the installed image before draining it.
