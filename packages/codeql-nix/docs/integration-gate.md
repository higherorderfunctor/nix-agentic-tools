# Nix language integration gate

> **Last verified:** 2026-10-23 — F0 shares pinned kit inputs and the canonical
> location adapter with S1; its bootstrap proof remains test-only.

## Purpose and boundary

F0 is a disposable fixture in `checks/fixtures/bootstrap/`, exposed by
`checks/bootstrap.nix` as `checks.x86_64-linux.codeql-nix-bootstrap`. It settles
whether the shared tree-sitter kit, a handwritten relation and the existing
CodeQL engine can form one queryable database. It is not the production
extractor or an implementation of Nix evaluation: its second producer reads
`targets.tsv`.

The check uses `packages/codeql`'s existing JavaScript engine bundle. It builds
Rust with `rustPlatform.buildRustPackage` and vendored dependencies, generates
the syntax schema and `Ast.qll`, then appends `nx_bootstrap_targets`. No second
engine factory, discovery framework or configuration wrapper is introduced. The
result contains only an evidence file; the engine and trial databases remain
build inputs and temporary artifacts.

## Compatibility pins

- CodeQL CLI: `2.27.3`, checked against the existing owner's `sources.json` and
  asserted at execution.
- Grammar: `nix-community/tree-sitter-nix` commit
  `38a15330421d20f3a4d380759f9634d39ba3d8ec`; crate `0.3.0`.
- Kit: `github/codeql` tag `codeql-cli/v2.27.3`, commit
  `a1575b98a8cc19bcfa7bb6cb41be688cb3dae65c`; crate `codeql-extractor` `0.2.0`.
- Parser runtime: `tree-sitter` `0.26.13` in the committed `Cargo.lock`.

The fixed-output source hashes and Cargo vendor hash live in `lib/kit.nix`,
shared by F0 and S1; the bootstrap fixture's `Cargo.lock` fixes transitive
dependencies. Changing the CLI requires a kit compatibility audit rather than
silently keeping this proof valid.

## Installed interfaces and join

The installed extractor has `codeql-extractor.yml`, `nix.dbscheme`, its
same-basename statistics file and `tools/{autobuild,index-files,qltest}.sh`. The
descriptor selects `column_kind: utf8`, build mode `none` and the legacy test
hook. The separate library has its own manifest, generated schema, statistics,
generated syntax and handwritten QL.

`index-files.sh` receives a file-list path and emits syntax TRAP plus source
archives. The test hook indexes `.nix` files in the current fixture directory,
then separately launches the target producer into the same TRAP directory. Both
producers publish completed files by rename before the CLI imports the database.

`ql/lib/codeql/Locations.qll` is the canonical `overlay[local]` language
interface, copied into F0 by `checks/bootstrap.nix` and shared with S1: `File`
exposes absolute and source-root-relative paths; `Location` exposes its file and
start/end line/column. The generated syntax imports that interface.
Same-basename statistics belong beside the library schema as well as beside the
extractor schema.

`Bootstrap.qll` joins the handwritten target to a generated token through the
shared `@file` identity and exact token text, then returns its location. It does
not reconstruct a raw node label from coordinates. `Raw.ql` requires six
integer-token rows, including identical `41` text in two different files and a
recovered parse. `Join.ql` requires only `selected/41` and `coordinate/73`;
wrong-text, absent-file and unselected-file controls cannot join.

## Coordinates: measured and remaining

The six golden rows verify one-based, inclusive byte columns for integer tokens.
`coordinates.nix.in` becomes CRLF during the check; its second line contains a
tab and UTF-8 `é` before `73`. That token occupies columns 27–28, rather than
decoded-character columns 26–27. The third-line `97` occupies 10–11. A missing
right-hand side in `recovered.nix.in` still permits the subsequent `41` at line
3, columns 10–11.

These assertions establish this file/location interface and these token spans.
They do not establish a unique syntax anchor, Nix evaluator position conversion
or complete coordinate coverage. S2 still needs the companion anchor bridge and
tests for empty spans, identical/ambiguous spans, multiline end-at-line-start
conversion, comments, interpolation and paths. The pinned kit's
`extractor/mod.rs:955–1022` handles empty ranges and ends at a new line; that
source behavior is not independently asserted by these golden rows.

## Exact text before the kit can clip it

The pinned kit's `trap.rs:177–187` clips a string argument beyond 1,048,576
UTF-8 bytes before doubling quotes. `src/lib.rs` therefore checks converted
token text and normalized file/folder paths before real extraction. The selected
simple extraction path emits source text only through token values; grammar
product tables carry labels and integers. Empty-file and diagnostic-tag strings
are constants. The unused alternate parser path, YAML, database metadata and
overlays are outside this fixture's producers; the CLI supplies the source-root
prefix.

Raw TRAP diagnostic messages also contain the source path. A source-derived
bound covers the selected tuple diagnostic templates and grammar/schema names.
The kit's location-correction internal errors go only to its logger, not to the
`diagnostics` tuple. When that bound cannot guarantee a safe message, extraction
first applies path preflight and checks the diagnostic bound for a short virtual
path before invoking the kit privately at that path. This guarantees the dry
output has not been clipped. It then checks the actual decoded diagnostic
arguments with the real path restored before real extraction. This applies to
ordinary trees as well as recovered trees. The second producer checks each TSV
field and every normalized derived absolute file/folder path before publishing
its transaction.

The shared `syntax` function serves the installed extractor and
`bootstrap-probe`. The latter reads a synthetic absolute path from a UTF-8 file
and never creates or archives a file at that path. In probe mode, oversized
syntax fields return exit 2 with bounded `text-field-too-large` stderr and no
completed TRAP; oversized evaluation paths fail without publishing even an
earlier valid target.

`test-preflight.py` checks 18 token/path cases: attribute keys, quote-heavy
comments, virtual file paths, source path fragments, ASCII strings and multibyte
strings, each at 1,048,575, 1,048,576 and 1,048,577 bytes. Accepted arguments
must round-trip through decoded real TRAP tuples; oversized arguments must
visibly refuse. Ten more cases cover parse-error and ordinary-tree type-mismatch
diagnostics, including safe near-limit messages and oversized messages/paths.
Three evaluation cases independently size the derived absolute path at the same
boundaries, with every input TSV field individually within the limit. These 31
cases support the audited emission paths; they do not replace re-auditing the
selected schema and kit when either pin changes.

## Offline verification and maintenance

The Nix sandbox successfully resolves the installed extractor and runs
`codeql test run` against the separate local library: `Raw.ql` and `Join.ql`
both pass. With an empty search path, extractor lookup fails with no extractor
named `nix`; query compilation fails because `nix-agentic-tools/nix-bootstrap`
is not local and no dependency lock is present. The check requires both
failures. It does not attempt a dependency download or prove a general network
fallback policy. Rust compilation uses the Nix-vendored Cargo inputs offline;
initial admission of missing inputs is a separate operation.

Change this gate through its owner-local check and fixture, keeping
hand-authored expected rows independent of extractor output. Run the bootstrap
check after changing pins, schema assembly, installed entry points, path
handling or preflight. Re-audit all tuple-string emission sites, diagnostic
templates and UTF-8 conversion before claiming the changed kit preserves exact
text. Keep production schema/identity, adapters, anchors and evaluation status
machinery in their later slices; this fixture proves only their integration
prerequisites.
