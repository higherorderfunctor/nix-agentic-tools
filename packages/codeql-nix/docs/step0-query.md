# Which files set an option?

> **Last verified:** 2026-10-23 — Q0 joins installed module metadata to
> authenticated syntax and checks it against independent Nix evaluation; R0
> retires the disposable bootstrap in favor of production integration proofs.

## Terms

- Association quality: the count of source matches for an origin.
- Candidate: an authenticated literal binding for a requested option path.
- Declaration: metadata identifying where an option was introduced.
- Health: recorded extraction phases, request outcomes and diagnostics.
- Observation: recorded evaluation evidence for one option or definition.
- Oracle: an expected answer computed independently of the extractor.
- Origin: an evaluator label, optionally linked to a file or reported point.
- Priority: the override number, preserved as signed decimal text; lower wins.
- Q0: the Step 0 query answering which files retain definitions for an option.
- QL: CodeQL's query language.
- Request: an explicit option path, metadata facet and work limits.
- Selected: retained for type merging, without proving sole cause of a value.
- Target: an explicitly named configuration.

## Answer and boundary

`ql/queries/WhoSetsOption.ql` returns row kind, target, exact option path as a
JSON array of segments, file, line, column, priority, selection and association
quality. Its shared implementation is `ql/lib/nix/WhoSetsOption.qll`; the
query-test wrapper imports that same implementation. This answers a file-level
module question using the existing [metadata library](metadata-library.md) and
[public syntax](minimal-ast.md), without evaluating or serializing option
values.

Selected rows require observed retained definitions. They carry `selected=true`
and the option's witnessed winning priority, or `unknown` when that priority was
not observed. An absent authenticated file is `unknown` and does not erase
observed selection; its association is `unmapped`. Equal-priority definitions
may all be selected. Missing evidence never establishes a losing definition.

Candidate rows enumerate admitted literal bindings matching the requested exact
path. Their selection and priority remain `unknown`, including candidates
associated with a retained file. Association describes the match between a
retained origin and source bindings; it cannot identify the expression that
produced a value. A candidate without such a match has unknown association. Zero
matches are `unmapped`, one is `unique` and several are `ambiguous`. Multiple
bindings in one file can therefore make an origin's association ambiguous.

Declaration rows expose admitted declaration files and available reported
points, retaining the row with an `unknown` file when source identity is absent.
File-level definitions need no invented byte range: absent line or column is
`unknown`. Paths retain segment boundaries, targets remain distinct and
priorities are not narrowed to QL integers. Synthetic evaluator labels cannot
supply authenticated source files.

`ql/queries/ExtractionHealth.ql` reports recorded phases, per-target request
outcomes with observed counts, and diagnostics capped at 4096 characters. Read
health alongside the answer: a failed request and an absent definition are
different results. Recorded health is evidence about explicit work, not a
promise that every possible option was explored.

## Installed proof

`checks.nix` imports `checks/step0.nix`, exposing the Linux check
`checks.x86_64-linux.codeql-nix-step0`. It runs
`checks/fixtures/step0/test_q0.py` through the existing nonempty domain runner
and writes its evidence only after the selected suite succeeds. Every installed
suite is a separate derivation from the same `installedSuite` helper, so CI
builds them in parallel instead of serially within one 60-minute leg; a new
suite adds one entry there rather than joining an existing derivation. The suite
reuses the [installed extractor](installed-extractor.md) harness: installed
products, `database create --language=nix`, both production queries and
`codeql test run ql/test/step0`.

The fixture declares integer option `demo.answer` in `options.nix`.
`ordinary.nix` uses a module function and `let`; `default.nix` supplies
`lib.mkDefault`. Handwritten expected rows check declarations, selected files
and candidate uncertainty. `checks/fixtures/step0/oracle.nix` independently
imports upstream `lib.evalModules` and reads declarations, retained files and
priority without the producer or encoder.

The ordinary case selects `ordinary.nix` at priority `100`. Replacing
`lib.mkDefault` with `lib.mkOverride 50` must select `default.nix` at `50` in
both query and oracle. Separate cases retain both equal-priority definitions,
tolerate an unselected throwing value and report a selected module failure.
Success requires specific rows and completed health with positive observation
counts. The failure case requires nonzero extraction, failed request evidence
and candidates whose selection and priority remain unknown. A separate installed
regression uses shared physical roots with distinct logical names: each target
retains its admitted identity, while a target admitting both aliases keeps
observed metadata with unknown files.

## Changing Q0

Change the shared QL implementation and independent expected rows together.
Preserve exact paths, observed selection, target separation, signed priority
text and explicit uncertainty. Extend the oracle independently when adding
module behavior; do not derive expected rows from query output. Keep installed
lifecycle tests in the owner check rather than relying on a manual query run.

Format changed files with `treefmt` and run `codeql-nix-step0` through CI.
Changes to source association or metadata evidence also require the
corresponding anchor or metadata checks. The metadata check also runs the
independent `UnknownOrigin` expectations for selected and declaration rows
without source files. Q0 consumes the existing installation, schema and source
bridge; it adds no second producer or evaluator. R0 retires the disposable
bootstrap; [integration-gate.md](integration-gate.md) records production lookup,
text and coordinate proofs.
