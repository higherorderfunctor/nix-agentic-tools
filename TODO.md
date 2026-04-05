# TODO

Triaged from migration plan, source repo TODOs, and gap analysis.
Items marked ✓ are resolved by the migration or devenv adoption.

## Stack Restructure

- [ ] Restructure sentinel tip commits into clean atomic stack for PRs
- [ ] Distribute devenv prototype commits into appropriate stack positions
- [ ] Content-level audit of all intermediate file states (no forward refs)
- [ ] Open PRs one at a time (Copilot reviews each)

## Infrastructure / CI

- [ ] CI workflow: `ci.yml` — `devenv test` + package build matrix + cachix
- [ ] CI workflow: `update.yml` — daily nvfetcher update pipeline
- [ ] CI workflow: `generate-routing.yml` — auto-regenerate on fragment changes
- [ ] Binary cache: set up `hof-agentic-tools` cachix cache
- [ ] Cachix badge in README
- ✓ Pre-commit hooks — devenv git-hooks (treefmt, deadnix, statix, cspell, convco)
- ✓ ~~agnix in CI~~ — agnix runs via devenv git-hooks PostToolUse
- ✓ ~~node24 workaround~~ — resolved by nixpkgs update

## Apps

- [ ] `apps/update` — nvfetcher-based version update for all packages
- [ ] `apps/check-drift` — MCP tool drift detection
- [ ] `apps/check-health` — MCP server health checks
- ✓ `apps/generate` — fragment → instruction file generation (exists but
  superseded by devenv files.* for dev shell; keep for CI/non-devenv users)

## Checks

- [ ] Structural check: validate skill → reference symlinks resolve
- [ ] Structural check: fragment profiles match filesystem
- [ ] Structural check: nvfetcher.toml keys match overlay exports
- [ ] Structural check: module imports match flake homeManagerModules
- [ ] Formatting check: `treefmt --fail-on-change` (via `devenv test`)
- [ ] Spelling check: cspell (via `devenv test`)
- [ ] Agent config check: agnix --strict (via `devenv test`)
- ✓ Module eval checks — copilot-cli, kiro-cli, mcp-servers, sws, ai
- ✓ Devshell eval checks — minimal, mcp, skills

## Tooling Wiring (Phase 3.8)

- [ ] Wire linters to devenv shell (deadnix, statix in devShell packages)
- [ ] Wire shell linters when shell scripts exist (shellcheck, shfmt)
- [ ] Wire LSPs to AI CLI modules (nixd, marksman, taplo via lspServers)
- [ ] Wire dprint LSP to each ecosystem
- [ ] Add cspell to devShell when wired to instruction files
- ✓ treefmt replaces dprint — devenv built-in treefmt module
- ✓ git-hooks auto-wired to claude.code via PostToolUse

## Packages

- ✓ AI CLI packages — copilot-cli, kiro-cli, kiro-gateway
- ✓ Git tool overlays — git-absorb, git-branchless, git-revise
- ✓ MCP server packages — 12 servers
- [ ] dprint plugin overlay/nvfetcher — pin plugin versions via Nix

## HM Modules

- ✓ programs.copilot-cli — full implementation
- ✓ programs.kiro-cli — full implementation
- ✓ services.mcp-servers — full with 12 server definitions
- ✓ stacked-workflows — git config presets + AI tool integrations
- ✓ ai — unified config across Claude/Copilot/Kiro
- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry with
  typed settings (currently in nixos-config)

## devenv

- ✓ Standalone CLI mode with devenv.yaml inputs
- ✓ File materialization from fragment pipeline
- ✓ treefmt (alejandra, prettier, taplo, biome)
- ✓ git-hooks (treefmt, deadnix, statix, cspell, convco, check-json, check-toml)
- ✓ claude.code.* (settings, permissions, MCP servers)
- ✓ Custom Kiro + Copilot devenv modules (modules/devenv/)
- ✓ .envrc for direnv auto-activation
- [ ] CUDA config — in flake.nix pkgsFor but not tested/verified
- [ ] MCP processes — wire no-cred servers for `devenv up` when bridge
  mode is needed
- [ ] SecretSpec — declarative secrets for MCP credentials (GitHub, Kagi, etc.)
- [ ] devenv MCP server — local `devenv mcp` crashes (Boehm GC 8.2.12 bug);
  using public mcp.devenv.sh as workaround; file upstream issue

## Fragments

- [ ] MCP server package-specific fragments (fragments/packages/mcp-servers/)
- [ ] Stacked-workflows dev profile fragments (commented out in fragments.nix)
- [ ] AI CLI package fragments (fragments/packages/ai-clis/)
- ✓ Common fragments — coding-standards, commit-convention, tooling-preference,
  validation
- ✓ Monorepo project-overview fragment
- ✓ Stacked-workflows routing-table fragment

## Documentation

- [ ] CONTRIBUTING.md — dev setup, code style, commit convention, testing,
  skill development guidelines, fragment pipeline overview, stack workflow
- [ ] Consumer migration guide — before/after flake input examples,
  breaking changes
- [ ] ADRs — monorepo structure, fragment pipeline, devshell module system,
  devenv adoption
- [ ] README: overlay usage examples for consumer flakes
- [ ] README: devenv setup instructions (direnv, devenv shell)
- ✓ README — feature-forward, skills table, HM modules, devshell, MCP
  servers, git tools, feature matrix

## New Features (Backlog)

- [ ] openmemory-mcp wiring — typed settings in MCP server module
- [ ] cclsp — Claude Code LSP integration
- [ ] filesystem-mcp — local filesystem MCP server
- [ ] atlassian-mcp — Atlassian/Jira MCP server
- [ ] gitlab-mcp — GitLab MCP server
- [ ] slack-mcp — Slack MCP server
- [ ] Rolling stack workflow skill
- [ ] Ollama HM module — potential migration from nixos-config
- [ ] flake-parts evaluation — modular per-package flake outputs

## Tech Debt

- [ ] packages/default.nix — overlay composition stub (commented out)
- [ ] Stacked-workflows dev profile — remaining fragments not migrated
- [ ] devenv MCP segfault — Boehm GC 8.2.12 crash during nixpkgs
  enumeration in mcp-cache-init thread; file upstream issue
- ✓ ~~agnix suppression rules~~ — handled in .agnix.toml
- ✓ ~~PostToolUse limitations~~ — replaced by devenv git-hooks
- ✓ ~~sources.nix re-evaluation~~ — per-package .nvfetcher dirs
- ✓ ~~hardcoded lists (DRY)~~ — fragment pipeline + module system
- ✓ ~~MCP-vs-Bash friction~~ — devenv claude.code.permissions handles this
