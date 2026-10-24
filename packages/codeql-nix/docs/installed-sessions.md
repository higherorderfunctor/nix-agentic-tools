# Installed acceptance sessions

> **Last verified:** 2026-10-23 — I9s reuses compatible finalized databases
> within each installed acceptance check.

`checks/installed_session.py` avoids repeated extraction for compatible
assertions. It serves tests, not production evaluation. Installed, Step0,
properties, renames and graph retain separate derivations and explicit session
directories; no mutable database crosses derivations.

Variant keys cover source bytes and filesystem shape, pinned inputs, descriptor
bytes, extractor options, product/schema/model identities and failure mode.
Installed and Step0 baseline/override families stay distinct. Negative
admissions bypass successful reuse; qltests retain their own databases.

`Session.database` holds a process lock while building private staging,
requiring the `ready` marker, validating and publishing by rename. Hits are
revalidated. The installed harness compares the sole run row against production
`RunIdentity` from the requested descriptor and pins, and requires nonempty
completed phases. Rejected staging is removed.

`ql/suites/` explicitly lists implemented query products. Packaging installs
suites beside queries; `values.qls` is intentionally empty until value queries
exist. The installed check compiles every installed suite without creating a
database.

Harness instrumentation measured 72→71 create commands across the five checks:
one compatible properties reuse. Each of the four main installed/Step0 variants
already creates once. The count retains 14 negative creates; two init/index
paths and five qltest invocations are separate. Instrumentation replaces the
engine, so it establishes no installed success, engine runtime or memory
improvement; real acceptance remains a CI obligation.

Change reuse through the shared helper and installed harness. Keep independent
fixture bytes/oracles, negative variants, qltests and per-check directories.
Register regressions through `checks/contracts.nix`; verify its nonempty runner
summaries. Format changes, then run `codeql-nix-contracts` and all five
installed owner checks through CI. Extend suite membership only for implemented
queries and update this note with boundary changes.
