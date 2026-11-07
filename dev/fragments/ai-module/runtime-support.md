## ai.\* runtime support declarations

> **Last verified:** 2026-11-07 — the proposed `surfaceSupport` decision moved
> here from the repository architecture list.

- **PROPOSAL (not yet vetted): Runtime support is declared in
  `surfaceSupport`.** Any shared root surface or normalized settings field a
  runtime does not declare warns when a consumer sets it, on each backend the
  runtime does not declare. This keeps a new surface or field a single
  declaration with no per-runtime edits and warns about undeclared delivery. A
  per-runtime opt-out for Copilot is future work. See
  `lib/ai/app/decompose.nix`, `lib/ai/app/checkRecord.nix` and
  `lib/ai/app/supportReasons.nix`.
