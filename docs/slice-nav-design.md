# Slice-nav design

> **Status:** design decisions locked. Ready for pre-pilot execution.
>
> **Inputs:**
>
> - `monorepo-restructure-assessment.md` §11 — slice layout direction
>   (~7 slices, dev-nav goal, module-merge-up mechanic).
> - `name-resolution-gap-analysis.md` — 14 sites of name-resolution
>   smell, clustered into 4 patterns. Surfaced 8 sites the assessment
>   didn't enumerate.
>
> **Scope of this doc:** captures the four decisions that block
> writing a full slice-nav plan, plus the concrete pre-pilot ticket.
> Does NOT enumerate slices 2–7, write per-slice migration steps,
> or commit to a timeline. Those come AFTER the pilot, because the
> pilot will surface things that change the plan.

## The four decisions

### 1. Merge-up namespace shape: concern-first

`config.<concern>.<slice>`, e.g.:

```nix
# slices/kiro/transformer.nix
{ ... }: {
  config.transformers.kiro = { … };
  config.update.targets.kiro-cli = { file = ./overlays/kiro-cli.nix; … };
}
```

Slice is a directory-layout convention; concerns are the runtime
contract. Shared code consumes by concern (`config.transformers`,
`config.update.targets`) — already symmetric with the
collision-refactor's `ai.<surface>.<cli>` shape.

Rejected: slice-first (`config.slices.<name>.<concern>`) — no
runtime use case for "iterate slices"; flat lib attrset
(no module system) — loses option-system benefits like collision
detection that the collision-refactor relies on.

### 2. Pilot scope: pre-pilot + kiro

Two-step validation:

**Pre-pilot:** migrate ONE update-target (`effect-mcp`) into
`config.update.targets`. ~2 days. Validates the merge-up namespace
shape with one concern, one package, no slice move yet. Tree
stays green via coexistence (decision 4).

**Pilot:** full kiro slice — kiro-cli, kiro-gateway, transformer,
and fragments. Validates module-merge across HM and devenv eval
boundaries with multiple concerns at once.

Pre-pilot package choice (`effect-mcp`): overlay-native (not a
nixpkgs-overrideAttrs override), no credentials, single package,
mature. Cleanest case to debug if the namespace shape needs
adjustment.

