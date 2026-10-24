# Nix CodeQL owner and test entry points

> **Last verified:** 2026-10-23 — M3n retains 28 metadata relations and explicit
> owner check imports; document and check inventories live in the owner registry
> and checks entry point. S1 adds combined-schema generation and standalone raw
> location tests; E1 adds the isolated metadata projection check; S2 registers
> source and anchor acceptance; Q0 adds the installed query check; M3 adds
> generated builtin model acceptance; R0 replaces disposable bootstrap evidence
> with production lookup, coordinate and preflight checks.

## Purpose and fit

`packages/codeql-nix/` owns the Nix language contracts, fixtures and pack
manifests. Its `registry.nix` is the source of scoped architecture documents,
including this note. It contributes through the existing owner registry; no root
owner allowlist or separate discovery mechanism is needed.

`checks.nix` is the source of explicit check imports. Supporting files are not
recursively discovered as checks. Each imported check declares its selected
fixtures, dependencies and platform guards. Add a deliberate owner-local import
when adding a domain, without changing the root flake or copying the inventory
into this document.

## Checks and nonempty evidence

The installed check proves production lookup and raw coordinates alongside the
installed lifecycle; the anchor check exercises shared production text
preflight. The ABI check validates the handwritten schema and independent typed
golden TRAP. The contracts check runs explicitly selected Python suites,
including the manifest/observation boundary, runner behavior and ABI/health
sentinels. The ABI and contracts fixtures alone do not establish production
extraction. Read their imports and commands through `checks.nix` for the current
check and suite inventory.

A check must fail when a selected suite fails and publish its evidence only
after every selected suite passes. Register transport tests in an owner check so
verification does not depend on a manual invocation.

`checks/run-domain-tests.py` accepts one or more explicit unittest file paths.
Each file runs in a separate Python process, with its parent directory available
for companion imports. The runner reports total and executed test counts per
file. Missing files, import errors, failed tests, empty suites, entirely skipped
suites and early `SystemExit` fail the aggregate. It never searches sibling
directories for tests; a passing suite cannot hide an empty later suite.

The ABI sentinel validates the golden graph and compares its relation inventory
with an independently spelled set of all 28 retained relations. The health
sentinel requires runs, targets, syntax results and request results, completed
discovery, successful target/syntax statuses and positive request work counts.
These witnesses prevent empty or failed fixture output from looking like clean
analysis. They validate the fixture contract, not live extraction health or
future evaluator completeness.

`codeql-nix-eval-isolation` adds the Linux-only E1 supervisor fixture through
the same domain runner. Its fake producers and real minimal Nix projections
check serialized metadata requests, budgets, refusal paths and validated TRAP
handoff. See [evaluation-isolation.md](evaluation-isolation.md) for admission
rules, runtime limits and the exact cases. This check supplies no module adapter
or CodeQL database import.

`codeql-nix-builtin-models` adds the Linux-only
[builtin model acceptance](builtin-models.md) through the same explicit imports
and nonempty Python runner. Its suite also invokes its named QL fixtures against
the installed extractor and checks a separate real Nix oracle. Model facts
remain separate from syntax generation and evaluation tables.

## Pack boundaries

Each pack has its own `qlpack.yml` at the reserved interface:

- `ql/lib/`: `nix-agentic-tools/nix-all`, a library selecting `nix.dbscheme` and
  extractor `nix`.
- `ql/queries/`: `nix-agentic-tools/nix-queries`, depending on `nix-all`.
- `ql/test/`: `nix-agentic-tools/nix-tests`, depending on `nix-all` and
  selecting extractor `nix`.

All versions are `0.0.0`; these manifests establish identities. The
[installed extractor](installed-extractor.md) assembles the installed products.
`ql/lib/nix.dbscheme` is a symlink to `../../generated/nix.dbscheme`, S1's
combined generated/handwritten schema. S1's private raw QL and location adapter
supply the library's syntax interface; `codeql-nix-raw-inventory` checks
deterministic generation, inventory drift and standalone generated-node
file/location traversal. S2 adds the syntax driver and private
[authenticated anchor bridge](source-identity.md), tested by
`codeql-nix-anchors` through F3 driver contracts, raw preflight and QL/archive
assertions. The installed extractor, public metadata API and
[Step 0 queries](step0-query.md) now have separate owner checks; Q0 acceptance
requires its installed lifecycle check to pass. R0 removes the disposable
bootstrap packs and check; [integration-gate.md](integration-gate.md) records
their production replacement.

## Adding a domain

Reserve a distinct `ql/test/<domain>/` for each domain's source, `.ql` and
reviewed `.expected` fixtures, and a distinct `checks/fixtures/<domain>/` when
Python or other contract fixtures are needed. Keep those paths disjoint from the
existing `abi`, `contracts`, `eval-isolation`, `installed` and `protocol`
fixtures. A directory reservation does not implement a later capability or make
it a passing test.

Add an owner-local `checks/<domain>.nix` and explicitly import it from
`checks.nix`. For Python contracts, invoke `checks/run-domain-tests.py` with the
exact selected files and declare their dependencies in that check. For QL
fixtures, a domain check must explicitly run the appropriate tests against its
required producer/library; the Python runner does not run CodeQL tests. Preserve
the nonempty guards and independent expectations rather than learning expected
output from the implementation.

Keep shared pack manifests and the ABI coordinated instead of letting domains
rewrite them independently. Change F1 first when relation semantics change;
update F2's independent transport fixtures when that boundary changes. Keep
production extraction acceptance in its installed and Step 0 checks. Format
changed files with `treefmt`, run the affected checks through CI and update this
note when ownership or entry-point obligations change.
