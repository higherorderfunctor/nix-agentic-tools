# TODO

Triaged from migration plan, source repo TODOs, and gap analysis.
Items marked ✓ are resolved by the migration or devenv adoption.

---

## Implementation (Field Test Scope)

Items needed to wire this flake as input to nixos-config and validate
the final form. Do these first.

### Consumer Integration Blockers

- [ ] Verify `overlays.default` composes cleanly when consumed by nixos-config
      (ai-clis + git-tools + mcp-servers — test with `inputs.agentic-tools.overlays.default`)
- [ ] Verify all 8 interface contracts from nixos-config still hold:
  - `pkgs.nix-mcp-servers.*` namespace
  - `pkgs.git-absorb`, `pkgs.git-branchless`, `pkgs.git-revise` top-level
  - `pkgs.github-copilot-cli`, `pkgs.kiro-cli`, `pkgs.kiro-gateway` top-level
  - `lib.mkStdioEntry`, `lib.mkHttpEntry`, `lib.externalServers`
  - `lib.mapTools`, `lib.gitConfig`, `lib.gitConfigFull`
  - `homeManagerModules.default` imports all modules
  - `stacked-workflows.integrations.*.enable`
  - `services.mcp-servers.servers.*.enable`
- [ ] Migrate nixos-config AI config to use `ai.*` unified module
      (replace 3x duplicated MCP/skills/instructions across Claude/Copilot/Kiro)
- [ ] Remove vendored copilot-cli, kiro-cli, kiro-gateway overlays from nixos-config
- [ ] Remove `inputs.nix-mcp-servers` + `inputs.stacked-workflow-skills` from nixos-config
- [ ] Add `inputs.agentic-tools` to nixos-config with follows (nixpkgs, nvfetcher, rust-overlay)
- [ ] Verify `home-manager switch` works end-to-end

### HM Module Gaps

- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry with
      typed settings (currently hardcoded in nixos-config kiro/default.nix)
- [ ] Verify copilot-cli module activation merge works (settings deep-merge
      with mutable config.json)
- [ ] Verify kiro-cli module steering file generation (YAML frontmatter)
- [ ] Verify stacked-workflows integrations wire skills to all 3 ecosystems

### devenv Polish

- [ ] CUDA config — verify packages build with cudaSupport on x86_64-linux
- [ ] SecretSpec — declarative secrets for MCP credentials (GitHub, Kagi, etc.)
      so `devenv shell` can wire cred-requiring MCP servers
- [ ] devenv MCP segfault — Boehm GC 8.2.12 crash during nixpkgs
      enumeration; using mcp.devenv.sh workaround; upstream aware

### Skill Wiring

- [ ] Wire dev skills (repo-review, index-repo-docs) into each ecosystem
      via devenv files.* — .claude/skills/, .kiro/skills/, .github/skills/
- [ ] Wire consumer skills (stack-*) via devenv files.* instead of
      committed symlinks — move .claude/skills/sws-* to devenv generation
- [ ] Register dev skills as invocable (currently in dev/skills/ but not
      in .claude/skills/ or any ecosystem skill path)

### Tooling Wiring

- [ ] Wire LSPs to AI CLI modules (nixd, marksman, taplo via lspServers)

---

## Publish (Pre-Release Scope)

Items for cleaning up, documenting, and shipping. Do these when
implementation is validated via field test.

### Stack Restructure

- [ ] Restructure sentinel tip commits into clean atomic stack for PRs
- [ ] Distribute devenv prototype commits into appropriate stack positions
- [ ] Content-level audit of all intermediate file states (no forward refs)
- [ ] Open PRs one at a time (Copilot reviews each)

### Infrastructure / CI

- [ ] CI workflow: `ci.yml` — `devenv test` + package build matrix + cachix
- [ ] CI workflow: `update.yml` — daily nvfetcher update pipeline
- [ ] CI workflow: `generate-routing.yml` — auto-regenerate on fragment changes
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

- [ ] CONTRIBUTING.md — dev setup, code style, commit convention, testing,
      skill development, fragment pipeline, stack workflow
- [ ] Consumer migration guide — before/after flake input examples
- [ ] ADRs — monorepo structure, fragment pipeline, devshell, devenv adoption
- [ ] README: overlay usage examples for consumer flakes
- [ ] README: devenv setup instructions (direnv, devenv shell)

### New Features (Backlog)

- [ ] openmemory-mcp wiring — typed settings in MCP server module
- [ ] cclsp — Claude Code LSP integration
- [ ] filesystem-mcp, atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] Rolling stack workflow skill
- [ ] Ollama HM module — potential migration from nixos-config
- [ ] flake-parts — modular per-package flake outputs
- [ ] dprint plugin overlay/nvfetcher — pin plugin versions via Nix
- [ ] Wire shell linters when shell scripts exist (shellcheck, shfmt)
- [ ] Wire dprint LSP to each ecosystem
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
- ✓ claude.code.\* (settings, permissions, MCP servers)
- ✓ Custom Kiro + Copilot devenv modules
- ✓ .envrc for direnv auto-activation
- ✓ Module eval checks — all modules
- ✓ Devshell eval checks — minimal, mcp, skills
- ✓ apps/generate — fragment → instruction file generation
- ✓ Linter + cspell wiring — deadnix, statix, cspell in devShell packages
- ✓ packages/default.nix — removed scaffold-era stub (composition lives in flake.nix)
- ✓ README — feature-forward, all sections
- ✓ Common + monorepo + SWS routing-table fragments
- ✓ Fragment profiles — ai-clis, mcp-servers, stacked-workflows dev profiles wired
