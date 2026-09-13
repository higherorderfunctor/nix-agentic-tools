## Stacked Workflows Development

> **Last verified:** 2026-08-16 — this package-specific architecture guide is
> co-located under `packages/stacked-workflows/docs/` and routed from there.
>
> Full lineage:
> `git show 89dce4c4:packages/stacked-workflows/docs/development.md`.

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a published
content package with per-backend modules:

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill
  definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by
  all skills (bundled as REAL files inside each skill dir at build time; see
  `packages/stacked-workflows/packages/stacked-workflows-content/package.nix`)
- `packages/stacked-workflows/router.nix` — the keyed skill-routing rule, shared
  by both backend modules
- `packages/stacked-workflows/modules/homeManager/` — user-global module
  (skills + skill-routing rule + git-config presets)
- `packages/stacked-workflows/modules/devenv/` — project-local module (skills +
  skill-routing rule)
- `packages/stacked-workflows/docs/development.md` — this package-owned
  development guide
- `packages/git-absorb/`, `packages/git-branchless/`, `packages/git-revise/` —
  the three git tools, each now its own owner facet with its recipe at
  `packages/<name>/packages/ai/gitTools/<name>/package.nix`

### Git Config Presets

Two preset levels are exported via `lib.gitConfig` (essential aliases) and
`lib.gitConfigFull` (extended configuration). The HM module wires these into
`programs.git.settings` via the `gitPreset` option (`"minimal"` / `"full"` /
`"none"`). That option remains `stacked-workflows.gitPreset`, outside `ai.*`,
because it is machine-wide Home Manager configuration with no runtime-specific
or devenv lowering.

### Skills + Skill-Routing Rule

`ai.programs.stacked-workflows.enable = true` fans the (unprefixed) `stack-*`
skills into the PER-RUNTIME `ai.<runtime>.skills` pool of every supported
runtime present in the evaluation. The `stacked-workflows-router` rule also fans
into each runtime that exposes an `ai.<runtime>.rules` pool; Kimchi has no rules
capability and receives only the skills. Each enabled AI CLI installs its
contribution at its native path.
`ai.<runtime>.programs.stacked-workflows.enable = false` disables that runtime's
contribution only. Both backend modules delegate to the shared
`lib/ai/mkSkillPackageModule` factory; those pools are per-`evalModules`, so the
HM (user-global) and devenv (project-local) contributions are independent.

It writes the per-runtime pools rather than root `ai.skills` because a root pool
belongs to consumers as a portable default surface — the provenance guard in
`checks/module-provenance/module-eval.nix` enforces that. **The practical
consequence for a consumer: override or suppress a package skill at
`ai.<runtime>.skills.<name>` and, on rule-capable runtimes, the router at
`ai.<runtime>.rules.stacked-workflows-router`.** Package values use `mkDefault`,
so an explicit value or null wins at that runtime scope. A same-key root entry
is replaced by the package's per-runtime value rather than colliding.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```
