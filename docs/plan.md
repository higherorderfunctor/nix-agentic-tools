# agentic-tools Plan

> Living document. Single source of truth for project status and tasks.
> Branch: `sentinel/monorepo-plan`

## Vision

A single flake consolidating all agentic tooling:

- **Skills** — stacked workflow skills for Claude Code, Kiro, and Copilot
- **MCP servers** — 13 packaged servers with typed settings, credentials
- **Home-manager modules** — declarative config for AI CLIs, MCP servers,
  stacked workflows, and unified AI config
- **DevShell modules** — per-project AI config (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise
- **AI CLI packages** — copilot-cli, kiro-cli, kiro-gateway
- **devenv integration** — standalone CLI with treefmt, git-hooks,
  claude.code, file materialization from fragments

Skills work without Nix. Everything else requires Nix.

---

## Architecture

### Key decisions (resolved)

- **Standalone devenv CLI** — not flake-based `devenv.lib.mkShell`.
  Full features: eval caching, `devenv mcp`, `devenv up`, `devenv test`.
  Flake keeps package/overlay/module exports.
- **Top-level `ai` namespace** — unified HM config across Claude/Copilot/Kiro
- **MCP bridging** — via `programs.mcp.servers` (existing HM plumbing)
- **treefmt replaces dprint** — via devenv built-in treefmt module
- **Fragment pipeline** — single source for multi-ecosystem instruction files,
  materialized by devenv `files.*` (not committed)
- **Overlay compat** — keep both top-level git tools + namespaced MCP servers
- **`homeManagerModules.default`** — imports all modules (no-ops when disabled)
- **Fresh git history** — source repos available for reference

### Flake outputs

```
overlays.{default, ai-clis, git-tools, mcp-servers}
homeManagerModules.{default, ai, copilot-cli, kiro-cli, mcp-servers, stacked-workflows}
lib.{fragments, mkAgenticShell, mkStdioEntry, mkHttpEntry, mkStdioConfig,
     mkMcpConfig, mapTools, externalServers, gitConfig, gitConfigFull}
packages.{18 packages: 3 AI CLIs + 3 git tools + 12 MCP servers}
apps.{generate}
checks.{module-eval, devshell-eval}
```

### devenv (standalone CLI)

- `devenv.nix` + `devenv.yaml` — shell config + inputs
- `treefmt.nix` — shared formatter config
- `.envrc` — direnv auto-activation (`use devenv`)
- `modules/devenv/` — custom Kiro + Copilot devenv modules
- devenv MCP: uses public `mcp.devenv.sh` (local crashes: Boehm GC bug)

---

## What's Done

### Packages ✓
- 3 AI CLIs: github-copilot-cli, kiro-cli, kiro-gateway
- 3 git tools: git-absorb, git-branchless, git-revise
- 12 MCP servers: context7, effect, fetch, git-intel, git, github, kagi,
  mcp-proxy, nixos, openmemory, sequential-thinking, sympy

### HM Modules ✓
- `ai` — unified config with instruction path scoping per ecosystem
- `programs.copilot-cli` — full (settings, MCP, skills, instructions)
- `programs.kiro-cli` — full (steering, MCP, skills, hooks)
- `services.mcp-servers` — 12 server definitions + systemd services
- `stacked-workflows` — git config presets + AI tool integrations

### Skills ✓
- 6 consumer: stack-fix, stack-plan, stack-split, stack-submit,
  stack-summary, stack-test
- 2 dev: repo-review (with tiered models), index-repo-docs
- 7 canonical reference docs

### Fragment Pipeline ✓
- Profiles: monorepo, ai-clis, mcp-servers, stacked-workflows
- 4 common fragments + per-package fragments
- Multi-ecosystem output (Claude, Kiro, Copilot, AGENTS.md)
- devenv files.* materializes all outputs as store symlinks

### devenv ✓
- Standalone CLI mode with git-hooks, treefmt, claude.code
- File materialization from fragment pipeline
- Eval checks for all modules + devshell

### Review ✓
- 6-reviewer repo-review with confidence scoring
- All findings fixed: loadServer path, package defaults, binary names,
  Copilot paths, Darwin guard, dprint→treefmt, stale URLs, prerequisites

---

## Implementation (Field Test)

Wire this flake as input to nixos-config. Validate the final form.

### Consumer Integration

- [ ] Verify `overlays.default` composes cleanly in nixos-config
- [ ] Verify all 8 interface contracts hold
- [ ] Add `inputs.agentic-tools` to nixos-config with follows
- [ ] Migrate nixos-config AI config to `ai.*` unified module
- [ ] Remove vendored copilot-cli, kiro-cli, kiro-gateway from nixos-config
- [ ] Remove `inputs.nix-mcp-servers` + `inputs.stacked-workflow-skills`
- [ ] Verify `home-manager switch` end-to-end

### HM Module Verification

- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry
- [ ] Verify copilot-cli activation merge (settings deep-merge)
- [ ] Verify kiro-cli steering file generation (YAML frontmatter)
- [ ] Verify stacked-workflows integrations wire all 3 ecosystems

### Skill Wiring

- [ ] Wire dev skills into each ecosystem via devenv files.*
- [ ] Wire consumer skills via devenv files.* (replace committed symlinks)
- [ ] Register dev skills as invocable

### devenv Polish

- [ ] CUDA — verify packages build with cudaSupport on x86_64-linux
- [ ] SecretSpec — declarative secrets for MCP credentials
- [ ] devenv MCP segfault — Boehm GC bug, using mcp.devenv.sh workaround

### Tooling Wiring

- [ ] Wire LSPs to AI CLI modules (nixd, marksman, taplo via lspServers)

### Cleanup

- [ ] Review `<!-- dprint-ignore -->` comments — replace with
      `<!-- prettier-ignore -->` or remove
- [ ] DRY: extract shared helpers from copilot-cli + kiro-cli into
      lib/hm-ai-cli.nix (7 duplicated functions)
- [ ] DRY: extract shared MCP server submodule from devenv modules
- [ ] aws-mcp.nix orphaned server definition — wire or remove

---

## Publish (Pre-Release)

Do after field test validates.

### Stack Restructure

- [ ] Restructure sentinel commits into clean atomic stack
- [ ] Distribute devenv prototype commits to correct positions
- [ ] Content-level audit (no forward references)
- [ ] Open PRs one at a time (Copilot reviews each)

### CI

- [ ] `ci.yml` — `devenv test` + package build matrix + cachix
- [ ] `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: `hof-agentic-tools` cachix
- [ ] Cachix badge in README

### Apps

- [ ] `apps/update` — nvfetcher version updates
- [ ] `apps/check-drift` — MCP tool drift detection
- [ ] `apps/check-health` — MCP server health checks

### Structural Checks

- [ ] Validate skill → reference symlinks resolve
- [ ] Fragment profiles match filesystem
- [ ] nvfetcher.toml keys match overlay exports
- [ ] Module imports match flake homeManagerModules

### Documentation

- [ ] CONTRIBUTING.md
- [ ] Consumer migration guide (before/after flake inputs)
- [ ] ADRs — monorepo, fragment pipeline, devshell, devenv
- [ ] README: overlay usage examples, devenv setup instructions

---

## Backlog

- [ ] openmemory-mcp — typed settings in server module
- [ ] cclsp — Claude Code LSP integration
- [ ] filesystem-mcp, atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] Rolling stack workflow skill
- [ ] Ollama HM module — migration from nixos-config
- [ ] flake-parts — modular per-package flake outputs
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
- [ ] MCP processes — no-cred servers for `devenv up`
