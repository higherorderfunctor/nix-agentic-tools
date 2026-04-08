## Project Overview

nix-agentic-tools is a Nix flake monorepo that will provide:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — Model Context Protocol servers packaged as
  Nix derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code,
  Copilot CLI, Kiro CLI, stacked workflows, and MCP services
- **DevShell modules** — per-project AI tool configuration without
  home-manager (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise

The monorepo is being assembled bottom-up across a sequence of PRs.
Skills work without Nix. Nix unlocks overlays, home-manager modules,
and devshell integration.

### Current Branch Layout

```
dev/
  fragments/    Dev-only instruction fragments (not exported)
  generate.nix  Fragment composition for instruction file generation
  tasks/        DevEnv task wrappers
devshell/       Standalone devshell modules (mkAgenticShell)
lib/            Shared library: fragments, MCP helpers, devshell helpers
packages/
  fragments-ai/ AI ecosystem transforms (fragment frontmatter)
```

Future top-level directories (introduced in later chunks):

- `modules/` — Home-manager modules
- `packages/coding-standards/` — content package: reusable standards
- `packages/stacked-workflows/` — content package: skills + routing
- `packages/ai-clis/` — AI CLI overlays
- `packages/git-tools/` — git tool overlays
- `packages/mcp-servers/` — MCP server overlays
- `packages/fragments-docs/` — docsite transforms and generators
