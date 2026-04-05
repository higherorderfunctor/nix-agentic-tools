# TODO

Triaged from migration plan, source repo TODOs, and gap analysis.

---

## Implementation (Field Test Scope)

Items needed to wire this flake as input to nixos-config and validate
the final form. Do these first.

### Consumer Integration Blockers

- [ ] Verify `overlays.default` composes cleanly when consumed by nixos-config
- [ ] Verify all 8 interface contracts hold:
  - `pkgs.nix-mcp-servers.*` namespace
  - `pkgs.git-absorb`, `pkgs.git-branchless`, `pkgs.git-revise` top-level
  - `pkgs.github-copilot-cli`, `pkgs.kiro-cli`, `pkgs.kiro-gateway` top-level
  - `lib.mkStdioEntry`, `lib.mkHttpEntry`, `lib.externalServers`
  - `lib.mapTools`, `lib.gitConfig`, `lib.gitConfigFull`
  - `homeManagerModules.default` imports all modules
  - `stacked-workflows.integrations.*.enable`
  - `services.mcp-servers.servers.*.enable`
- [ ] Migrate nixos-config AI config to use `ai.*` unified module
- [ ] Remove vendored copilot-cli, kiro-cli, kiro-gateway overlays from nixos-config
- [ ] Remove `inputs.nix-mcp-servers` + `inputs.stacked-workflow-skills` from nixos-config
- [ ] Add `inputs.agentic-tools` to nixos-config with follows
- [ ] Verify `home-manager switch` works end-to-end

### HM Module Gaps

- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry
- [ ] Verify copilot-cli module activation merge (settings deep-merge)
- [ ] Verify kiro-cli module steering file generation (YAML frontmatter)
- [ ] Verify stacked-workflows integrations wire skills to all 3 ecosystems

### Skill Wiring

- [ ] Wire dev skills (repo-review, index-repo-docs) into each ecosystem
      via devenv files.* — .claude/skills/, .kiro/skills/, .github/skills/
- [ ] Wire consumer skills (stack-*) via devenv files.* instead of
      committed symlinks
- [ ] Register dev skills as invocable

### devenv Polish

- [ ] CUDA config — verify packages build with cudaSupport on x86_64-linux
- [ ] SecretSpec — declarative secrets for MCP credentials
- [ ] devenv MCP segfault — Boehm GC 8.2.12 bug; using mcp.devenv.sh

### Tooling Wiring

- [ ] Wire LSPs to AI CLI modules (nixd, marksman, taplo via lspServers)

### Cleanup

- [ ] Review `<!-- dprint-ignore -->` comments across repo — we use
      treefmt/prettier now, not dprint; replace with `<!-- prettier-ignore -->`
      or remove if no longer needed
- [ ] DRY: extract shared helpers from copilot-cli + kiro-cli modules
      into lib/hm-ai-cli.nix (7 duplicated functions)
- [ ] DRY: extract shared MCP server submodule from devenv copilot/kiro
      modules into modules/devenv/mcp-common.nix
- [ ] aws-mcp.nix orphaned server definition — either wire into serverFiles
      or remove (aws-mcp is external-only via lib.externalServers)

---

## Publish (Pre-Release Scope)

Do these when implementation is validated via field test.

### Stack Restructure

- [ ] Restructure sentinel tip commits into clean atomic stack for PRs
- [ ] Distribute devenv prototype commits into appropriate stack positions
- [ ] Content-level audit of all intermediate file states
- [ ] Open PRs one at a time (Copilot reviews each)

### Infrastructure / CI

- [ ] CI workflow: `ci.yml` — `devenv test` + package build matrix + cachix
- [ ] CI workflow: `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: set up `hof-agentic-tools` cachix cache
- [ ] Cachix badge in README

### Apps

- [ ] `apps/update` — nvfetcher-based version update for all packages
- [ ] `apps/check-drift` — MCP tool drift detection
- [ ] `apps/check-health` — MCP server health checks

### Checks

- [ ] Structural check: validate skill → reference symlinks resolve
- [ ] Structural check: fragment profiles match filesystem
- [ ] Structural check: nvfetcher.toml keys match overlay exports
- [ ] Structural check: module imports match flake homeManagerModules

### Documentation

- [ ] CONTRIBUTING.md
- [ ] Consumer migration guide — before/after flake input examples
- [ ] ADRs — monorepo structure, fragment pipeline, devshell, devenv
- [ ] README: overlay usage examples for consumer flakes
- [ ] README: devenv setup instructions

### New Features (Backlog)

- [ ] openmemory-mcp — typed settings in MCP server module
- [ ] cclsp — Claude Code LSP integration
- [ ] filesystem-mcp, atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] Rolling stack workflow skill
- [ ] Ollama HM module — potential migration from nixos-config
- [ ] flake-parts — modular per-package flake outputs
- [ ] Shell linters when shell scripts exist (shellcheck, shfmt)
- [ ] MCP processes — wire no-cred servers for `devenv up`

---

## Resolved ✓

- ✓ Pre-commit hooks — devenv git-hooks
- ✓ treefmt replaces dprint — devenv built-in treefmt module
- ✓ git-hooks auto-wired to claude.code via PostToolUse
- ✓ AI CLI packages — copilot-cli, kiro-cli, kiro-gateway
- ✓ Git tool overlays — git-absorb, git-branchless, git-revise
- ✓ MCP server packages — 12 servers
- ✓ programs.copilot-cli, programs.kiro-cli — full implementation
- ✓ services.mcp-servers — full with 12 server definitions
- ✓ stacked-workflows — git config presets + AI tool integrations
- ✓ ai — unified config across Claude/Copilot/Kiro
- ✓ devenv standalone CLI mode
- ✓ File materialization from fragment pipeline
- ✓ claude.code.* (settings, permissions, MCP servers)
- ✓ Custom Kiro + Copilot devenv modules
- ✓ .envrc for direnv auto-activation
- ✓ Module eval checks — all modules
- ✓ Devshell eval checks — minimal, mcp, skills
- ✓ apps/generate — fragment → instruction file generation
- ✓ Linter + cspell wiring — deadnix, statix, cspell in devShell
- ✓ README — feature-forward, all sections
- ✓ Fragment profiles — ai-clis, mcp-servers, stacked-workflows dev profiles
- ✓ Repo review findings — loadServer path, package defaults, binary names,
  Copilot paths, Darwin guard, dprint→treefmt, stale URLs, prerequisites
