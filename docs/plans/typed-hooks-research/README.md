# Typed-hooks research artifacts

Backing material for `docs/plans/typed-hooks-across-clis-assessment.md` (the assessment is
the curated, verified deliverable — **read that first**). These are the raw inputs and a
working prototype, kept so a future session doesn't have to re-discover (or re-spend tokens
regenerating) them. Produced 2026-07-20 by a 7-lens research Workflow (`w0y9rf1sc`) + a
dedicated drift-detection agent, with 56 load-bearing claims adversarially verified.

> **Provenance/status:** `research-raw/` is **unedited AI-agent output** — it contains known
> errors that the assessment doc corrects (e.g. a lens grepped Kiro's telemetry enum and
> mis-reported the trigger set; see the assessment §5.1 + §15). Trust the assessment over
> these; they are retained for detail and traceability, not as ground truth.

## Manifest

| Path                                                 | What it is                                                                                                                                                                                                                                   | Graduates into                                                                         |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `primary-source-hardening.md`                        | **Citation store (2026-07-20b):** full Claude I/O contract pinned to a hashed raw-docs snapshot (stdin/output/exit/decision/timeout/matcher, each line-anchored) + GH issue statuses. Backs the assessment §4/§6/§11/§18 `[U]→[C]` upgrades. | assessment §4/§18 + `packages/claude-code/hook-events.json` provenance                 |
| `tier1b-prototype/`                                  | **Working Tier-1b harness (2026-07-20b):** documented-stdin → generated-hook → assert stdout/exit; 5 example hooks + 11 fixtures; standalone `.sh` + sandboxed `contract-test.nix` (`nix-build` green). NOT wired into `checks/`.            | `checks/hook-contract-tests.nix` (after Phase-1 real scripts + Tier-2 captures)        |
| `drift-extract.prototype.sh`                         | Working prototype: greps both pinned binaries for the hook event/trigger surface, emits the sidecars below, prints an advisory drift report. Validates assessment §10 end-to-end.                                                            | `checks/hook-surface-staleness.nix` (advisory) + `overlays/*.nix` `extraExtract` regen |
| `hooks-surface-draft/claude-code.hooks-surface.json` | Draft SSOT + provenance sidecar for Claude (30-event binary vocabulary, curated typed-9, provenance stamp).                                                                                                                                  | `packages/claude-code/hook-events.json` / `hooks-surface.json`                         |
| `hooks-surface-draft/kiro-cli.hooks-surface.json`    | Draft Kiro sidecar — records the **three-way trigger conflict** (Jun-5 docs=5, Jun-17 docs=11, 2.13.0 binary=~6) + provenance.                                                                                                               | `packages/kiro-cli/hook-triggers.json` / `hooks-surface.json`                          |
| `research-raw/verdicts.json`                         | 56 adversarial verification verdicts (36 CONFIRMED / 16 REFUTED / 4 UNCERTAIN) with corrections. The corrections are folded into the assessment §15.                                                                                         | test/fixture provenance                                                                |
| `research-raw/claims-questions-decisions.txt`        | Compact index of every lens's key-claims + open-questions + decisions.                                                                                                                                                                       | —                                                                                      |
| `research-raw/lens-0N-*.md`                          | The 7 raw research sections (inventory, composition, edge-cases, kiro-inventory, nix-architecture, testing, why/future). `lens-05-nix-architecture.md` has the fullest typed-option Nix sketches.                                            | assessment §4–§11                                                                      |

## Regenerating the drift data

```bash
bash docs/plans/typed-hooks-research/drift-extract.prototype.sh
```

Rebuilds `claude-code`/`kiro-cli`, re-greps, and re-emits the draft sidecars to the session
scratchpad. Hermetic (store-path greps, no network/auth). See assessment §10 for the
advisory-vs-blocking split and the docs-diff half (which is impure → flake app / cron, not a
`nix flake check`).
