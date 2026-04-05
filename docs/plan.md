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

## Done (this session)

### Package-Focused Restructure

- [x] `packages/stacked-workflows/` — content package with skills (6),
      references (6), routing-table fragment; derivation + passthru
- [x] `packages/coding-standards/` — 5 common fragments as derivation + passthru.fragments (priority=10)
- [x] Dev-only content moved to `dev/` (fragments, references)
- [x] Root `skills/`, `references/`, `fragments/` removed
- [x] `lib/fragments.nix` — pure functions only (compose, mkFragment,
      mkFrontmatter, ecosystems, mkEcosystemContent). 65 lines, was 273.
- [x] devenv.nix consumes from package passthru via content overlays
- [x] apps.generate consumes from package passthru
- [x] stacked-workflows HM module consumes from pkgs.stacked-workflows-content
- [x] All docs updated (CLAUDE.md, README, dev fragments, .gitignore)

### Earlier Work

- [x] agnix + mcp-language-server packaged
- [x] Serena MCP — flake input, wired to all 3 ecosystems
- [x] `ai.lspServers` typed submodule with mkLspConfig/mkCopilotLspConfig
- [x] `ENABLE_LSP_TOOL=1` auto-set when ai.lspServers non-empty
- [x] `lib.mkPackageEntry` — DRY MCP entry from package passthru
- [x] Frontmatter generators exposed in flake.nix lib
- [x] Deadnix/statix/cspell cleanup across entire repo

---

## Solo (no external deps — can run autonomously)

### Fragment Presets (refactor of existing content)

- [x] Named preset compositions: `coding-standards.presets.all`,
      `coding-standards.presets.minimal`, `lib.presets.agentic-tools-dev`

### Documentation

mdBook + Pagefind docs site at `docs/`. Logo chosen (#4, OLED black + grey
hexagons with colored nodes). Dark mode (coal theme) default.

- [x] Fix devenv module export gap (devenvModules in flake.nix)
- [x] Choose framework: mdBook + Pagefind (both in nixpkgs, dark mode)
- [x] Logo generated and optimized (docs/src/assets/)
- [x] Scaffold: book.toml, SUMMARY.md, directory structure
- [x] Getting Started: choose-your-path, home-manager, devenv quickstarts
- [x] Concepts: overlays & packages reference
- [ ] Concepts: unified ai module, fragments, credentials, config parity
- [ ] Guides: HM deep dive, devenv deep dive, MCP servers, stacked workflows
- [ ] Reference: lib API, types, ai.\* mapping table
- [ ] Troubleshooting page
- [ ] `nix build .#docs` derivation (mdbook build + pagefind)
- [ ] GitHub Pages deploy workflow
- [ ] README rewrite: slim landing page linking to docs site

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

- [ ] Fragment content expansion — new presets (code review, security, testing)
- [ ] Module fragment exposure — MCP servers contributing own fragments
- [ ] Rename repo to `nix-agentic-tools` — too Nix-heavy for `agentic-tools`;
      skills still publishable for general consumption but overlays, HM modules,
      devenv modules are Nix-specific. Update GitHub repo name, flake description,
      README, all internal references, cachix name
- [ ] ChatGPT Codex CLI — package + HM/devenv module, same pattern as
      copilot-cli/kiro-cli; add to `ai.*` unified fanout as 4th ecosystem
- [ ] cclsp — Claude Code LSP integration (passthru.withAdapters pattern)
- [ ] filesystem-mcp — package + wire to devenv; may reduce tool approval
      friction for file operations
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] flake-parts — modular per-package flake outputs
- [ ] HM/devenv modules as packages — research NixOS module packaging
      patterns; would allow `pkgs.agentic-modules.ai` etc. for FP composition
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] Ollama HM module
- [ ] openmemory-mcp typed settings
- [ ] Rolling stack workflow skill
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
