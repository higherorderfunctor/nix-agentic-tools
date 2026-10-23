# Installed Nix extractor

> **Last verified:** 2026-10-23 — P2a installs one coordinator for database
> creation and query tests, preserving authenticated partial work; Q0 remains
> deferred.

## Terms

- ABI: the shared database tables, identities and text encodings.
- Anchor: a syntax node identified by file, byte range, kind and child path.
- Binding: an explicit map entry resolving an evaluation or argument reference.
- Coordinator: the program that admits sources and joins both producers.
- Discovery: evaluating the project function that declares targets and bindings.
- Extractor: the installed program and schema CodeQL uses to build a database.
- NAR hash: Nix's content hash of a complete directory tree.
- Oracle: an expected answer obtained independently of extraction.
- Pack: a named CodeQL library, query or test directory.
- Producer: a component that emits syntax or evaluation facts.
- Q0: the deferred Step 0 query about which file sets an option.
- QL: CodeQL's query language.
- Request: an explicit option path, metadata facet and work limits.
- Run: one extraction identity joining schema, implementation and source
  snapshot.
- Snapshot: admitted source identities, directory hashes and selected file
  digests.
- Target: an explicitly named configuration with bounded requests.
- TRAP: the fact-file format CodeQL imports.

## What installs and why

`lib/packaging.nix` assembles extractor, library and query products. The
extractor's schema and statistics are copied from the library, preserving one
schema for fact import and query compilation. Its `autobuild.sh`,
`index-files.sh` and `qltest.sh` hooks all invoke `src/extract.py` through the
same coordinator launcher. This keeps ordinary database creation and query tests
on the production path.

The recipes under `packages/ai/devTools/` expose the separate products and a
`codeql-nix` command. That command uses the existing CodeQL owner's
`customizePackage` interface to install the Nix extractor and packs beside its
engine. `lib/default.nix` exposes the same packaging function. Pack identities
remain those established by [owner-layout.md](owner-layout.md); the library
retains its own location interface.

## Admission and discovery

Invoke the customized command with
`codeql database create --language=nix --source-root=PROJECT DATABASE`. The
`inputs` extractor option is a JSON map from input name to `{path, narHash}`;
each path must be an absolute directory and match its supplied NAR hash. The
coordinator first copies the project into a private directory and hashes that
stable copy. It excludes only exact CodeQL work-in-progress database, TRAP,
archive and scratch paths supplied by the engine, so query-test output under the
source root cannot change the admitted bytes. Query tests supply the same input
map through `CODEQL_EXTRACTOR_NIX_OPTION_INPUTS`.

The default target file is `.nixql/targets.nix` under the source root. The
`targets` extractor option selects another admitted file; relative paths resolve
under that root. Its `{ inputs, source }: { manifest, bindings }` function
receives pinned local input trees and project source. Discovery uses the
existing evaluation supervisor's offline, restricted, pure Nix invocation and
process controls, with a 60-second deadline, 2048 MiB memory limit and 8 MiB
output limit. Discovery passes its initial directory hashes through
`sourcePins`; the evaluator must match them before constructing pinned local
input trees. Coordinated evaluation requests enforce the same guard. No second
discovery evaluator is introduced.

The result must contain exactly `manifest` and `bindings`, with the manifest
passing the existing [target contract](target-contract.md). Returned copied-tree
paths are restored to admitted paths before request processing; project
evaluation uses the private copy. Syntax retains the original project path for
file and archive identity, checks those bytes against the copied-file digests
and snapshots each file for parsing. Target source roots must match admitted
directory paths. Their content identities and snapshot fingerprints are replaced
with the coordinator's admitted identities; caller labels do not determine the
installed run snapshot.

## One run across both producers

`RunIdentity` in `src/extract.py` owns the shared identity. It hashes the
installed combined schema, producer implementation bytes, admitted root
identities and selected file digests. Named dependency pins participate even
though their syntax is not selected. Only project-root `*.nix` files are
selected for syntax extraction.

The coordinator passes that identity to [syntax extraction](source-identity.md)
and the [evaluation supervisor](evaluation-isolation.md). Syntax checks its
manifest snapshot; evaluation checks target snapshot fingerprints. Each returned
fact collection must pass ABI validation and contain exactly the expected run
row. A foreign run or snapshot is refused. Coordinated children omit their run
row when writing TRAP; the coordinator publishes the sole `nx_runs` row. The
syntax module loads the neighboring coordinator by file path, preserving
callers' module search paths when imported as a standalone driver.

Syntax and evaluation write into temporary staging directories. Authenticated
file rows and copied-path mappings connect evaluation origins through the
existing [module adapter](module-adapter.md). Before copying staged archives and
TRAP into CodeQL's destinations, the coordinator validates the combined facts,
recopies the original project with the same exclusions and checks its NAR hash
against the initial private copy. It also rehashes admitted dependencies. A
changed snapshot refuses staged publication, including completed requests from
an otherwise partial run.

Publication copies completed files individually and writes the coordinator run
record afterward. This is no whole-run atomic rename or crash-recovery protocol.
Authenticated partial evaluation preserves completed request facts, per-request
failures and diagnostics, then returns nonzero when a phase is incomplete. Mixed
snapshots or invalid child facts never reach that promotion step. Missing,
throwing, malformed or forbidden-fetch discovery returns failure with a failed
phase and bounded diagnostic. Absent metadata never establishes success.

## Evidence and changes

`checks.nix` imports `checks/installed.nix`, exposing the Linux-only
`checks.x86_64-linux.codeql-nix-installed`. Its explicit nonempty runner
executes six installed-path tests and four separate review-regression tests
before writing `$out/evidence`. The installed tests cover offline language/pack
lookup, identical schema bytes, database creation with syntax and real module
metadata under one run, an explicit target file, query-test extraction,
discovery refusals and stale input pins. Direct Nix evaluation independently
checks priority changing from `100` to `50`; this does not implement Q0.

The regression suite uses deterministic pin controls for a transient dependency
change during discovery, preservation of completed requests beside failed
requests, refusal to publish partial work after a snapshot change and standalone
syntax-module import. These checks exercise coordinator boundaries with
controlled producers, complementing the installed database tests.

The one-run and stale-pin cases do not independently inject a foreign child
envelope. Keep that distinction when reporting mixed-snapshot coverage. General
evaluator isolation and authenticated syntax mapping retain their separate owner
checks.

To change installation, edit the existing packaging assembly and recipes
together; keep all hooks on the coordinator and preserve shared schema bytes. To
change identity or admission, update `RunIdentity` and both producer boundaries
together, retaining ABI/target-contract validation and independent refusal
expectations. Register new fixtures through the owner check entry point. Format
changed files, run the affected owner checks through CI and update this note
plus its registry entry when these obligations change. Regenerate instruction
projections from their sources rather than editing generated consumers.
