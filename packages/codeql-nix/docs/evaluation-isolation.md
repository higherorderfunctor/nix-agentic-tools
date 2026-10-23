<!-- cspell:ignore unrequested -->

# Evaluation isolation and projection publication

> **Last verified:** 2026-10-23 — E1 implements the serialized projection
> boundary; E2a adds [module metadata](module-adapter.md).

## Purpose and fit

`src/eval/supervisor.py` accepts an F2 manifest, explicit opaque-reference
bindings and a TRAP destination through `supervise`. It launches one subprocess
at a time for each selected request. Failure in one request leaves completed
projections available. It does not discover flake outputs, enter a devenv shell
or select an adapter from its label. E2a reports module-adapter support. The F2
`option-metadata` domain supports `declarations`, `definitions`, `isDefined` and
`priority` facets at root depth (`maxDepth = 0`) in `metadata` mode.

`src/eval/protocol.py` enables all three F2 custom formats and delegates exact
text, identity and fact validation to F1's `schema/abi.py`. Its TRAP renderer
uses F1 global labels and columns. Keep this shared authority: adding a second
relation validator or inferring success from empty output would violate the
[database](database-contract.md) and [target](target-contract.md) contracts.

## Runtime bindings and admission

The caller supplies a map resolving `evaluation.reference`, `moduleArgumentsRef`
and `specialArgumentsRef`; labels are never parsed as selectors. A binding
selects either an explicit `expression` path or a trusted fixture `command`.
Module and special arguments must be JSON representable. This boundary does not
transport arbitrary runtime functions or secret-bearing argument closures.

For a real expression, the supervisor resolves the path under a declared source
root, hashes each admitted root with Nix and imports a hash-pinned local
`fetchTree` copy. A separate admitted tree carries the request job. Roots are
admitted whole directories; this is not file-level snapshot authentication.
Descriptor identity and fingerprint strings are caller-supplied evidence, not
independently authenticated hashes of the copied roots.

A second declared root is accessible through its exact hash-pinned local
`fetchTree` URI. A projection may use this shape, with that root's actual path
and independently computed `nix hash path` result:

```nix
import ((builtins.fetchTree {
  narHash = "sha256-<root hash>";
  path = "/absolute/declared/dependency";
  type = "path";
}).outPath + "/value.nix")
```

Original absolute imports are not rewritten and remain blocked by pure
evaluation. E1 does not manufacture framework input handles. Each request gets a
disposable local Nix store and writable home/cache/temp directory. The
environment is rebuilt, and Nix receives pure/restricted evaluation, offline
operation, an allowlist of the exact pinned local tree URIs, no substitution, no
builders, `max-jobs = 0` and disabled import-from-derivation. No lock-update
command is invoked. These controls apply to Nix expression bindings; a trusted
command binding is a test transport and does not receive a network or filesystem
sandbox.

The Linux check supplies `pkgs.nix` (tested Nix 2.34.9) from the flake's locked
nixpkgs through `CODEQL_NIX_TEST_NIX`; production callers select the executable
through `supervise(..., nix=...)`. Changing that runtime requires rerunning the
real isolation cases. This slice makes no Darwin isolation claim.

## Budgets and transaction boundary

A request deadline covers root hashing and evaluation. Child processes get a new
process group, an address-space ceiling from `maxMemoryMiB` and disabled core
dumps. Both output pipes are drained, with their combined bytes bounded by
`maxBytes` (`byte-limit` on overflow). F1 separately enforces its per-field
1,048,576-byte ceiling (`text-field-too-large`); multiple legal fields may
exceed that size in aggregate. Timeout or excess output kills and reaps the
process group. Run diagnostics retain at most 4096 UTF-8 bytes of a message.

Accepted output must be one F2 envelope with exactly its request result. Options
and observations must match the selected context, path and request; metadata
must match the requested facet. Every observation has exactly one typed subject
link, validated by F1; the supervisor accepts option subjects for emitted
options and definition subjects for emitted definitions. A complete projection
observes each emitted option and definition exactly once. Origins belong to
emitted definitions or declarations, and positions belong to those origins.
Producers cannot emit supervisor facts. [E2a](module-adapter.md) authenticates
caller-admitted source links.

