## Project Overview

nix-agentic-tools is a Nix flake monorepo providing:

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
  <pkg>/              Per-package facet barrel: modules/{homeManager,devenv},
                      lib, docs, and fragments for that package
  stacked-workflows/  Content package: skills, references, routing-table fragment
  coding-standards/   Content package: reusable coding standard fragments
overlays/     Binary package overlays (pkgs.ai.*, pkgs.gitTools.*, pkgs.devTools.*)
              plus per-package -sources.json / -extracted.json sidecars
lib/          Shared library: the ai factory (lib/ai/*), fragments, MCP helpers,
              credentials, devshell
devshell/     Standalone devshell modules (mkAgenticShell)
config/       update-targets.nix (config.update.targets) and shared configuration data
dev/
  fragments/    Dev-only instruction fragments (not exported)
  references/   Dev-only reference docs (not exported)
  skills/       Dev-only skills (index-repo-docs, repo-review)
  generate.nix  Fragment to per-ecosystem instruction generator
checks/       Flake checks
```
