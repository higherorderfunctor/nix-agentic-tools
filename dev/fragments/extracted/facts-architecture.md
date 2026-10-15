# Extracted facts: the architecture

> **Last verified:** 2026-10-15 — every extractor owner is on the contract,
> CLIProxyAPI included (#2513); a hand field may be a list; a row may be a `*`
> pattern; Darwin CI selects host-run owners from declarations through the
> shared Nix owner map. Probes are not on the contract yet.

The contract (`facts-contract.md`, same category) is the spec: file shapes,
functions, failure kinds. This file is the why and the rules that keep the
machinery from growing back. Read it before adding anything under
`lib/extracted/`, `packages/<owner>/extract*/` or a harness's `lib/`.

## The pipeline

Five stages. Two of them take human input, and they are different inputs.

| Stage     | Lives in                                          | Written by                | Holds                                                                       |
| --------- | ------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------- |
| extract   | `packages/<owner>/extract/`, `passthru.extracted` | the extractor, in a build | one raw value tree per system, `extracted/<system>.json`                    |
| declare   | `packages/<owner>/extracted/facts.json`           | the extractor's author    | one row per key: type, source, which systems must carry it                  |
| decide    | `packages/<owner>/extracted/decisions.json`       | a human, dated            | ONLY how a key combines when systems disagree; absent when nothing diverges |
| aggregate | `lib.extracted.load` → `checks.extracted-index`   | evaluation                | the combined value per key; `index.json` for readers outside Nix            |
| annotate  | `packages/<owner>/extract/annotations.json`       | a human                   | what the extractor cannot measure: prose, dead-key reasons, refinements     |

`decisions.json` is not the hand-tuned layer. It answers one question, "these
two platforms disagree, which answer wins", and the drift check prints the exact
row to paste when that happens. The hand-tuned layer is `annotations.json`,
reconciled against the measurement by the owner's `rules.nix` so a stale hand
row fails the build. A hand field is prose or a non-empty list of prose (an
enum's values, as in CLIProxyAPI's rows). An owner may pass `reconcile` some
rows as `patterns`: a `*` in the name stands for one key of letters, digits, `_`
and `-`, so one row covers a field every key family repeats (CLIProxyAPI's
`api-keys.*[].proxy-url`). A pattern that matches nothing is stale, and a name
two rows claim is a bad row. Owners without hand prose (Claude, Codex, glab,
semble) have no annotations file; owners measured on one platform (every owner
except Kiro and Codex) have no decisions file.

Consumers read the aggregate with `get` and `children`, at the place the value
is used. Nothing else reads a raw: the guard (`checks.extracted-contract-guard`)
fails any owner file that opens `<system>.json`, reaches into `bySystem` or
defines a combine.

## The subtractive rule

The seven migration PRs added +3300/−900 lines of code before two subtraction
passes (#2433, #2434) took most of it back. Every surplus line had the same
shape: a thing added "for completeness" that no reader needed. The operator's
standing instruction is that this machinery stays at the simplest form that
serves a named consumer. Concretely:

- **A fact needs a reader in the same PR.** A declaration no `get` or `children`
  call consumes is not declared. Measured data with no reader stays in the raw,
  undeclared: `load` lists it under `undeclared` and the index omits it, so
  declaring it is what makes it visible, and a reader is what earns the
  declaration.
- **An owner's `expect` row carries a value or a `contains`.** The lib accepts a
  presence-only need (`{ key = "..."; }`), and the fixtures keep that working;
  owners do not write one, because `get` already throws on a missing key, so a
  presence row is the same check written twice.
- **Measured once means one raw.** An owner whose extraction is the same on
  every host commits `x86_64-linux.json` only, with
  `"systems": ["x86_64-linux"]` on every row; the darwin CI leg verifies against
  that one raw. A byte-identical second raw is a defect.
- **No decision without a printed divergence.** A `decisions.json` row exists
  because the drift check failed `divergent` and printed it. An empty
  `decisions.json` is deleted; `load` treats absent as `{}`.
- **No wrapper over the readers.** Owner libs call `load`, `get` and `children`
  directly. A helper that re-shapes the aggregate for one owner is the first
  step back to per-owner merge logic.
- **Fixtures are the library's regression suite, not a mirror of owners.** Every
  combine, source and failure kind in the contract's closed vocabulary keeps one
  positive and one refusal case, whether or not an owner selects it today
  (operator, 2026-10-11: a combine with no current user is still part of the
  library). A fixture is deleted only together with the behavior it pins. What
  is NOT kept is a fixture for an owner-shaped scenario, such as a presence row
  or a second platform for a measured-once owner.
- **Delete in the PR that removes the last caller.** `mkExtractRegen`,
  `mkRegenerateExtracted` and single-mode `mkDriftCheck` outlived their last
  caller by three PRs because deletion was "a later batch". It is not.
- **A hand-copied measured fact is a defect, not a backlog.** The 2026-10-10
  census counted 572 facts hand-copied into docs and tables, 281 with no feed.
  That number is a measurement of the problem, not a work list; the fix is a
  reader per fact only where a consumer actually depends on it.

## Probes: status and end goal

**Status.** `packages/delegate-routing/probes/delegates/<runtime>/` are run by
hand against a logged-in runtime. They write their own evidence files (including
`kimchi/extracted.json`, which is probe output, not an owner sidecar) and
nothing in Nix reads them. CI does not run them. The facts they establish
(delegation reach, nesting, hooks, worktrees, effort) are hand-copied into the
delegate-routing docs, which is the largest remaining source of the 572 above.

**End goal** (ASSESSMENT §6 of the private consolidation notes,
operator-approved as a direction; not yet scoped as work). Each probe meets one
of three fates:

1. A case that establishes a fact offline moves under the runtime's `extract/`
   and runs in CI as a `static` or `host-run` fact, with its darwin raw produced
   by the darwin leg when it is host-run.
2. A case that needs a login or the network stays operator-run and is declared
   `"source": "live", "systems": []`; its value is committed when the operator
   runs it and nothing in CI depends on it being fresh.
3. A probe with no declared consumer is deleted.

Consumers of probe facts (the delegate-routing skill, the capability map)
declare `expect` needs with values, so a runtime change under a skill surfaces
as a named failure. Until that lands, treat probe output as evidence to cite,
never as a fact source for Nix. The probe work owns the rewrite of this section.

## Where the rest lives

- `facts-contract.md`: the spec (same category, loads with this file).
- `dev/fragments/git-tool-settings/git-tool-settings.md`: annotations and the
  option generator for git-absorb, git-branchless, git-revise.
- `packages/cliproxyapi/docs/cliproxyapi-extraction.md`: CLIProxyAPI's Go
  extraction, its hand rows and the option reader.
- `packages/kimchi/docs/kimchi-factory.md`: Kimchi's hand tables and reconcile.
- `private/harness-facts-consolidation/HANDOFF.md`: the consolidation history,
  batch by batch, with what was dismissed and why.
