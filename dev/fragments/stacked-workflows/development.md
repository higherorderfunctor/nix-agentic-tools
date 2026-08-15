## Stacked Workflows Development

> **Last verified:** 2026-08-15 (commit pending — the router is now the keyed
> `stacked-workflows-router` rule, contributed at `mkDefault` so an ordinary
> per-runtime consumer definition wins). Prior: 2026-08-14 (commit pending — the
> contributions land on the PER-RUNTIME pools now, not the root ones, so the
> consumer override key moved to `ai.<runtime>.skills.<name>` and a root write
> is a collision rather than an override). Prior: 2026-08-02 (commit pending —
> Codex now receives the shared stacked-workflow skills and routing instruction
> through the same explicit HM and devenv pool contributions as the other
> enabled AI CLIs).

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a published
content package with per-backend modules:

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill
  definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by
  all skills (bundled as REAL files inside each skill dir at build time; see
  `overlay.nix`)
- `packages/stacked-workflows/router.nix` — the keyed skill-routing rule, shared
  by both backend modules
- `packages/stacked-workflows/modules/homeManager/` — user-global module
  (skills + skill-routing rule + git-config presets)
- `packages/stacked-workflows/modules/devenv/` — project-local module (skills +
  skill-routing rule)
- `dev/fragments/stacked-workflows/` — dev-only development guide
- `packages/git-tools/` — overlay for git-absorb, git-branchless, git-revise

### Git Config Presets

Two preset levels are exported via `lib.gitConfig` (essential aliases) and
`lib.gitConfigFull` (extended configuration). The HM module wires these into
`programs.git.settings` via the `gitPreset` option (`"minimal"` / `"full"` /
`"none"`).

### Skills + Skill-Routing Rule

`stacked-workflows.enable = true` fans the (unprefixed) `stack-*` skills and the
`stacked-workflows-router` rule into the PER-RUNTIME `ai.<runtime>.skills` /
`ai.<runtime>.rules` pools of every runtime present in the evaluation, so each
enabled AI CLI installs them at its native path. Both backend modules delegate
to the shared `lib/ai/mkSkillPackageModule` factory; those pools are
per-`evalModules`, so the HM (user-global) and devenv (project-local)
contributions are independent.

It writes the per-runtime pools rather than root `ai.skills` because a root pool
is additive and cannot be retracted per runtime — the provenance guard in
`checks/module-eval.nix` enforces that. **The practical consequence for a
consumer: override a skill at `ai.<runtime>.skills.<name>` or the router at
`ai.<runtime>.rules.stacked-workflows-router`, not through the root pools.** A
same-key root entry is a hard cross-level collision because the merge compares
key presence and cannot see `mkDefault`.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```