A complete request requires a positive observed count and an `observed` option
witness for the selected facet. `isDefined` and `priority` also require their
respective metadata rows; declarations may be empty with an observed option. F1
independently requires each priority's same-option `isDefined = true` and
priority-request observation. A result-only envelope, unforced observation or
missing metadata cannot establish success. The complete graph passes F1
validation before publication. `maxNodes` bounds option, definition,
declaration, observation and reported counts. Child limits exclude JSON/F1
validation and publication; the supervisor has no aggregate memory ceiling.

Each validated projection is written to a temporary file, flushed and renamed to
a completed `.trap` file. An invalid transaction publishes no metadata.
Supervisor-owned run, phase, target, context, capability, request and diagnostic
rows are published separately at completion. This is a per-projection handoff,
not an atomic whole-run snapshot or a proof of crash recovery. Completed
transactions survive another request's error. Strict mode raises
`ExtractionFailed` after publishing status evidence, carrying the full validated
packet.

Missing bindings, denied paths, missing inputs and recognized evaluator refusals
are blocked; other producer errors fail. Targets and the evaluation phase expose
incomplete requests. Exception messages classify some Nix refusals, so changed
runtime wording requires checking the blocked/failed distinction. A malformed
manifest records failed discovery before any target is admitted. Missing
observations never imply absent options or completed metadata.

## Exact CI entry point and cases

`checks.nix` imports `checks/eval-isolation.nix`, exposing the Linux-only
`checks.x86_64-linux.codeql-nix-eval-isolation`. It runs
`checks/fixtures/eval-isolation/test_supervisor.py` through F3's explicit
nonempty domain runner. The runner reports each named test and its executed
count; `$out/evidence` is written only after the suite passes. No CodeQL engine
or database import runs in this check.

The fixture has two complementary oracle groups:

- Fake producers check bound arguments, literal target names and paths, statuses
  and completed-file handoff; serialized execution; error isolation with
  strict-mode evidence; crash/malformed/invalid/forged/foreign-request, context,
  option-path and origin refusal; time, address-space, output, root depth, node
  and diagnostic budgets; invalid manifests (including lone surrogates), custom
  formats and missing opaque bindings; unrequested metadata; legal multi-field
  output above 1 MiB versus aggregate/individual overflow; actual metadata
  record counts at and over the node budget despite a smaller reported count;
  refusal of result-only, unobserved or missing-metadata success; all three
  metadata facets and priority's independent witness.
- Real Nix checks compare `isDefined` metadata to an independently invoked
  direct Nix Boolean expression with an unselected throwing leaf; import an
  admitted sibling and bound arguments; read a second declared root through its
  pinned `fetchTree`; distinguish a selected throw from a missing input; hide a
  host environment input; deny an undeclared path and an expression outside the
  roots; refuse a hash-pinned loopback fetch before the HTTP server receives a
  request; and reject IFD without a builder marker or lockfile appearing.

These tests establish the exercised runtime controls and projection handoff.
They do not establish general adapter correctness, scalar/path serialization,
string contexts, authenticated source provenance, a production extractor or
queryable combined database. Those need their own slice checks.

## Changing the boundary

Keep F1/F2 authority and the owner-local check import. Add independent failure
and positive controls to the explicit fixture when changing binding admission,
subprocess handling, budgets, publication or evaluator flags. Preserve
successful unrelated requests and health evidence on failures. Format changed
files, run the affected owner checks, and update this note and the existing
registry source list when the abstraction changes. Regenerate instruction
projections through `generate:all`; never edit generated consumers directly.

## Deferred consumers

Increment 4 restores value/member/scalar/string-context validation and fixtures,
including selected-root value success, opaque/empty/null witnesses,
reachability, cycles, shared DAG processing and longest-path depth checks. Their
text and aggregate-output checks remain here on metadata rows. Increment 3
restores nested contexts; the retained transport accepts roots only. E2a
supplies the module adapter and admitted syntax-to-origin links without adding a
value serializer.
