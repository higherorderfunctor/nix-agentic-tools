# Source transactions and syntax anchors

> **Last verified:** 2026-10-23 — S2 authenticates archived source bytes and
> transports the companion anchor index through the existing kit metadata table.

`lib/packaging.nix` exposes
`syntaxDriver/bin/nixql-syntax MANIFEST_JSON OUTPUT_DIRECTORY`. The manifest
supplies roots with `logicalName`, `rootContentIdentity`, `path`, `sourceKind`
and explicit `files` entries containing root-relative `path` and the SHA-256
`contentHash` of admitted bytes. This syntax-only input is separate from the
evaluation target manifest. F1's durable identities retain its existing
root/file/anchor components; SHA-256 authenticates this driver's snapshot
admission without changing the opaque digest ABI.

The driver resolves roots and source paths, refuses escapes through symlinks,
verifies the declared digest and snapshots the bytes privately. The pinned kit
and `src/anchors.rs` both read those snapshot bytes. A second checkout read
after extraction must match before publication. Renaming or moving a checkout
changes physical mapping, while byte edits change file and anchor identity.
`rootContentIdentity` is caller-supplied; the driver verifies selected file
digests rather than recomputing a digest of the whole root. Equal text in
different files or roots remains distinct.

Completed raw TRAP is published by rename only after source authentication,
exact-text preflight and F1 transaction validation succeed. Source bytes are
archived under the absolute canonical path with its leading slash removed.
`CODEQL_EXTRACTOR_NIX_TRAP_DIR` and `CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR`
select standard CodeQL publication destinations; otherwise `trap/` and
`archive/` live under the output directory. `facts.json` uses F2's envelope and
contains only F1 relations. Independent completed files survive a refusal. A
failed representable file retains its identity and failed syntax result, with a
bounded enclosing run diagnostic; oversized identity text retains only the
enclosing failure. Source publication is per file, not atomic across a run; the
archive entry is written before the completed TRAP file.

The companion index uses a line-start map over archived UTF-8 bytes. Columns
count bytes: tabs and CR each occupy one column. Raw ends are inclusive; a node
ending immediately after LF ends on the preceding line, including that LF's
column. Empty spans use the kit's start column minus one as the end column.
Anchors retain exclusive byte ends, original grammar kinds and ordered concrete
child-index paths. The index separately records the kit's structural path, which
excludes error/missing children from sibling ordinals and detaches extra tokens.
Pruned nodes retain anchors but have no precise raw association.

`nix/internal/RawBridge.qll` joins authenticated visible F1 identity components
to the raw `File` interface through namespaced `databaseMetadata` entries. It
checks grammar kind, normalized coordinates and the kit structural path before
counting raw candidates. One candidate is `unique`; zero is `unmapped`; multiple
are `ambiguous`. Only a unique association exposes a raw location. Raw labels
are never manufactured, shared with F1 entity types or exposed as durable
identity.

The private metadata keys frame root key, relative path and digest after a
namespaced prefix. `nixql.s2.file|` maps that identity to archived absolute path
and source byte length; `nixql.s2.line|` supplies one-based line numbers and
line-start byte offsets. `nixql.s2.path|` additionally keys the concrete child
path and supplies the kit structural path. Fields escape `%` as `%25` and `|` as
`%7C`, then join with `|`. RawBridge derives normalized coordinates from anchor
bytes and the independent line map; changing an anchor byte span cannot inherit
the original coordinates. Both metadata columns are exact UTF-8 tuple text and
are checked against F1's 1,048,576-byte ceiling before publication. These
entries use the existing generated schema table; neither the 35-relation
handwritten ABI nor the combined schema changes. They are not evaluation facts
or authenticated evaluator origins. As with every extractor relation, these are
trusted producer evidence; fabricating a file admission record is outside the QL
consumer's archive-authentication boundary. The driver tests establish that
boundary from actual bytes.

The raw writer reuses F0's audited token, path and diagnostic preflight before
calling the kit; added metadata and handwritten facts receive their own
preflight. An oversized field refuses the entire file transaction with
`text-field-too-large`, without raw nodes or anchors from that file. Re-audit
the raw writer when the grammar, kit or selected emission paths change.

`checks.x86_64-linux.codeql-nix-anchors` registers the driver suite through F3,
inherited raw preflight cases and independent QL/archive acceptance. Keep
expected rows independent of generated output, including duplicate raw
extraction, unauthenticated identities, Unicode/CRLF, empty spans and ends at a
line start. Later AST/evaluation slices must consume this bridge rather than
introduce a second source mapping.

To change this boundary, update the driver, companion index and RawBridge
together, keeping the metadata framing and concrete-to-kit path translation in
agreement. Change F1 first if durable identity or relation semantics change;
regenerate the combined schema through S1 when required. Format changed files
and run `checks.x86_64-linux.codeql-nix-anchors` plus the affected ABI or
raw-inventory check. Keep archive and refusal controls: successful query rows
alone cannot establish that admitted bytes match the source snapshot.
