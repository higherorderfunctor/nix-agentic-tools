# agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Branch: `sentinel/monorepo-plan`

## Architecture

- **Standalone devenv CLI** for dev shell (not flake-based)
- **Top-level `ai`** namespace for unified config (HM and devenv)
- **Config parity** — lib, HM, and devenv must align in capability
- **MCP bridging** via `programs.mcp.servers`
- **treefmt** via devenv built-in module (replaced dprint)
- **Fragment pipeline** materializes ecosystem files via devenv `files.*`
- **devenv MCP** uses public `mcp.devenv.sh` (local Boehm GC bug)

---

## Solo (no external deps — can run autonomously)

### Composable Fragment Library

Infrastructure landed. Design in memory: `project_fragment_system.md`.

- [x] `lib.fragments.compose` — priority sort, dedup, concat with optional
      metadata overrides (description, paths, priority)
- [x] `mkFragment` constructor — canonical typed fragment attrset
- [x] `readCommonFragment` / `readPackageFragment` — typed wrappers
- [x] `packages/fragments/` — overlay exposing `pkgs.agentic-fragments`
      with common fragments + compose + mkFragment
- [x] Frontmatter generators exposed in `flake.nix` lib
- [x] Self-cook: devenv.nix uses compose + mkEcosystemFile
- [x] Self-cook: apps.generate uses compose + mkEcosystemFile
- [x] stacked-workflows HM module uses compose + aiCommon frontmatter
- [ ] Create preset compositions (agentic-tools-dev, minimal-coding, etc.)
- [ ] Module fragment exposure (MCP servers contributing own fragments)
- [ ] Fragment content expansion (code review, security, testing presets)

### README & Documentation

Research done — structure in memory: `project_readme_strategy.md`.
Single rich README with collapsible sections (nixvim pattern).

- [ ] README rewrite: hero block, badges, 3 collapsible quick starts
- [ ] Features matrix table (feature × non-Nix/HM/devenv)
- [ ] Configuration section: collapsible per-module (HM + devenv + lib)
- [ ] Consumer guide: flake input, overlay, HM integration, devenv example
- [ ] Config parity matrix, architecture tree, fragment pipeline explanation
- [ ] `ai.*` mapping table — how each `ai.*` option maps to underlying
      ecosystem primitives (claude.code._, copilot._, kiro.\*), known gaps,
      missing support, translation quirks (e.g. model name differences)

### New MCP Server Packages

- [x] Serena MCP — flake input (oraios/serena), codebase-aware semantic
      code tools (find_symbol, references, edits), wired to all 3 ecosystems

### CI & Automation

- [ ] `ci.yml` — `devenv test` + package build matrix + cachix push
- [ ] `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: `hof-agentic-tools` cachix setup

### Apps & Structural Checks

- [ ] `apps/update` — run nvfetcher + rebuild hashes
- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, nvfetcher keys, module imports)

### Documentation & Guides

- [ ] CONTRIBUTING.md — dev workflow, package patterns, module patterns
- [ ] Consumer migration guide — replace vendored packages + nix-mcp-servers
- [ ] ADRs for key decisions (standalone devenv, fragment pipeline, config parity)
- [ ] SecretSpec — declarative secrets for MCP credentials

---

## HITL (requires nixos-config or interactive testing)

### Consumer Integration

- [ ] Add `inputs.agentic-tools` to nixos-config with follows
- [ ] Verify overlays + 8 interface contracts hold
- [ ] Migrate nixos-config AI config to `ai.*` unified module
- [ ] Remove vendored copilot-cli, kiro-cli, kiro-gateway from nixos-config
- [ ] Remove `inputs.nix-mcp-servers` + `inputs.stacked-workflow-skills`
- [ ] Verify `home-manager switch` end-to-end

### HM Module Verification

- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry
- [ ] Verify copilot-cli activation merge (settings deep-merge)
- [ ] Verify kiro-cli steering file generation (YAML frontmatter)
- [ ] Verify stacked-workflows integrations wire all 3 ecosystems
- [ ] CUDA — verify packages build with cudaSupport on x86_64-linux

### Publish (Pre-Release)

- [ ] Stack redistribution — use `/stack-plan` on the TIP state only:
  - Run `/stack-summary --root` to understand the final tree at HEAD
  - Ignore the commit history (failed paths, pivots, restacks are noise)
  - Plan new commits from scratch based on what FILES exist at tip
  - Only main's merged content is the base — everything else is new
  - Think through end-to-end: what order lets a reviewer understand
    the architecture incrementally? Consider dependency timing + the
    content-level audit rules from the skill
  - Don't preserve intermediate implementations that were replaced
    (e.g., flake-based devenv commits are gone, dprint config is gone)
- [ ] Content-level audit (no forward references)
- [ ] Open PRs one at a time (Copilot reviews each)

---

## Backlog

- [ ] Rename repo to `nix-agentic-tools` — too Nix-heavy for `agentic-tools`;
      skills still publishable for general consumption but overlays, HM modules,
      devenv modules are Nix-specific. Update GitHub repo name, flake description,
      README, all internal references, cachix name
- [ ] ChatGPT Codex CLI — package + HM/devenv module, same pattern as
      copilot-cli/kiro-cli; add to `ai.*` unified fanout as 4th ecosystem
- [ ] cclsp — Claude Code LSP integration (passthru.withAdapters pattern)
- [ ] filesystem-mcp, atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] flake-parts — modular per-package flake outputs
- [ ] HM/devenv modules as packages — research NixOS module packaging
      patterns; would allow `pkgs.agentic-modules.ai` etc. for FP composition
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] Ollama HM module
- [ ] openmemory-mcp typed settings
- [ ] Rolling stack workflow skill
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
