# agentic-tools Migration Plan

> Living document. Updated as decisions are made and checkpoints complete.
> Branch: `sentinel/monorepo-plan`

## Vision

A single flake consolidating all agentic tooling:

- **Skills** — stacked workflow skills for Claude Code, Kiro, and Copilot
- **MCP servers** — 12+ packaged servers with typed settings, credentials,
  and systemd services
- **Home-manager modules** — declarative config for Claude Code (upstream),
  Copilot CLI, Kiro CLI, stacked workflows, and MCP servers
- **DevShell modules** — per-project AI config without home-manager
  (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise
- **Fragment pipeline** — single-source instruction generation for all
  ecosystems

Works without Nix for skills. Nix unlocks everything else.

---

## Principles

1. **Checkpoint-driven delivery** — each phase produces a working,
   committable artifact
2. **DRY** — one source of truth for each concept; unify during migration,
   not after
3. **Feature-forward documentation** — README leads with what, not how it's
   built
4. **Change propagation** — every removal/rename must update all surfaces in
   the same commit; structural checks enforce cross-references
5. **Sentinel until stable** — work on `sentinel/monorepo-plan` until
   scaffold is solid, then split into a stack

---

## Directory Structure

```
agentic-tools/
├── flake.nix                           # Root flake
├── flake.lock
├── README.md                           # Feature-forward, SEO-friendly
├── CLAUDE.md                           # Hand-authored root + @-imports
├── AGENTS.md                           # Generated (dev profile, all packages)
├── .gitignore
│
├── packages/                           # All package overlays
│   ├── default.nix                     # Compose all sub-overlays
│   ├── git-tools/                      # git-absorb, git-branchless, git-revise
│   │   ├── default.nix                 # Overlay: top-level pkgs.*
│   │   ├── git-absorb.nix
│   │   ├── git-branchless.nix
│   │   ├── git-revise.nix
│   │   └── sources.nix                # nvfetcher sources for git tools
│   ├── mcp-servers/                    # 12 MCP server packages
│   │   ├── default.nix                 # Overlay: pkgs.nix-mcp-servers.*
│   │   ├── context7-mcp.nix
│   │   ├── ...                         # One file per server
│   │   ├── sources.nix                 # nvfetcher + hashes.json merge
│   │   ├── hashes.json                 # npmDepsHash, vendorHash sidecar
│   │   └── locks/                      # npm lockfiles
│   └── ai-clis/                        # AI CLI packages (vendored elsewhere)
│       ├── default.nix                 # Overlay: pkgs.copilot-cli, pkgs.kiro-cli, etc.
│       ├── copilot-cli.nix
│       ├── kiro-cli.nix
│       ├── kiro-gateway.nix
│       └── sources.nix
│
├── modules/                            # All home-manager modules
│   ├── default.nix                     # Import all sub-modules
│   ├── stacked-workflows/              # stacked-workflows.* options
│   │   ├── default.nix
│   │   └── git-config.nix              # gitConfig / gitConfigFull presets
│   ├── mcp-servers/                    # services.mcp-servers.* options
│   │   ├── default.nix                 # Home-manager module
│   │   └── servers/                    # Per-server definitions
│   │       ├── context7-mcp.nix
│   │       ├── ...                     # meta, settingsOptions, settingsToEnv, settingsToArgs
│   │       └── github-mcp.nix
│   ├── copilot-cli/                    # programs.copilot-cli.* options
│   │   └── default.nix
│   └── kiro-cli/                       # programs.kiro-cli.* options
│       └── default.nix
│
├── lib/                                # Shared library
│   ├── default.nix                     # Compose all lib
│   ├── fragments.nix                   # Fragment pipeline (extended for monorepo)
│   ├── mcp.nix                         # mkStdioEntry, mkHttpEntry, mkStdioConfig, etc.
│   ├── credentials.nix                 # mkCredentialsOption, mkCredentialsSnippet, etc.
│   └── devshell.nix                    # mkAgenticShell (standalone evalModules)
│
├── devshell/                           # DevShell module definitions
│   ├── top-level.nix                   # Core options: packages, shell, files
│   ├── files.nix                       # File materialization (shellHook symlinks)
│   ├── mcp-servers/                    # Per-server devshell modules
│   │   ├── default.nix                 # mcpServers option type + .mcp.json gen
│   │   └── ...                         # Reuse modules/mcp-servers/servers/ defs
│   ├── skills/                         # Skill injection for devshells
│   │   └── stacked-workflows.nix
│   └── instructions/                   # Instruction generation for devshells
│       └── default.nix
│
├── skills/                             # Consumer-facing skills (the product)
│   ├── stack-fix/
│   │   ├── SKILL.md
│   │   └── references/                 # Symlinks to canonical refs
│   ├── stack-plan/
│   ├── stack-split/
│   ├── stack-submit/
│   ├── stack-summary/
│   └── stack-test/
│
├── references/                         # Canonical reference docs
│   ├── git-absorb.md
│   ├── git-branchless.md
│   ├── git-revise.md
│   ├── philosophy.md
│   └── recommended-config.md
│
├── fragments/                          # Instruction generation sources
│   ├── common/                         # Shared across all packages
│   │   ├── coding-standards.md
│   │   ├── commit-convention.md
│   │   └── ...
│   └── packages/                       # Per-package fragments
│       ├── stacked-workflows/
│       │   ├── routing-table.md
│       │   ├── build-commands.md
│       │   └── ...
│       ├── mcp-servers/
│       │   ├── server-config.md
│       │   └── ...
│       └── monorepo/                   # Root-level monorepo meta
│           └── project-overview.md
│
├── dev/                                # Dev-only (not distributed)
│   └── skills/
│       ├── index-repo-docs/
│       └── repo-review/
│
├── apps/                               # Nix apps
│   ├── default.nix
│   ├── generate/                       # Fragment → instruction generation
│   │   ├── default.nix
│   │   └── generate.sh
│   ├── update/                         # MCP server version updates
│   │   ├── default.nix
│   │   └── update.sh
│   ├── check-drift/                    # MCP tool drift detection
│   │   ├── default.nix
│   │   └── check-drift.sh
│   └── check-health/                   # MCP server health checks
│       ├── default.nix
│       └── check-health.sh
│
├── checks/                             # Flake checks (unified superset)
│   ├── default.nix
│   ├── agent-configs.nix               # agnix --strict
│   ├── formatting.nix                  # dprint check
│   ├── linting.nix                     # deadnix, statix
│   ├── shell.nix                       # shellcheck, shellharden, shfmt
│   ├── spelling.nix                    # cspell
│   ├── structural.nix                  # Cross-reference validation
│   └── module-eval.nix                 # HM module evaluation tests
│
├── scripts/
│   └── pre-commit                      # Unified pre-commit hook
│
├── docs/
│   ├── plan.md                         # This file
│   └── decisions/                      # ADRs (MADR-style)
│
├── .claude/                            # Claude Code ecosystem config
│   ├── settings.json
│   ├── rules/                          # Generated per-package rules
│   │   ├── common.md                   # No paths: (always loaded)
│   │   └── mcp-servers.md              # paths: ["packages/mcp-servers/**"]
│   ├── skills/                         # sws-* prefixed (dev variants)
│   │   ├── sws-stack-fix -> ../../skills/stack-fix
│   │   └── ...
│   └── references/                     # Generated from fragments
│       └── stacked-workflow.md
│
├── .kiro/                              # Kiro ecosystem config
│   ├── steering/                       # Generated per-package steering
│   │   ├── common.md                   # inclusion: always
│   │   └── mcp-servers.md              # inclusion: fileMatch
│   └── skills/                         # Per-skill symlinks
│
├── .github/                            # GitHub / Copilot ecosystem
│   ├── copilot-instructions.md         # Generated (common fragments)
│   ├── instructions/                   # Generated per-package
│   │   └── mcp-servers.instructions.md # applyTo: "packages/mcp-servers/**"
│   └── workflows/
│       ├── ci.yml
│       ├── update.yml
│       └── generate-routing.yml
│
└── nvfetcher.toml                      # Unified version tracking
```

### Sub-Package Instruction Strategy

Each ecosystem has native path-scoping. The fragment pipeline generates all
outputs — one source, four targets:

| Ecosystem   | Root (always loaded)                             | Per-package scoping mechanism                                          |
| ----------- | ------------------------------------------------ | ---------------------------------------------------------------------- |
| Claude Code | `CLAUDE.md` (hand-authored, `@`-imports)         | `.claude/rules/<pkg>.md` with `paths:` frontmatter                     |
| Kiro        | `.kiro/steering/common.md` (`inclusion: always`) | `.kiro/steering/<pkg>.md` (`inclusion: fileMatch`, `fileMatchPattern`) |
| Copilot     | `.github/copilot-instructions.md` (repo-wide)    | `.github/instructions/<pkg>.instructions.md` (`applyTo:` glob)         |
| AGENTS.md   | Root `AGENTS.md` (generated, all packages)       | `packages/<pkg>/AGENTS.md` (nearest-wins)                              |

**Fragment pipeline extension:**

```
fragments/common/*.md       →  root-level outputs (all ecosystems)
fragments/packages/<pkg>/*  →  per-package outputs with path scoping
```

Each package declares a profile: `common/*` fragments + its own
`packages/<pkg>/*` fragments. The pipeline concatenates and wraps with
ecosystem-appropriate frontmatter.

**Claude Code specifics:**

- Root `CLAUDE.md` is hand-authored with `@AGENTS.md` import and shared
  coding standards
- `.claude/rules/` files are generated with `paths:` frontmatter for
  per-package scoping — loaded only when working in those paths
- Subdirectory `CLAUDE.md` files (e.g., `packages/mcp-servers/CLAUDE.md`)
  are lazy-loaded when Claude reads files there
- Target < 200 lines per file to avoid context bloat

### nvfetcher Strategy

Single `nvfetcher.toml` at root. Prefixed keys avoid collisions:

```toml
# Git tools
[git-absorb]
src.github = "tummychow/git-absorb"

# MCP servers
[context7-mcp]
src.cmd = "..."

# AI CLIs
[copilot-cli]
src.github = "github/copilot-cli"
```

Generated output goes to a shared `.nvfetcher/` directory. Each
`packages/*/sources.nix` imports from this shared output and merges its
own sidecar hashes where needed.

---

## Flake Interface

### Outputs

```nix
{
  # Overlays
  overlays.default          # All overlays composed (git-tools + mcp-servers + ai-clis)
  overlays.git-tools        # Just git-absorb, git-branchless, git-revise
  overlays.mcp-servers      # Just pkgs.nix-mcp-servers.*
  overlays.ai-clis          # Just copilot-cli, kiro-cli, kiro-gateway

  # Home-manager modules
  homeManagerModules.default           # All modules
  homeManagerModules.stacked-workflows # Just SWS
  homeManagerModules.mcp-servers       # Just MCP
  homeManagerModules.copilot-cli       # Just Copilot CLI
  homeManagerModules.kiro-cli          # Just Kiro CLI

  # Library
  lib.mkStdioEntry          # Preserved (MCP)
  lib.mkHttpEntry           # Preserved (MCP)
  lib.mkStdioConfig         # Preserved (MCP)
  lib.mkMcpConfig           # Preserved (MCP)
  lib.mapTools              # Preserved (MCP)
  lib.externalServers       # Preserved (MCP)
  lib.fragments             # Preserved (SWS)
  lib.gitConfig             # Preserved (SWS)
  lib.gitConfigFull         # Preserved (SWS)
  lib.mkAgenticShell        # New: devshell modules

  # Packages (flat)
  packages.${system}.*      # All packages: git tools + MCP servers + AI CLIs

  # Dev
  devShells.${system}.default
  checks.${system}.*
  apps.${system}.*          # generate, update, check-drift, check-health
  formatter.${system}       # alejandra
}
```

### Inputs

```nix
{
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  nvfetcher = { url = "github:berberman/nvfetcher"; inputs.nixpkgs.follows = "nixpkgs"; };
  rust-overlay = { url = "github:oxalica/rust-overlay"; inputs.nixpkgs.follows = "nixpkgs"; };
  mcp-nixos = { url = "github:utensils/mcp-nixos"; inputs.nixpkgs.follows = "nixpkgs"; };
}
```

Consumers change from two flake inputs to one:

```nix
# Before
inputs.nix-mcp-servers = { ... };
inputs.stacked-workflow-skills = { ... };

# After
inputs.agentic-tools = {
  url = "github:higherorderfunctor/agentic-tools";
  inputs = {
    nixpkgs.follows = "nixpkgs";
    nvfetcher.follows = "nvfetcher";
    rust-overlay.follows = "rust-overlay";
  };
};
```

---

## Current Stack

20 feature commits + 1 sentinel tip. Each feature commit includes its
own documentation (README section, eval checks) — no batched doc commits.
Sentinel commit (`docs/plan.md`) is never included in PRs.

```
 1. chore: scaffold monorepo directory structure and skeleton flake
    LICENSE, README.md (identity), CLAUDE.md, AGENTS.md stub, configs,
    flake.nix skeleton, directory structure

 2. chore: add unified nvfetcher.toml

 3. feat(lib): implement fragment pipeline library
    lib/fragments.nix, lib/default.nix

 4. feat(fragments): add common and monorepo fragments
    fragments/common/*.md, fragments/packages/monorepo/*.md

 5. feat(fragments): generate ecosystem instruction files
    .claude/rules/, .kiro/steering/, .github/, AGENTS.md (generated),
    flake.nix apps.generate wiring

 6. feat(modules): implement copilot-cli home-manager module
    modules/copilot-cli/, checks/module-eval.nix (harness + copilot eval),
    flake.nix checks wiring, README (Nix Quick Start, HM Modules section)

 7. feat(modules): implement kiro-cli home-manager module
    modules/kiro-cli/, module-eval.nix (+kiro eval), README (+kiro subsection)

 8. feat(devshell): implement mkAgenticShell module system
    lib/devshell.nix, devshell/*.nix, checks/devshell-eval.nix,
    README (+DevShell Usage section)

 9. docs(references): add canonical reference documents
    references/*.md (7 files)

10. feat(skills): add stack-fix and stack-split skills
    skills/stack-fix/, skills/stack-split/,
    README (+Non-Nix Quick Start, Skills section with table)

11. feat(skills): add stack-plan and stack-submit skills
    skills/stack-plan/, skills/stack-submit/, README (+table rows)

12. feat(skills): add stack-summary and stack-test skills
    skills/stack-summary/, skills/stack-test/, README (+table rows)

13. feat(skills): add dev skills and wire claude code symlinks
    dev/skills/*, .claude/skills/sws-*

14. feat(packages): add git tool overlays
    packages/git-tools/*, README (+Git Tool Overlays section)

15. feat(packages): add MCP server packages
    packages/mcp-servers/* (incl. npm lockfiles)

16. feat(lib): add MCP library
    lib/mcp.nix, lib/default.nix

17. feat(modules): add MCP server home-manager module
    modules/mcp-servers/default.nix,
    README (+mcp-servers subsection, Feature Matrix)

18. feat(modules): add MCP server definitions (core)
    7 server .nix files, README (+MCP Servers Reference table)

19. feat(modules): add MCP server definitions (remaining)
    5 server .nix files, module-eval.nix (+MCP eval), README (+table rows)

20. feat(modules): add stacked-workflows home-manager module
    modules/stacked-workflows/*, module-eval.nix (+SWS eval),
    README (+stacked-workflows subsection)

21. sentinel: update plan (this file, never in PRs)
```

---

## Phases

### Phase 0: Plan & Scaffold ✓

- Plan document (this file)
- Skeleton flake with inputs, empty outputs, directory structure
- LICENSE (Unlicense), README.md identity, CLAUDE.md, configs
- Fragment pipeline (`lib/fragments.nix`) with monorepo scoping
- Common + monorepo fragments, ecosystem instruction generation

---

### Phase 1: HM Modules (Copilot CLI + Kiro CLI) ✓

- `programs.copilot-cli` module mirroring upstream `programs.claude-code`
- `programs.kiro-cli` module adapted for Kiro conventions
- Module eval checks absorbed into each module commit
- README sections for each module

---

### Phase 1.5: Unified AI Configuration Module (deferred)

**`programs.ai` meta module** — single source of truth for shared config
across Claude Code, Copilot CLI, and Kiro CLI. Eliminates 3x duplication
of MCP servers, skills, and instructions in consumer configs.

```nix
programs.ai = {
  enable = true;
  enableClaude = true;
  enableCopilot = true;
  enableKiro = true;
  skills = { stack-fix = ./skills/stack-fix; };
  mcpServers = { /* shared MCP config */ };
  instructions.coding-standards = {
    text = "Always use strict mode...";
    paths = ["src/**"];
    description = "Project coding standards";
  };
};
```

Design decisions:

- Instructions use shared semantic fields (`text`, `paths`, `description`),
  module translates to ecosystem-specific frontmatter
- Skills are `attrsOf path` (identical format across ecosystems)
- Agents excluded (markdown vs JSON format mismatch)
- Settings excluded (too CLI-specific)
- All injections use `mkDefault` so per-CLI config wins
- Follows stacked-workflows multi-ecosystem pattern (conditional `mkIf`)

**Timing:** implement after copilot-cli and kiro-cli PRs are merged and
reviewed. Insert into stack after kiro-cli commit, before mkAgenticShell.
Must be complete before mkAgenticShell PR merge.

---

### Phase 2: DevShell Modules (`mkAgenticShell`) ✓

- `lib/devshell.nix` with `mkAgenticShell` using `lib.evalModules`
- File materialization, MCP server modules, skills injection
- Devshell eval checks absorbed into module commit
- README DevShell Usage section

---

### Phase 3: Content Migration (mostly complete)

- Skills + references migrated from SWS ✓
- Git tool overlays migrated from SWS ✓
- MCP server packages (12) migrated from nix-mcp-servers ✓
- MCP lib + HM module + server definitions migrated ✓
- Stacked-workflows HM module migrated from SWS ✓
- Unified nvfetcher.toml ✓
- README sections for all migrated content ✓
- Eval checks for MCP + SWS modules ✓

**Remaining:**

- Checkpoint 3.6: AI CLI packages (copilot-cli, kiro-cli, kiro-gateway)
- Checkpoint 3.7: unified checks, CI config, pre-commit hook, devShell
- Checkpoint 3.8: tooling wiring — add linters (deadnix, statix,
  shellcheck, shellharden, shfmt, cspell) and LSPs (nixd, marksman,
  bash-language-server, taplo) to devShell alongside their wiring:
  - Wire dprint LSP to `lspServers` in each ecosystem (copilot-cli,
    kiro-cli, claude-code) — dprint has a built-in LSP
  - Wire linters via instruction files, PostToolUse hooks, or flake checks
  - Wire LSPs via `lspServers` config in each AI CLI module
  - Each tool arrives with its automation, not before

---

### Phase 4: Apps and CI

**Checkpoint 4.1: Update pipeline**

- Migrate `apps/update.sh` from MCP
- Extend for git-tools and AI CLI updates
- Single `nix run .#update` covers all packages

**Checkpoint 4.2: Drift detection**

- Migrate `apps/check-drift.sh` from MCP
- Extend structural checks for cross-reference validation
- CI integration

**Checkpoint 4.3: CI workflows**

- `ci.yml`: flake check + build matrix + cachix
- `update.yml`: daily update pipeline
- `generate-routing.yml`: auto-regenerate on fragment changes
- Branch protection, labels

**Done when:** CI passes on all PRs, daily updates auto-PR, drift
detection creates issues.

---

### Phase 5: Documentation and Polish

**Checkpoint 5.1: README**

- Feature-forward structure:
  1. What this provides (skills, MCP servers, HM modules, devshell)
  2. Quick start (non-Nix: copy skills; Nix: flake input)
  3. Feature matrix (what works with/without Nix)
  4. Skills reference
  5. MCP servers reference
  6. HM modules reference
  7. DevShell usage
  8. Contributing
- Natural search terms: "stacked commits", "git workflow",
  "Claude Code skills", "MCP servers", "home-manager"

**Checkpoint 5.2: Migrate TODOs**

- Consolidate 70 items from SWS (52) and MCP (14) and shared (4)
- Triage: resolved by migration vs. still open
- Create TODO.md or GitHub issues

**Checkpoint 5.3: ADRs**

- Migrate existing ADRs from SWS
- New ADR: monorepo structure decision
- New ADR: fragment pipeline extension
- New ADR: devshell module system

**Checkpoint 5.4: Consumer migration guide**

- Document consumer flake update path
- Before/after flake input examples
- Breaking changes (if any)

**Done when:** README is complete, TODOs triaged, ADRs documented,
migration guide ready.

---

### Phase 6: Stack and Ship

**Checkpoint 6.1: Split sentinel into stack**

- Use `/stack-plan` to split sentinel into logical commits
- One commit per checkpoint where practical

**Checkpoint 6.2: Submit**

- Use `/stack-submit` to create PRs
- Review, iterate, merge

**Checkpoint 6.3: Consumer update**

- Update consumer flake inputs
- Verify `home-manager switch` works
- Remove old repo inputs from consumer flake

---

## Open Questions

### High Importance (affects entire monorepo)

**Q1: Overlay backward compatibility strategy**

SWS packages are top-level (`pkgs.git-absorb`), MCP is namespaced
(`pkgs.nix-mcp-servers.*`). Options:

- **(a)** Keep both patterns as-is (backward compatible, inconsistent)
- **(b)** Namespace everything under `pkgs.agentic-tools.*` (breaking, clean)
- **(c)** Keep both + add unified `pkgs.agentic-tools.*` alias (no
  breakage, some overlay complexity)

**Recommendation:** (a) for now — preserves contracts #6 and #7, avoids
breaking consumers. Can add unified namespace later if desired.

**Q2: `homeManagerModules.default` scope**

Should `default` import ALL modules? Or require explicit opt-in?

- All-in: simple for consumers, but importing copilot-cli module when you
  don't use Copilot is noise
- Opt-in: more boilerplate but cleaner

**Recommendation:** `default` imports all. Modules are no-ops when
`enable = false`. Consumers typically do
`builtins.attrValues outputs.homeManagerModules` to import all.

**Q3: Git history preservation**

- **Subtree merge:** preserves full blame/log history, complex initial
  setup, subtree paths visible in log
- **Fresh start:** clean history, loses context, simpler

**Recommendation:** Fresh start on this branch. Both source repos remain
available for historical reference. The monorepo's history should tell its
own story. Optionally tag both source repos at migration point.

**Q4: Vendored AI CLI packages — migrate now or later?**

copilot-cli, kiro-cli, kiro-gateway are currently vendored elsewhere.
Moving them requires coordinated consumer flake changes.

**Recommendation:** Scaffold the `packages/ai-clis/` directory structure
in Phase 0, but defer actual content migration to Phase 3.6. This
decouples monorepo scaffold from consumer changes.

**Q5: Binary cache name**

MCP has `hof-nix-mcp-servers`. Options:

- Keep existing name (confusing after migration)
- New name: `hof-agentic-tools` or `agentic-tools`

**Recommendation:** New cache `hof-agentic-tools`. Set up in Phase 4
with CI.

**Q6: Shared vs separate nvfetcher.toml**

Both repos use nvfetcher for version tracking. Options:

- Single `nvfetcher.toml` at root with prefixed keys
- Per-package `nvfetcher.toml` files

**Recommendation:** Single file. nvfetcher doesn't support multiple
configs natively. Prefix keys to avoid collision. Generated output in
shared `.nvfetcher/` directory, consumed by per-package `sources.nix`.

---

## Consolidated TODOs (from source repos)

70 items total. Will be triaged in Phase 5.2. Categories:

- **Infrastructure / CI** (13): agnix in CI, node24 workaround removal,
  drift labels, cachix badge, SWS PR merge
- **New features** (11): openmemory-mcp wiring, cclsp, filesystem-mcp,
  atlassian-mcp, gitlab-mcp, slack-mcp, rolling stack workflow, deferred
  tooling, ollama module, vendored AI CLI packages, dprint plugin
  overlay/nvfetcher (pin plugin versions via Nix instead of URLs in
  dprint.json)
- **Tooling gaps** (13): auto-generate MCP config from HM, MCP-vs-Bash
  friction, allowed-tools research, permission propagation, missing
  linters/LSPs in SWS
- **Documentation** (13): CONTRIBUTING.md fix, AGENTS.md fix, README
  ordering, reference doc updates, rolling stack docs
- **Known bugs / tech debt** (21): agnix suppression, PostToolUse
  limitations, rust-overlay scope, sources.nix re-evaluation, hardcoded
  lists (DRY violations), skill content issues

Many items will be resolved by the migration itself (unified devShell,
shared linting, DRY). Remaining items carry forward as monorepo TODOs.

---

## Key Architecture Decisions

### Fragment Pipeline Extension

Current: flat `fragments/` directory, two profiles (package, dev).

Extended:

```
fragments/
├── common/           # Shared (coding standards, commit convention, etc.)
└── packages/
    ├── stacked-workflows/   # Routing table, build commands, etc.
    ├── mcp-servers/         # Server config, overlay architecture, etc.
    └── monorepo/            # Root-level meta (project overview, etc.)
```

`lib/fragments.nix` changes:

- `readFragment` gains package-aware lookup:
  `readFragment "common" "coding-standards"` and
  `readFragment "mcp-servers" "server-config"`
- Profiles become per-package: each package declares which common +
  package-specific fragments to include
- `mkInstructions` gains `paths` parameter for ecosystem-specific
  frontmatter scoping
- Root outputs aggregate all packages; per-package outputs scope to their
  paths

### DevShell Module System (`mkAgenticShell`)

Uses `lib.evalModules` standalone (same pattern as devenv). No
home-manager or devenv dependency required.

Key modules:

- `top-level.nix` — packages, shellHook, shell derivation
- `files.nix` — file materialization (Nix store paths symlinked via
  shellHook, adapted from devenv's `files.nix`)
- `mcp-servers/` — reuses server definitions from
  `modules/mcp-servers/servers/` (DRY)
- `skills/` — injects skill files into ecosystem directories
- `instructions/` — composes from fragments

The bridge between HM modules and devshell modules is the server
definitions in `modules/mcp-servers/servers/*.nix`. These are pure data
(meta, settingsOptions, settingsToEnv, settingsToArgs) consumed by both
the HM module and devshell module.

### HM Module Patterns (Copilot CLI + Kiro CLI)

Both follow upstream `programs.claude-code` conventions:

1. **`pkgs.formats.json`** for type-safe settings generation
2. **Wrapper script** for MCP injection (Copilot: `--additional-mcp-config`;
   Kiro: env-based or file-based)
3. **Activation merge** for mutable config files (`config.json`,
   `settings/cli.json`) — deep-merge Nix settings into existing file,
   preserving runtime-mutated keys
4. **Mutual exclusion assertions** between inline and directory variants
5. **`enableMcpIntegration`** bridging `programs.mcp.servers`
6. **`pkgs.symlinkJoin`** for non-destructive binary wrapping

### Change Propagation Enforcement

CLAUDE.md includes a change propagation rule. Structural check validates:

- Every skill in routing tables exists in `skills/`
- Every fragment referenced in profiles exists in `fragments/`
- Every skill has required reference symlinks that resolve
- Every ecosystem instruction file exists with correct frontmatter
- Every server in `modules/servers/` is registered in the overlay
- Package names in nvfetcher.toml match overlay exports

CI runs these checks on every PR. Pre-commit runs a fast subset.
