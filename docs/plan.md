# agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Branch: `sentinel/monorepo-plan`

## Architecture

- **Standalone devenv CLI** for dev shell (not flake-based)
- **Top-level `ai`** namespace for unified config (HM and devenv)
- **Config parity** — lib, HM, and devenv must align in capability
- **Content packages** — published content (skills, fragments) lives in
  `packages/` as derivations with passthru for eval-time composition
- **Pure fragment lib** — compose, mkFragment, mkEcosystemContent;
  no file I/O, no hardcoded data
- **treefmt** via devenv built-in module (replaced dprint)
- **devenv MCP** uses public `mcp.devenv.sh` (local Boehm GC bug)

---

## Next Session

### ai.\* API restructure (do before HITL testing)

Restructure `enableClaude/enableCopilot/enableKiro` into submodules with
package overrides. Package defaults to overlay package.

- [x] Restructure ai.\* module API (HM + devenv):
      `enableClaude = true` → `claude = { enable = true; package = ...; }`
      Same for copilot and kiro. Package defaults to overlay package
      (not nixpkgs upstream).
- [x] Update all consumers: devenv.nix, checks/module-eval.nix
- [x] Update all docs: getting-started/home-manager.md, devenv.md,
      concepts/unified-ai-module.md, guides, README.md
- [ ] Update CLAUDE.md, AGENTS.md, dev fragments

### Then test

- [ ] Review docs site (`devenv up docs` — opens browser automatically)
- [ ] Wire agentic-tools into nixos-config: HM global + devshell per-repo
- [ ] Review docs accuracy against actual consumer experience
- [ ] Fix any doc gaps found during integration testing

---

## Solo (no external deps — can run autonomously)

### CI & Automation

- [ ] `ci.yml` — `devenv test` + package build matrix + cachix push
- [ ] `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: `hof-agentic-tools` cachix setup
- [ ] After cachix: remove flake input overrides in nixos-config
      (currently needed because no binary cache — builds from source)

### Apps & Structural Checks

- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, nvfetcher keys, module imports)

### Documentation & Guides

- [ ] CONTRIBUTING.md — dev workflow, package patterns, module patterns,
      `devenv up docs` for docs preview, `devenv up` process naming
- [ ] Consumer migration guide — replace vendored packages + nix-mcp-servers
- [ ] ADRs for key decisions (standalone devenv, fragment pipeline, config parity)
- [ ] GitHub Pages deploy workflow
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
- [ ] Fresh clone test — clone to /tmp, `devenv test`, verify no rogue
      .gitignore files making dev workflow work but fresh clone fail

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

- [ ] Auto-display images in terminal — fragment/hook/plugin that auto-runs
      `chafa --format=sixel` when AI reads/generates images. Wire via ai.\*
      so all ecosystems get it. Needs chafa in packages.
- [ ] ChatGPT Codex CLI — package + HM/devenv module, same pattern as
      copilot-cli/kiro-cli; add to `ai.*` unified fanout as 4th ecosystem
- [ ] cclsp — Claude Code LSP integration (passthru.withAdapters pattern)
- [ ] filesystem-mcp — package + wire to devenv; may reduce tool approval
      friction for file operations
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion — new presets (code review, security, testing)
- [ ] HM/devenv modules as packages — research NixOS module packaging
      patterns; would allow `pkgs.agentic-modules.ai` etc. for FP composition
- [ ] Logo refinement — higher quality SVG or larger PNG, crisp at all sizes
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] Module fragment exposure — MCP servers contributing own fragments
- [ ] Ollama HM module
- [ ] Rename repo to `nix-agentic-tools`
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] openmemory-mcp typed settings
- [ ] Rolling stack workflow skill
