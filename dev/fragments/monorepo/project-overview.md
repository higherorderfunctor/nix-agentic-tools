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
  fragments/         Dev-only instruction fragments (not exported)
  generate.nix       Fragment composition for instruction file generation
  tasks/             DevEnv task wrappers
devshell/            Standalone devshell modules (mkAgenticShell)
lib/                 Shared library: fragments, MCP helpers, devshell helpers
packages/
  agnix/             Linter, LSP, and MCP server for AI config files
  <per-package dirs>/ Bazel-style dirs for every published AI app + MCP server
                     under pkgs.ai.* (claude-code/, copilot-cli/, kiro-cli/,
                     context7-mcp/, github-mcp/, etc.)
  coding-standards/  Content package: reusable coding standards
  fragments-ai/      AI ecosystem transforms (fragment frontmatter)
  fragments-docs/    Doc site transforms and generators
  stacked-workflows/ Content package: skills + references + routing fragment
```

Future top-level directories (introduced in later chunks):

- `modules/` — Home-manager modules