Rejected: kiro-only as pilot (assessment's recommendation) —
gap analysis shows kiro alone doesn't exercise update-target
merge-up at all because kiro packages use `--use-update-script`,
not the `git`-URL Phase 0 path.

### 3. Update-pipeline cleanup: empirical

Sites #12 (magic-comment parser) and #13 (regex sed for rev/hash)
are independent of slice-nav — slice-nav doesn't change file
contents. The script grew through accumulated workarounds for
nix-update edge cases; "go back to nix-update" might rediscover
the original bugs.

Migration mode:

- **Site #1 (file-discovery grep)** — fixed by the merge-up
  `config.update.targets.<name>` namespace. Each slice declares
  its file. Independent of Phase 0 cleanup.
- **Sites #12 / #13 (Phase 0 homebrew)** — opportunistic per
  slice. AS we migrate a package, try plain `nix-update` for it.
  If it works → drop magic comments + Phase 0 entry for that
  package. If it doesn't → debug, document why, keep homebrew
  for that package until the cause is understood.
- **Sidecars** — disfavored by default. Used only when a
  specific multi-output case (e.g. modelcontextprotocol's 7
  sub-package version literals from one source) genuinely
  cannot be expressed via native nix-update. Decided per
  package, not as a policy.
- **Findings captured** — each migration that surfaces a real
  reason for homebrew gets documented in
  `name-resolution-gap-analysis.md` as a notes section. Goal:
  turn the homebrew black-box into a documented set of discrete
  problems with known causes, even if some never get fixed.

No mass conversion before slice-nav. No mass conversion baked
INTO slice-nav. No upfront timeline.

### 4. Stay-green discipline: coexistence + atomic file moves

**Invariants (every commit):**

- Builds clean. `nix flake check` green.
- Published HM + devenv module surface byte-identical for
  consumers. nixos-config sees no change until/unless we
  explicitly want it to.
- No flag days. Old and new paths coexist during transition.

**Mechanism — split by migration kind:**

- **Data-registry migrations (sites #2, #5, #6, #7, #8, #11)** —
  coexistence pattern:
  1. Introduce the option shape. Code consuming the merged set
     falls back to the old path when a name isn't in the merged
     set. Both paths work — no functional change yet.
  2. Migrate contributors one at a time. Each migration is a
     small commit: "add slice X's declaration, remove its
     old-path entry."
  3. Delete fallback only when no consumer remains. Final
     cleanup commit per namespace.
- **Directory-layout changes (file moves)** — atomic per-slice.
  When `overlays/kiro-gateway.nix` moves to
  `slices/kiro/kiro-gateway/overlay.nix`, the old path either
  exists or doesn't — no useful "fallback." Each slice's
  file-move lands as one commit (or a tight series within the
  slice).

Cost: coexistence boilerplate for the duration. Bounded — exits
when last slice lands. Acceptable; collision-refactor proved
it works at this scale.

## Pre-pilot ticket

**Goal:** prove `config.update.targets.<name>` merge-up shape
with one package end-to-end. Tree green throughout. No slice
move yet.

**Scope (no code changes outside these):**

1. Introduce `config.update.targets` option in shared lib
   (probably `lib/ai/sharedOptions.nix` or a new
   `lib/update.nix` — to be decided during execution). Type:
   `attrsOf submodule { file, git, flags, dependsOn }`.
   Default: empty attrset.
2. Modify `dev/scripts/update-pkg.sh` to:
   - Read merged set via `nix eval --json
.#updateTargets.<name>` first.
   - Fall back to existing grep path when name absent.
   - No other changes (Phase 0 homebrew stays for now).
3. Add the single declaration in `overlays/mcp-servers/effect-mcp.nix`
   (or wherever the option-system contribution naturally lives
   — to be decided during execution; might be a sibling
   `update.nix` next to the overlay).
4. Verify pipeline runs locally: `effect-mcp` update should
   pull file path from merged set; all other packages still use
   grep path; both produce identical output to status quo.

**Out of scope:**

- Migrating any other package. Only effect-mcp.
- Touching homebrew Phase 0. That's empirical-per-slice.
- Slice-nav file moves. Effect-mcp stays in `overlays/`.
- Other merge-up namespaces (mcp.serverModules,
  fragments.scopes, etc.). One concern at a time.

**Done when:**

- All `nix flake check` passes.
- Local update-pipeline run produces identical output for
  effect-mcp before and after the change.
- Effect-mcp's update-target declaration is visible at
  `nix eval .#updateTargets.effect-mcp`.
- Branch builds green on CI for x86_64-linux + aarch64-darwin.
- User reviews and approves before any next slice work.

## After pre-pilot

If pre-pilot lands clean:

1. Pilot: kiro slice with transformer-merge + update-target
   merge for any kiro packages with `git` URLs (kiro-gateway is
   currently not git-URL — assess at pilot time).
2. Write the per-slice migration plan based on what the pre-pilot
   and pilot reveal.
3. Slices 2–7 in subsequent passes, each independently
   reviewable.

If pre-pilot reveals the namespace shape doesn't work:

- Stop. Reassess. Revise this doc. No commitment to slice-nav
  rollout until the foundation is settled.

## What this doc does NOT do

- Enumerate slices 2–7. Premature.
- Schedule or estimate timeline. Pilot output drives those.
- Lock the merge-up shape for concerns beyond `update.targets`
  (e.g., `mcp.serverModules`, `fragments.scopes`). Each concern's
  shape gets settled when first migrated, informed by what
  works for `update.targets`.
- Commit to native-nix-update migration for any specific
  package. That's per-slice empirical.

## References

- `monorepo-restructure-assessment.md` — slice layout direction (§11).
- `name-resolution-gap-analysis.md` — 14 smell sites + patterns + risks.
- `ai-factory-collision-refactor-plan.md` — proven precedent for
  coexistence-pattern stay-green migrations at this scale.
