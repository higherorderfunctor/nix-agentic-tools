## Project Overview

> **Last verified:** 2026-10-03 — this flake's own nixpkgs builds every package
> it ships, and the overlay and module defaults re-export those builds; owner
> registries contribute update, documentation, and architecture metadata;
> project-local configuration uses the devenv modules.

nix-agentic-tools is a Nix flake monorepo providing:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — 12+ Model Context Protocol servers packaged as Nix
  derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code, Copilot
  CLI, Kiro CLI, stacked workflows, and MCP services
- **Devenv modules** — per-project AI tool configuration without home-manager
- **Git tool overlays** — git-absorb, git-branchless, git-revise

Skills work without Nix. Nix unlocks overlays, home-manager modules, and devenv
modules.

This flake's own nixpkgs builds every package it ships. `overlays.default` and
the module package defaults hand consumers those same builds, so they hit the
cache whatever nixpkgs the consumer uses. Unfree packages are left out of
`packages` and need the consumer's own opt-in; CI and checks read the
unfree-enabled `ciPackages`. The overlay-pattern fragment has the details.

### Key Directories

```text
packages/<owner>/
  packages/ai/<namespace>/<name>/package.nix  Native binary recipes and roles
  lib/                  Public default.nix plus private factories/helpers
  modules/              Consumer Home Manager and devenv configuration
  registry.nix          Update, documentation, and architecture metadata
  checks.nix, checks/   Owner checks and fixtures
  sources.json          Owner-local release pins (when needed)
  extracted.json        Measured CLI schemas (when needed)
  docs/, patches/, src/ Documentation and build support files
  fragments/, skills/  Published content (when applicable)
lib/                    Shared composition, AI module engines, packaging helpers
lib/testing/            Shared test harnesses with discovered backend imports
checks/<concern>/       Native workspace checks and cross-owner integration
config/                 Workspace policy and shared option declarations/data
dev/                    Repo-only generation, tasks, scripts, skills, and guidance
flake.nix               Public assembly and repo outputs
devenv.nix              This repository's workspace shell
```

The owner layout merged in PR #1633 is the operator-accepted baseline as of
2026-09-12. Further regrouping or reducing directory nesting is future design
work, not an unfinished migration. Old restructure plans and private prototypes
are historical evidence, not instructions to resume.

See `docs/repository-layout.md` for the settled owner tree and the distinction
between package and workspace responsibilities.
