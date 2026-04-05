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

## Implementation (Field Test)

Wire this flake as input to nixos-config. Validate the final form.

### Consumer Integration (HITL — requires nixos-config)

- [ ] Add `inputs.agentic-tools` to nixos-config with follows
- [ ] Verify overlays + 8 interface contracts hold
- [ ] Migrate nixos-config AI config to `ai.*` unified module
- [ ] Remove vendored copilot-cli, kiro-cli, kiro-gateway from nixos-config
- [ ] Remove `inputs.nix-mcp-servers` + `inputs.stacked-workflow-skills`
- [ ] Verify `home-manager switch` end-to-end

### HM Module Verification (HITL — requires system test)

- [ ] Kiro openmemory MCP: migrate from raw npx to mkStdioEntry
- [ ] Verify copilot-cli activation merge (settings deep-merge)
- [ ] Verify kiro-cli steering file generation (YAML frontmatter)
- [ ] Verify stacked-workflows integrations wire all 3 ecosystems

### devenv ai.\* Settings Normalization

- [ ] Add normalized `ai.settings` to devenv ai module (model, telemetry)
      that translates to ecosystem-specific settings per CLI
- [ ] Expand devenv copilot/kiro modules with richer settings options
      matching claude.code depth (hooks, permissions where applicable)

### Remaining Cleanup

- [ ] CUDA — verify packages build with cudaSupport on x86_64-linux
- [ ] cspell: research built-in dictionaries (nix, typescript, etc.) to
      reduce custom project-terms.txt — load via cspell.json `dictionaries`
- [ ] Review config parity matrix in references/config-parity.md against
      actual module implementations — close any remaining gaps

---

## Publish (Pre-Release)

Do after field test validates.

- [ ] Restructure sentinel commits into clean atomic stack
- [ ] Content-level audit (no forward references)
- [ ] Open PRs one at a time (Copilot reviews each)
- [ ] `ci.yml` — `devenv test` + package build matrix + cachix
- [ ] `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: `hof-agentic-tools` cachix
- [ ] `apps/update`, `apps/check-drift`, `apps/check-health`
- [ ] Structural checks (symlinks, fragments, nvfetcher keys, module imports)
- [ ] CONTRIBUTING.md, consumer migration guide, ADRs
- [ ] README: overlay usage examples, devenv setup instructions
- [ ] SecretSpec — declarative secrets for MCP credentials

---

## Backlog

- [ ] openmemory-mcp typed settings
- [ ] cclsp — Claude Code LSP integration
- [ ] filesystem-mcp, atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] Rolling stack workflow skill
- [ ] Ollama HM module
- [ ] flake-parts — modular per-package flake outputs
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
- [ ] MCP processes — no-cred servers for `devenv up`
