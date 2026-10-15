## Open keys: advisory inspection and explicit refusal

> **Last verified:** 2026-10-15 — CPA uses shared freeform refusal, credential
> names at every depth and owner reasons at the top level, with config-level
> spelling warnings on both backends; warning allowlists cannot permit refused
> fields. Kiro retains its workspace delivery allowlist.

`lib/open-keys` is a pure `{lib}` import. It has no module, package, file
writer, or runtime dependency. Owners supply schema data and choose the policy:
unknown names warn; an explicitly selected credential refusal fails. Inspection
returns the original value unchanged.

### Normalize a known surface once

A node can declare `struct` children, one `map` value node, one `list` element
node, and `open`. Struct children take precedence over a map fallback. An open
node accepts unknown children; map entry names are unrestricted while their
values are inspected. Lists descend only through an explicit element node.

`fromPaths {paths; names?;}` adapts dotted paths with `*` maps and `[]` lists.
It understands glued list markers and branch markers from flattened union
schemas. Childless leaves are open because path-only data cannot describe
arbitrary payloads below them. `names` declares literal top-level names,
including names that themselves contain dots. A caller with complete flat file
keys must keep those keys literal and leave their values open, rather than
splitting them into a fabricated nested schema.

### Emit warnings from module config

`inspect {known; value; optionPath?; allowed?; allowOptionPath?; notes?;}`
returns the unchanged `value` and warning strings. Unknown struct children get
spelling suggestions from their declared siblings. Allowlist entries are
strings: `services.*.newField` matches user-named maps, `entries[].newField`
matches list elements, and JSON-quoted segments preserve literal dots
(`"chat.futureKey"`). The diagnostic prints a Nix list containing the exact
entry to add, and names `allowOptionPath` when supplied. Owner notes start on a
new line. `allowlistSyntax` supplies the entry prose shared by the Claude, Kiro
and CPA allowlist option descriptions. Redundant suppressions warn,
distinguishing declared keys, literal names accepted under maps, and unchecked
freeform containers. Wildcard map paths retain the child status. An entry with
no schema status and no matching unfiltered finding warns that it suppresses
nothing; this also catches unquoted dotted entries aimed at literal names. Stale
and unused diagnostics retain the exact raw entry, including quotes and list
markers.

Compute inspection from the same filtered value the writer receives, so null
option defaults cannot become false diagnostics. Pass option paths as segment
lists; `lib.showOption` quotes literal dots in user-chosen keys. Attach warning
strings at config level behind `options ? warnings`, on every supported backend.
Type merge can throw or trace but cannot publish module warnings.

### Refusal is a separate policy

`credentialReason name` normalizes camel case, acronym boundaries, dots and
hyphens before matching credential suffixes in `patterns.nix`. Runtime-value
classification delegates this same name test, while retaining its own type and
hint checks. Keep that table as the single name-policy definition.

`check {name; optionPath?; reasons?;}` returns `assertion`, `message` and
`reason`, using `credentialReason name` unless the owner's name-to-reason map
supplies an exact refusal. Owner reasons take precedence, including for
credential-shaped names. Reasons remain owner data; the shared library names no
runtime fields. Modules must select only `assertion` and `message` when
appending an assertion; the extra diagnostic `reason` is not a module assertion
field.

`refuse {type; reasons?;}` wraps an attribute type's `merge` for use as a
submodule `freeformType`. The module system does not call that type's `check`,
so refusal runs before merging each definition's keys. Credential-shaped names
are refused at every depth of a definition, through attribute sets and lists
(`accounts.a.metadata.access_token`); owner reasons apply to top-level names
only, because an owner names its own fields and a nested `type` is someone
else's. Ordinary unknown keys and their arbitrary values pass through unchanged.
CPA supplies its reconciled `accounts.ignored` reasons and selects this guard
only for open account fields; its declared secret options keep their own types.
Warning suppressions never bypass refusal. Error messages contain the option
path and reason, no values.

Codex's OAuth client-secret assertion takes the shared credential decision and
appends its own delivery remedy. The composed message ends with a period and no
trailing newline. Select refusal only at a surface whose owner already forbids
that field. Unknown settings do not become credential refusals merely because
they use the inspector. Diagnostics contain names and reasons, never the refused
value.

Kiro's unknown-key inspection runs on both backends, with
`ai.kiro.cli.allowUnrecognizedSettings` suppressing spelling warnings. Its
separate devenv assertion rejects **every** written key outside the measured
`workspaceOverridableSettings`: the pinned binary discards those keys at project
scope. A spelling suppression cannot grant project-scope delivery. Home Manager
keeps unknown settings available before the extracted registry catches up.
