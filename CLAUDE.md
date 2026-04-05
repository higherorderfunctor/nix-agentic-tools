# CLAUDE.md

@AGENTS.md

## Project Overview

agentic-tools is a Nix flake monorepo providing stacked workflow skills,
MCP server packages, and home-manager modules for AI coding CLIs (Claude
Code, Copilot CLI, Kiro CLI). Skills work without Nix; Nix unlocks
overlays, home-manager modules, and devshell integration.

## Build & Validation Commands

```bash
nix flake show                # List all outputs
nix flake check               # Linters + evaluation (does NOT build packages)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter devShell with all tools
nix run .#generate            # Regenerate instruction files from fragments
treefmt                       # Format all files (Nix, markdown, JSON, TOML, shell)
```

## Architecture

```
packages/          Overlays: git-tools, mcp-servers, ai-clis
modules/           Home-manager modules: stacked-workflows, mcp-servers, copilot-cli, kiro-cli
lib/               Shared library: fragments, MCP helpers, credentials, devshell
devshell/          Standalone devshell modules (mkAgenticShell, no HM required)
skills/            Consumer-facing stacked workflow skills
references/        Canonical tool reference docs
fragments/         Instruction generation sources (common/ + packages/)
apps/              Nix apps: generate
checks/            Flake checks: formatting, linting, spelling, structural, module-eval
```

## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

This applies everywhere: standalone scripts, generated wrappers,
`writeShellApplication`, heredocs in Nix.

### Nix

All home-manager module options must use explicit NixOS module types.
Never use `types.anything` where a specific type is known. Overlay
functions access nvfetcher sources via `final.nv-sources.<key>` — never
import `generated.nix` directly. Computed hashes belong in
`hashes.json` sidecars.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to
lists, attribute sets, JSON objects, markdown tables, TOML sections, and
similar collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing
appears twice, extract it. Three similar lines is better than a premature
abstraction, but three similar blocks means it is time to extract.

## Commit Convention

[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`, `devshell`), or `flake` for root changes.

Lowercase, imperative mood, no trailing period.

## Change Propagation

When removing or renaming a concept, update ALL surfaces that reference
it in the same commit:

- Fragments and generated instruction files
- CLAUDE.md, AGENTS.md, Kiro steering, Copilot instructions
- Routing tables in skills
- README feature matrix and server reference
- flake.nix output lists
- nvfetcher.toml keys
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references.
The pre-commit hook runs a fast subset. If something is removed, grep
for it across the repo before committing.

## Naming Conventions

- Package overlays: `packages/<group>/<name>.nix`
- Server modules: `modules/mcp-servers/servers/<name>.nix`
- Skills: `skills/<name>/SKILL.md`
- Fragments: `fragments/{common,packages/<pkg>}/<name>.md`
- nvfetcher keys use upstream project names (may differ from exported package names)
- Exported packages: lowercase with hyphens

## Linting

All code must pass linters before committing:

- **Meta-formatter:** treefmt (orchestrates all formatters below)
- **Nix:** alejandra (format), deadnix (dead code), statix (anti-patterns)
- **Shell:** shellcheck, shellharden, shfmt
- **Markdown:** prettier (via treefmt)
- **JSON:** biome (via treefmt)
- **TOML:** taplo (via treefmt)
- **Spelling:** cspell
- **Agent configs:** agnix
