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
packages/     Overlays: git-tools, mcp-servers, ai-clis
modules/      Home-manager modules
lib/          Shared library: fragments, MCP helpers, credentials, devshell
devshell/     Standalone devshell modules (mkAgenticShell)
skills/       Consumer-facing stacked workflow skills
references/   Canonical tool reference docs
fragments/    Instruction generation sources (common/ + packages/)
apps/         Nix apps: generate, update, check-drift, check-health
checks/       Flake checks
```
