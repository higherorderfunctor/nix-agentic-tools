# Extracted facts: the architecture

> **Last verified:** 2026-10-18 — Go owners run in-package extractor tests
> through the shared `goTestExtract`; shared reconciliation accepts single-key
> pattern rows. Every owner keeps one carried file; probes are not on the
> contract yet.

The contract (`facts-contract.md`, same category) is the spec: file shapes,
functions, failure kinds. This file is the why and the rules that keep the
machinery from growing back. Read it before adding anything under
`lib/extracted/`, `packages/<owner>/extract*/` or a harness's `lib/`.

## The pipeline

Five stages. Two of them take human input, and they are different inputs.

| Stage     | Lives in                                          | Written by                | Holds                                                                       |
| --------- | ------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------- |
| extract   | `packages/<owner>/extract/`, `passthru.extracted` | the extractor, in a build | one raw per system, carried into the forked `extracted/extracted.json`      |
| declare   | `packages/<owner>/extracted/facts.json`           | the extractor's author    | one row per key: type, source, which systems must carry it                  |
| decide    | `packages/<owner>/extracted/decisions.json`       | a human, dated            | ONLY how a key combines when systems disagree; absent when nothing diverges |
| aggregate | `lib.extracted.load` → `checks.extracted-index`   | evaluation                | the combined value per key; `index.json` for readers outside Nix            |
| annotate  | `packages/<owner>/extract/annotations.json`       | a human                   | what the extractor cannot measure: prose, dead-key reasons, refinements     |

`decisions.json` is not the hand-tuned layer. It answers one question, "these
two platforms disagree, which answer wins", and the drift check prints the exact
row to paste when that happens. The hand-tuned layer is `annotations.json`,
reconciled against the measurement by the owner's `rules.nix` so a stale hand
row fails the build. Owners without hand prose (Claude, Codex, glab, semble)
have no annotations file; owners measured on one platform (every owner except
Kiro and Codex) have no decisions file.

Reconciliation hand fields are non-blank prose. Owners may pass `patterns` for
repeated paths: `*` matches one key made of letters, digits, `_` or `-`. A
pattern matching no fact is stale; a fact claimed by multiple rows fails,
including overlaps between patterns and literal rows. The classifier stays in
`lib/redact/classify.nix`.

Go owners measure unexported structs and tables with a `_test.go` file copied
into the pinned source's package. `goTestExtract` runs it offline beside
`lib/extracted/go/nat_shared_test.go`, which holds the node type vocabulary, the
field walk and the output every Go owner shares; codec-specific typing stays in
the owner's test. CLIProxyAPI's `config` fact holds its v8 path-to-node mapping
as an opaque object because paths contain dots. Its reconciliation reader
consumes `config` for credential reasons. The owner fragment
`packages/cliproxyapi/docs/cliproxyapi-extraction.md` describes that extraction.

Consumers read the aggregate with `get` and `children`, at the place the value
is used. Nothing else reads a raw: the guard (`checks.extracted-contract-guard`)
fails any owner file that names `extracted/extracted.json` or `__platforms`,
reaches into `bySystem` or defines a combine.

## One file, carried per host

Each per-system extraction runs on a declared host, its derivation's `system`. A
static read of another platform's artifact runs on Linux and fills that
platform's side; only an extraction that must execute the binary runs on the
macOS runner, and it writes only Darwin's side. `regenerate` carries each host's
fresh raws into the one committed file. Only a carry from the base system,
`x86_64-linux`, makes the other systems follow every unforked node while keeping
their forks; any other host's carry leaves the rest exactly as committed, so a
difference new in its release becomes a fork that the next Linux carry keeps.
Following from both hosts would let each regenerate overwrite the other's side,
and no new difference could ever fork. Following from Linux is what keeps a
Linux bump evaluable: the per-system files it replaced let a Linux update
rewrite only Linux's raw, and every `equal` key a new release changed went
`divergent` against the stale Darwin raw. `get` throws on that at evaluation,
and `checks` forces every fact, so the Darwin regenerate that would have fixed
it could not evaluate (PR #2559, kiro 2.29.1 → 2.31.1, 2026-10-15).

Darwin CI's `extracted-facts` job therefore runs only owners with a `host-run`
row for Darwin, today Codex (clap help is compiled per platform).

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
- **Measured once means no forks.** An owner whose extraction is the same on
  every host commits its Linux raw unforked, with `"systems": ["x86_64-linux"]`
  on every row; a Darwin host's own extraction is still compared with its
  projection. A fork whose sides are equal is a defect: `merge` never writes
  one.
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

## Settled — do not relitigate

- **Per-system raw files, retired 2026-10-15.** `<system>.json` per owner left
  each host free to rewrite only its own raw, which made every release bump a
  two-host race (PR #2559). Making `checks` lazy does not help: the rejected
  `lazyAttrsOf` probe still failed, because derived check names force every
  `ciPackages` entry. The fix is the single carried file.
- **Kiro's TUI is decoded, not materialized.** Its settings came from running
  the chat binary in a PTY until it wrote `tui.js`. The same payload is a zstd
  frame in the binary followed by its SHA-256 hex, which the chat binary accepts
  as `tui.js.sha256`; the static read matched the host-run facts byte for byte
  on 2.29.1 for both platforms (2026-10-15). Only the asset loader was not
  disassembled.
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
- `packages/kimchi/docs/kimchi-factory.md`: Kimchi's hand tables and reconcile.
