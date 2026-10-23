# Nix CodeQL owner and test entry points

> **Last verified:** 2026-10-23 — F3 registers the owner and explicit contract
> checks; S1 adds combined-schema generation and standalone raw location tests.

## Purpose and fit

`packages/codeql-nix/` owns the Nix language contracts, fixtures and pack
manifests. Its `registry.nix` contributes the `codeql-nix` scoped architecture
category through the existing owner registry, including this note and the
[database](database-contract.md), [integration](integration-gate.md) and
[target](target-contract.md) contracts. No root owner allowlist or separate
discovery mechanism is needed.

`checks.nix` explicitly imports `checks/abi.nix`, `checks/bootstrap.nix`,
`checks/contracts.nix` and `checks/raw-inventory.nix`. Supporting files are not
recursively discovered as checks. This keeps ownership local and lets a new
domain add a deliberate check import without changing the root flake.

## Checks and nonempty evidence

The existing F0 `codeql-nix-bootstrap` and F1 `codeql-nix-abi` checks remain
registered on `x86_64-linux`, where the engine is available. F0 exercises its
disposable syntax/target integration fixture. F1 runs its ABI behavioral tests,
verifies the schema projection, compiles the handwritten schema and
imports/checks typed golden TRAP. Neither check establishes production
extraction.

`codeql-nix-contracts` runs these explicit Python suites with `jsonschema`
available:

- `checks/fixtures/contracts/test_domain_entrypoint.py`: black-box checks of the
  generic runner's acceptance and refusal behavior.
- `checks/fixtures/contracts/test_sentinels.py`: nonempty ABI and health
  witnesses over F1's independent golden graph.
- `checks/fixtures/protocol/test_protocol.py`: F2's manifest and observation
  transport tests, including the F1 validation layer.

The contracts check has no engine dependency or engine-specific platform guard.
Its derivation fails if a selected suite fails and writes `$out/evidence` only
after all suites pass. Registering F2 here puts its standalone entry point in
the existing flake-check CI path; it is no longer dependent on someone
remembering a manual protocol run.

`checks/run-domain-tests.py` accepts one or more explicit unittest file paths.
Each file runs in a separate Python process, with its parent directory available
for companion imports. The runner reports total and executed test counts per
file. Missing files, import errors, failed tests, empty suites, entirely skipped
suites and early `SystemExit` fail the aggregate. It never searches sibling
directories for tests; a passing suite cannot hide an empty later suite.

The ABI sentinel validates the golden graph and compares its relation inventory
with an independently spelled set of all 35 F1 relations. The health sentinel
requires runs, targets, syntax results and request results, completed discovery,
successful target/syntax statuses and positive request work counts. These
witnesses prevent empty or failed fixture output from looking like clean
analysis. They validate the fixture contract, not live extraction health or
future evaluator completeness.

## Pack boundaries

Each pack has its own `qlpack.yml` at the reserved interface:

- `ql/lib/`: `nix-agentic-tools/nix-all`, a library selecting `nix.dbscheme` and
  extractor `nix`.
- `ql/queries/`: `nix-agentic-tools/nix-queries`, depending on `nix-all`.
- `ql/test/`: `nix-agentic-tools/nix-tests`, depending on `nix-all` and
  selecting extractor `nix`.

All versions are `0.0.0`; these manifests establish identities, not an installed
product. `ql/lib/nix.dbscheme` is a symlink to `../../generated/nix.dbscheme`,
S1's combined generated/handwritten schema. S1's private raw QL and location
adapter supply the library's syntax interface; `codeql-nix-raw-inventory` checks
deterministic generation, inventory drift and standalone generated-node
file/location traversal. There is no production extractor, public meaning API or
query suite supplied by these manifests. The bootstrap's separate fixture packs
remain disposable evidence.

## Adding a domain

Reserve a distinct `ql/test/<domain>/` for each domain's source, `.ql` and
reviewed `.expected` fixtures, and a distinct `checks/fixtures/<domain>/` when
Python or other contract fixtures are needed. Keep those paths disjoint from the
existing `abi`, `bootstrap`, `contracts` and `protocol` fixtures. A directory
reservation does not implement a later capability or make it a passing test.

Add an owner-local `checks/<domain>.nix` and explicitly import it from
`checks.nix`. For Python contracts, invoke `checks/run-domain-tests.py` with the
exact selected files and declare their dependencies in that check. For QL
fixtures, a domain check must explicitly run the appropriate tests against its
required producer/library; the Python runner does not run CodeQL tests. Preserve
the nonempty guards and independent expectations rather than learning expected
output from the implementation.

Keep shared pack manifests and the ABI coordinated instead of letting domains
rewrite them independently. Change F1 first when relation semantics change;
update F2's independent transport fixtures when that boundary changes.
Production extractor installation needs its own checks before this note can
claim that capability. Format changed files with `treefmt`, run the affected
checks through CI and update this note when ownership or entry-point obligations
change.
