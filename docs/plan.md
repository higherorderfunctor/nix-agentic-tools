# nix-agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Branch: `sentinel/monorepo-plan`

## Architecture

- **Standalone devenv CLI** for dev shell (not flake-based)
- **Top-level `ai`** namespace for unified config (HM and devenv)
- **Config parity** — lib, HM, and devenv must align in capability
- **Content packages** — published content (skills, fragments) lives in
  `packages/` as derivations with passthru for eval-time composition
- **Topic packages** — each topic bundles content (derivation) + API
  (passthru transforms/functions). Core fragment lib stays in `lib/`
  (pure functions, no content). Topic packages (`fragments-ai`,
  `fragments-docs`) carry templates + transforms together
- **Pure fragment lib** — `lib/fragments.nix` provides compose,
  mkFragment, render; target-agnostic core. `render` takes a
  transform lambda (`fragment -> string`) supplied by topic packages
- **treefmt** via devenv built-in module (replaced dprint)
- **devenv MCP** uses public `mcp.devenv.sh` (local Boehm GC bug)

---

## Next Session

### HITL Integration

- [ ] Wire nix-agentic-tools into nixos-config: HM global + devshell per-repo
- [ ] Review docs accuracy against actual consumer experience
- [ ] Fix any doc gaps found during integration testing

---

## Solo (no external deps — can run autonomously)

### CI & Automation

- [x] `ci.yml` — `devenv test` + package build matrix + cachix push
      2-arch matrix (x86_64-linux, aarch64-darwin). Cachix upstream
      dedup handles nixpkgs paths automatically.
- [x] `update.yml` — daily nvfetcher update pipeline (devenv tasks)
- [x] Binary cache: `nix-agentic-tools` cachix setup (50G plan)
- [ ] Revert `ci.yml` branch trigger to `[main]` only (after sentinel merge)
- [ ] Review CI cachix push strategy — currently pushes on every build
      which speeds up subsequent runs via cache hits. May be fine as-is
      since upstream dedup avoids storage waste. Re-evaluate if cache
      size becomes a concern
- [ ] Remove `update.yml` push trigger, keep schedule + workflow_dispatch only
- [ ] Document binary cache for consumers (blocked on docs rewrite)
- [ ] After cachix: remove flake input overrides in nixos-config
      (currently needed because no binary cache — builds from source)

### Apps & Structural Checks

- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, nvfetcher keys, module imports)

### Generated Docs & Fragment Refactor

Phase 1 — Fragment core FP refactor: **DONE**

- [x] Refactor `lib/fragments.nix`: replace `mkEcosystemContent` with
      generic `render { composed, transform }`
- [x] Create `packages/fragments-ai/` with curried transforms
- [x] Migrate all callers (flake.nix, devenv.nix, 3 modules, ai-common)
- [x] Verify byte-identical instruction file output

Phase 2 — DRY audit fixes + fragment consolidation: **DONE**

- [x] Generate CLAUDE.md from fragments (gitignored)
- [x] Consolidate routing-table fragment duplication
- [x] Extract CLAUDE-specific sections as new dev fragments

Phase 3a — Instruction task migration: **DONE**

- [x] Extract composition to `dev/generate.nix` (single source of truth)
- [x] Instruction derivations in flake.nix (nix store cached)
- [x] `generate:instructions:*` devenv tasks
- [x] Remove `files.*` instruction generation + `apps.generate`
- [x] Byte-identical output verified
- [x] Architecture steering fragment added

Phase 3b — Repo doc generation: **DONE**

- [x] README.md generated from fragments + nix data (committed)
- [ ] Generate CONTRIBUTING.md from fragments (committed — front door)

Phase 3c — Doc site generation: **DONE**

- [x] `packages/fragments-docs/` with dynamic generators
- [x] Prose moved to `dev/docs/`, `docs/src/` gitignored
- [x] `docs-site-{prose,snippets,reference}` derivations
- [x] `generate:site:*` devenv tasks + `generate:all` meta
- [x] `devenv up docs` generates before serving
- [x] `{{#include}}` snippets: credentials, AI mapping, skill table,
      routing table, overlay table, CLI table
- [x] Dynamic generators: overlay packages, MCP servers from nix data
- [x] Removed static fallback pages (home-manager, devenv, mcp-servers)

Phase 4 — Options browser & heavy content: **DONE**

- [x] `nixosOptionsDoc` for HM (281 options) and devenv (64 options)
- [x] NuschtOS/search static client-side options browser (HM + devenv scopes)
- [x] Pagefind post-build full-text search indexing

Generated file policy:

| File              | Generated       | Committed     | Reason                          |
| ----------------- | --------------- | ------------- | ------------------------------- |
| CLAUDE.md         | fragments       | gitignored    | devenv generates on shell entry |
| AGENTS.md         | fragments       | gitignored    | devenv generates on shell entry |
| README.md         | fragments + nix | **committed** | front door for repo visitors    |
| CONTRIBUTING.md   | fragments       | **committed** | front door                      |
| docs/src/\*\*     | fragments + nix | gitignored    | built artifact, GH Pages        |
| .claude/rules/\*  | fragments       | gitignored    | devenv generates                |
| .github/\*        | fragments       | gitignored    | devenv generates                |
| .kiro/steering/\* | fragments       | gitignored    | devenv generates                |

### Documentation & Guides

- [ ] CONTRIBUTING.md — dev workflow, package patterns, module patterns,
      `devenv up docs` for docs preview, `devenv up` process naming
