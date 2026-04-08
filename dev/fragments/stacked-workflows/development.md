## Stacked Workflows Development

### Package Structure

Stacked workflow content lives in `packages/stacked-workflows/` as a
published content package. The home-manager module is in
`modules/stacked-workflows/`.

- `packages/stacked-workflows/skills/<name>/SKILL.md` — consumer-facing skill definitions
- `packages/stacked-workflows/references/*.md` — tool reference docs shared by all skills
- `dev/fragments/stacked-workflows/` — dev-only routing table and development guide
- `modules/stacked-workflows/` — HM module with git config presets
  and AI tool integrations
- `packages/git-tools/` — overlay for git-absorb, git-branchless,
  git-revise

### Git Config Presets

Two preset levels are exported via `lib.gitConfig` (essential aliases)
and `lib.gitConfigFull` (extended configuration). The HM module wires
these into `programs.git.extraConfig`.

### AI Tool Integrations

The `stacked-workflows.integrations` option generates skill routing
instructions for each AI CLI ecosystem (Claude, Copilot, Kiro). When
`integrations.<ecosystem>.enable = true`, the module writes the
routing table fragment into the appropriate config path.

### Building and Testing

```bash
nix build .#git-absorb          # Build git-absorb overlay
nix build .#git-branchless      # Build git-branchless overlay
nix build .#git-revise          # Build git-revise overlay
nix flake check                 # Run module eval checks
```
