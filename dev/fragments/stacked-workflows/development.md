## Stacked Workflows Development

> **Last verified:** 2026-08-02 (commit pending — Codex now receives the shared
> stacked-workflow skills and routing instruction through the same explicit HM
> and devenv pool contributions as the other enabled AI CLIs).

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a published
content package with per-backend modules:

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill
  definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by
  all skills (bundled as REAL files inside each skill dir at build time; see
  `overlay.nix`)
- `packages/stacked-workflows/router.nix` — the skill-routing instruction,
  shared by both backend modules
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
skill-routing instruction into the cross-ecosystem `ai.skills` /
`ai.instructions` pools, so each enabled AI CLI (Claude, Codex, Copilot, Kiro)
installs them at its native path. Both backend modules delegate to the shared
`lib/ai/mkSkillPackageModule` factory; the `ai.skills` pool is
per-`evalModules`, so the HM (user-global) and devenv (project-local)
contributions are independent.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```
