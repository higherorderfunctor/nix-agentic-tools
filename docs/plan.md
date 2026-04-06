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

### Test

- [ ] Review docs site (`devenv up docs` — opens browser automatically)
- [ ] Wire nix-agentic-tools into nixos-config: HM global + devshell per-repo
- [ ] Review docs accuracy against actual consumer experience
- [ ] Fix any doc gaps found during integration testing

---

## Solo (no external deps — can run autonomously)

### CI & Automation

- [ ] `ci.yml` — `devenv test` + package build matrix + cachix push
- [ ] `update.yml` — daily nvfetcher update pipeline
- [ ] Binary cache: `hof-nix-agentic-tools` cachix setup
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

Phase 2 — DRY audit fixes + fragment consolidation:

- [ ] Generate CLAUDE.md from fragments (gitignore, stop hand-maintaining)
      Currently 71% duplicated from fragments. Compose all fragments +
      append CLAUDE-specific sections (Nix standards, Change Propagation,
      Naming Conventions, Linting) as additional fragments or local text
- [ ] Add missing `tooling-preference` fragment to CLAUDE.md generation
      (MCP > CLI > web, treefmt after edits — in AGENTS.md but not CLAUDE)
- [ ] Consolidate routing-table fragment duplication:
      `dev/fragments/stacked-workflows/routing-table.md` and
      `packages/stacked-workflows/fragments/routing-table.md` are
      byte-identical — single source + symlink or build copy
- [ ] Extract CLAUDE-specific sections as new fragments:
      `nix-coding-standards`, `change-propagation`, `naming-conventions`,
      `linting` — so they can be composed into CLAUDE.md and potentially
      shared with other targets

Phase 3 — `packages/fragments-docs/` + generated doc site:

- [ ] `packages/fragments-docs/` — doc site topic package
      passthru.transforms: `{ page, section, table, withOptions }`
      passthru.generators: `{ optionsPage, packageTable, serverList }`
- [ ] Generate `docs/src/**` from fragments (gitignore entire dir)
      Shared fragments render to both instruction files AND doc pages
      via different transforms. Same source of truth, multiple targets.
- [ ] Generate README.md from fragments + nix-evaluated data
      (committed — front door file; re-generated on `nix run .#generate`)
      Package tables, server lists, skill matrices derived from overlays
- [ ] Generate CONTRIBUTING.md from fragments (committed — front door)
- [ ] Wire `devenv up docs` to: generate source → mdbook serve watches it
- [ ] Inject nix-evaluated data via transform closures: overlay package
      tables, MCP server lists, supported CLIs — derived from actual
      attrsets, not hand-maintained

Phase 4 — Options browser & heavy content:

- [ ] `nixosOptionsDoc` for HM and devenv modules → generated markdown
      (279 options, ~2-4s build, must be pre-generated not inline)
- [ ] Add NuschtOS/search as static client-side options browser
      (no backend, scopes for HM/devenv/MCP options)
- [ ] Pagefind post-build indexing for enhanced full-text search
      (already in devenv packages)

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
- [ ] Docs favicon — not loading or never configured in book.toml
- [ ] GitHub Pages deploy workflow
- [ ] SecretSpec — declarative secrets for MCP credentials

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
- [ ] Module fragment exposure — MCP servers contributing own fragments
- [ ] Ollama HM module
- [ ] scripts/update → devenv task or script — integrate into devenv so
      `devenv run update` works; remove standalone bash script
- [ ] scripts/update auto-discovery — derive which hashes to update from
      the nix files themselves (scan for npmDepsHash/vendorHash/cargoHash in
      hashes.json, match to package names). Eliminates hardcoded package
      lists in the script. Could also use a fragment/instruction so adding
      a new overlay package automatically updates the update script.
- [ ] Shell linters (shellcheck, shfmt) when shell scripts exist
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp
- [ ] openmemory-mcp typed settings
- [ ] Rolling stack workflow skill