- [ ] Consumer migration guide — replace vendored packages + nix-mcp-servers
- [ ] ADRs for key decisions (standalone devenv, fragment pipeline, config parity)
- [x] Docs favicon — configured in book.toml
- [x] GitHub Pages deploy workflow (docs.yml with per-branch previews)
- [ ] SecretSpec — declarative secrets for MCP credentials
- [ ] Declutter root dotfiles — move `.cspell/`, `.nvfetcher/`,
      `.agnix.toml` to `config/` or `dev/` using tool config path
      overrides (all three support custom paths)
- [x] Document binary cache for consumers — in getting-started guides

---

## HITL (requires nixos-config or interactive testing)

### Consumer Integration

- [ ] Add `inputs.nix-agentic-tools` to nixos-config with follows
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
- [ ] claude-code-nix review — audit github.com/sadjow/claude-code-nix for
      features to adopt. Bun runtime interesting if faster than native Node
- [x] claude-code.withBuddy — passthru function on claude-code package
      that binary-patches the buddy salt at build time. Two-derivation
      split: mkBuddySalt (cached, expensive) + withBuddy (cheap byte
      replacement). HM + devenv `ai.claude.buddy` option with full
      enum types. Ref: github.com/cpaczek/any-buddy
- [ ] CONTRIBUTING.md refinement — review with maintainer, expand sections
- [ ] copilot-cli/kiro-cli DRY — 7 helpers copy-pasted between modules
- [ ] cspell permissions — wire via `ai.*` permissions so all ecosystems
      get cspell in Bash allow rules (not Claude-specific)
- [ ] devenv feature audit — explore underused devenv features (tasks,
      services, process dependencies, readiness probes, env vars, containers,
      `devenv up` process naming) for potential adoption
- [ ] filesystem-mcp — package + wire to devenv; may reduce tool approval
      friction for file operations
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion — new presets (code review, security, testing)
- [ ] HM/devenv modules as packages — research NixOS module packaging
      patterns; would allow `pkgs.agentic-modules.ai` etc. for FP composition
- [ ] Logo refinement — higher quality SVG or larger PNG, crisp at all sizes
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] MCP server submodule DRY — duplicated in devenv copilot/kiro modules
- [ ] Module fragment exposure — MCP servers contributing own fragments
- [ ] Ollama HM module
- [ ] scripts/update auto-discovery — derive which hashes to update from
      the nix files themselves (scan for npmDepsHash/vendorHash/cargoHash in
      hashes.json, match to package names). Eliminates hardcoded package
      lists in the script. Could also use a fragment/instruction so adding
      a new overlay package automatically updates the update script.
- [x] Shell linters (shellcheck, shfmt) — added to devenv git hooks
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] openmemory-mcp typed settings + missing option descriptions (11 attrTag variants)
- [ ] stack-plan: missing git restack after autosquash fixup pattern
- [ ] Repo review re-run — DRY + FP composition audit of fragment system,
      generation pipeline, and doc site. Verify no duplication crept back
      in during rapid iteration. Use /repo-review with fragment focus.
      Also codify patterns for local agentic development: nightly packaging
      via nvfetcher, split-platform sources, overlay composition, fragment
      authoring, generation task structure. Ensure dev fragments capture
      all patterns so new sessions have full context.
- [ ] Rolling stack workflow skill
- [ ] claude-code build approach docs — thoroughly document how our
      claude-code package differs from upstream nixpkgs: Bun runtime
      wrapper (not Node), buddy state at $XDG_STATE_HOME, withBuddy
      removal, cli.js writable copy, fnv1a vs wyhash hash routing.
      Consumer-facing docs explaining what they get vs upstream.
- [ ] **ai.claude.\* full passthrough** — architectural gap: ai.claude
      currently only exposes `enable`, `package`, and `buddy`. The
      intent is that ai.claude.\* mirrors EVERY option from
      programs.claude-code.\*, so consumers don't need to drop down
      to programs.claude-code for anything. Same for ai.copilot and
      ai.kiro vs their respective programs.\* modules. Missing options
      from real-world consumer config (nixos-config claude/default.nix)
      include at minimum: - `ai.claude.memory.text` (CLAUDE.md global instructions) - `ai.claude.skills` (per-Claude skills, separate from
      cross-ecosystem `ai.skills`) - `ai.claude.mcpServers` (Claude-only MCP entries + explicit
      inclusion list from services.mcp-servers) - `ai.claude.settings.*` (effortLevel, permissions,
      enableAllProjectMcpServers, enabledPlugins, etc.) - `ai.claude.plugins` (marketplace plugin install — needs
      new abstraction over current activation script pattern)
      Approach: rather than enumerating every option, consider a
      generic passthrough mechanism (submodule with freeformType
      pointing at the upstream module's option set). The existing
      cross-ecosystem options (ai.skills, ai.instructions,
      ai.lspServers, ai.settings.{model,telemetry}) stay as
      convenience layers that fan out to multiple ecosystems
- [ ] outOfStoreSymlink helper for runtime state dirs — Claude writes
      ~/.claude/projects mid-session, can't use regular HM files.
      Document the outOfStoreSymlink pattern or wrap as an option
      (ai.claude.persistentDirs)
- [ ] Secret scanning — integrate gitleaks into pre-commit hook or CI.
      Currently clean (406 commits verified 2026-04-06). Wire via
      git-hooks.hooks in devenv or as a CI step in ci.yml
