## Stacked Workflows Development

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a
published content package with per-backend modules:

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by all skills (bundled as REAL files inside each skill dir at build time; see `overlay.nix`)
- `packages/stacked-workflows/router.nix` — the routing-table instruction, shared by both backend modules
- `packages/stacked-workflows/modules/homeManager/` — user-global module (skills + routing table + git-config presets)
- `packages/stacked-workflows/modules/devenv/` — project-local module (skills + routing table)
- `dev/fragments/stacked-workflows/` — dev-only development guide
- `packages/git-tools/` — overlay for git-absorb, git-branchless,
  git-revise

### Git Config Presets

Two preset levels are exported via `lib.gitConfig` (essential aliases)
and `lib.gitConfigFull` (extended configuration). The HM module wires
these into `programs.git.settings` via the `gitPreset` option
(`"minimal"` / `"full"` / `"none"`).

### Skills + Routing Table

`stacked-workflows.enable = true` fans the (unprefixed) `stack-*`
skills and the routing-table instruction into the cross-ecosystem
`ai.skills` / `ai.instructions` pools, so each enabled AI CLI
(Claude, Copilot, Kiro) installs them at its native path. Both backend
modules delegate to the shared `lib/ai/mkSkillPackageModule` factory;
the `ai.skills` pool is per-`evalModules`, so the HM (user-global) and
devenv (project-local) contributions are independent.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```
