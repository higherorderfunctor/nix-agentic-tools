## Project Overview

agentic-tools is a Nix flake monorepo providing:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — 12+ Model Context Protocol servers packaged as
  Nix derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code,
  Copilot CLI, Kiro CLI, stacked workflows, and MCP services
- **DevShell modules** — per-project AI tool configuration without
  home-manager (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise

Skills work without Nix. Nix unlocks overlays, home-manager modules, and
devshell integration.

### Key Directories

```
packages/
  stacked-workflows/  Content package: skills, references, routing-table fragment
  coding-standards/   Content package: reusable coding standard fragments
  ai-clis/            Overlay: AI CLI packages
  git-tools/          Overlay: git tools (agnix, git-absorb, etc.)
  mcp-servers/        Overlay: MCP server packages
modules/      Home-manager modules
lib/          Shared library: fragments, MCP helpers, credentials, devshell
devshell/     Standalone devshell modules (mkAgenticShell)
dev/
  fragments/    Dev-only instruction fragments (not exported)
  references/   Dev-only reference docs (not exported)
  skills/       Dev-only skills (index-repo-docs, repo-review)
apps/         Nix apps: generate, update, check-drift, check-health
checks/       Flake checks
```
