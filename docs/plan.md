# nix-agentic-tools Backlog

> Single source of truth for remaining work. Lives on the working
> branch. **Never merges to main** — PR extraction filters it out.
> cspell + treefmt are configured to skip this file.
>
> Ordered by confidence / effort. Easy wins at the top, larger
> initiatives at the bottom. Memory files carry extended context
> where noted — `memory/<name>.md` references are relative to
> `~/.claude/projects/-home-caubut-Documents-projects-nix-agentic-tools/memory/`.

## Current status (2026-04-15)

**nix-update migration complete and pushed.** nvfetcher deleted. All
overlay packages have inline hashes managed by nix-update + ninja
DAG pipeline. Auto-computed versions from source (`overlays/lib.nix`).
CI pipeline restructured and actively running. Update pipeline uses
git worktrees + flock merge for parallel per-package updates.

### Consumer integration (nixos-config) — in progress

Major fixes landed on `refactor/ai-factory-architecture` (not yet on main):

- **claude-code binary fix** — `autoPatchelfHook` corrupted Bun single-exec
  trailer. Replaced with manual `patchelf --set-interpreter` + `makeWrapper`
  for `LD_LIBRARY_PATH`. See `overlays/claude-code.nix`.
- **homeManagerModules.default** — renamed from `.nix-agentic-tools` to
  standard `.default` convention.
- **lib.ai + lib.hm.dag** — each HM module entry point uses `lib.extend` to
  inject these, avoiding chicken-and-egg with `_module.args.lib`.
  `lib/hm-dag.nix` provides a stub for `nix flake check` outside HM context.
- **services.mcp-servers restored** — regression from factory refactor.
  Restored via `packages/mcp-services/` virtual package.
- **github-mcp mcpName passthru** — `pname` is `github-mcp-server` but
  directory is `github-mcp`; added `passthru.mcpName`.
- **Buddy disabled** — upstream removed `/buddy` (anthropics/claude-code#45596).
  User disabled buddy config in nixos-config pending upstream resolution.

### Active investigation: MCP server startup failures

`github-mcp` and `kagi-mcp` show `✘ failed` in Claude Code session startup.
Both servers **work fine when run manually** — the secrets wrappers execute
correctly, the binaries start, and MCP handshake succeeds. The failure is
specific to how Claude Code spawns them.

**What we know:**
- Secret files exist and are readable at `/run/user/1000/secrets/`
- Wrapper scripts (`/nix/store/*-github-mcp-env`, `/nix/store/*-kagi-mcp-env`)
  work correctly when invoked from the shell
- The `.mcp.json` in the HM plugin has correct `command`, `args`, `env` fields
- Other MCP servers (context7, effect, fetch, nixos, sequential-thinking) work
  — but those are HTTP type (connecting to already-running services), not stdio
- `git-mcp` (stdio, no credentials) works
- `aihubmix-mcp` (stdio, credentials, hand-rolled wrapper) status unknown
- The `env` field sets `PYTHONPATH=""` + `PYTHONNOUSERSITE=true` — tested
  manually, doesn't cause issues
- This is a regression — these servers used to work before the factory refactor

**Hypotheses to test next session:**
1. The `type: "stdio"` + `env` + secrets-wrapper combination causes a race
   or timeout during Claude Code's MCP initialization
2. Something in how `programs.claude-code.settings.mcpServers` (factory path)
   vs `programs.claude-code.mcpServers` (direct path) gets rendered differs
3. Claude Code's process spawning handles the wrapper differently (e.g.,
   env replacement vs merge)
4. Check if `aihubmix-mcp` also fails — if yes, it's all secrets wrappers;
   if no, it's the `env` field interaction

---

### Backlog items

> **Design principle: unified transformer pattern.** Every cross-ecosystem
> concern (mcpServers, instructions, skills, agents, lspServers,
> environmentVariables, permissions) uses the same architecture:
> typed option surface at `ai.<concern>` (top-level) + `ai.<cli>.<concern>`
> (per-ecosystem additive, wins on collision), translated at eval time by
> per-ecosystem transformers in `lib/ai/transformers/`. **No ecosystem-specific
> option shapes, no throwaway passthrough wiring** — write typed once, fan
> out everywhere. See `docs/unified-instructions-design.md` for the full
> design (covers instructions; same pattern applies to all concerns).

- [ ] **Unified `ai.context` + `ai.rules` instruction surface** — HIGH priority. Full design in `docs/unified-instructions-design.md`. Add `ai.context` + `ai.rules` top-level and `ai.<cli>.context` + `ai.<cli>.rules` per-ecosystem. Build `lib/ai/transformers/{claude,copilot,codex}.nix` alongside existing `kiro.nix`. Codex 32 KiB eval-time size guard. Migrates consumer's 15 kiro steering files off `mkOutOfStoreSymlink`.
- [ ] **Typed `ai.claude.settings` schema** — LOW priority. Currently `attrsOf anything`; could be an opinionated submodule with known keys (`effortLevel`, `enableAllProjectMcpServers`, `permissions`, `env`, `hooks`, `outputStyle`) + freeformType escape hatch, matching the Kiro pattern. Note: today's HM `inherit (cfg) settings;` is an IDENTITY translation (our schema matches upstream's freeform shape by coincidence). If we move to a typed schema, HM must be refactored to the same hook-routing + gap-write pattern devenv now uses, because our schema would no longer identity-map to upstream's. Separate design pass.
  - *Correction note (2026-04-21):* earlier versions of this backlog listed a standalone "HM translation refactor" bullet. That was incorrect — today's HM code is already a (trivial) translation, not raw inherit. No refactor is needed until the schema diverges from upstream's. Absorbed into this typed-schema bullet.
- [ ] **Typed `ai.claude.plugins` schema** — LOW priority. Same shape/status as `ai.claude.settings`: upstream HM accepts `listOf (either package path)` and our option declares the same, so `inherit (cfg) plugins;` is identity translation. Would only need refactor if we give the option opinionated structure (e.g., per-plugin metadata). Absorbed from an earlier mis-flagged "plugins refactor" bullet.
- [ ] **ai.claude.memory migration** — already supported in mkClaude.nix, consumer just needs to switch from `programs.claude-code.memory.text = builtins.readFile ./path` to `ai.claude.memory = ./path`. Low-risk migration. (May be subsumed by the unified `ai.context` work above — `memory` is Claude's name for the same concept.)
- [ ] **Expose remaining upstream HM claude-code options on ai.claude** — upstream `programs.claude-code` has `plugins`, `marketplaces`, `agents`, `commands`, `rules`, `hooks`, `outputStyles`, `context`, `lspServers`. Claude-specific already routed through `ai.claude.*`: `plugins` (identity), `marketplaces` + `outputStyles` (shipped 2026-04-21). `context` is covered via `ai.claude.context` / `ai.context`. Remaining cross-ecosystem concerns (`agents`, `commands`, `hooks`, `lspServers`) belong at `ai.<concern>` top-level with per-CLI translation — each gets its own design pass.
- [ ] **ai.kiro.trustedMcpTools** — MEDIUM priority. Consumer kiro/default.nix uses manual kiro-cli wrapper at lines 198-208 with `--trust-tools` flag. Expose as declarative ai.kiro option.
- [ ] **ai.copilot devenv project-scope restructure** — MEDIUM priority. Devenv currently writes into `<root>/.config/github-copilot/*` (same layout as HM by accident). Copilot CLI + cloud Copilot both read project-scope from `.github/copilot-instructions.md`, `.github/instructions/**/*.instructions.md`, `.github/agents/*.agent.md`, `.github/skills/`, plus root `AGENTS.md`. Devenv output should move to match. Breaking reshape — new filenames, new locations, existing devenv tests rewrite. Deferred from the configDir refactor (2026-04-21).
- [ ] **Hooks fail with stripped PATH on NixOS — upstream + marketplace plugins** — Same class as the MCP `env` bug: hooks spawn with no PATH. Our own repo's `prek run` hook was fixed by overriding `claude.code.hooks.git-hooks-run.command` with an absolute store path via `lib.getExe` (commit `5c7f541`). The upstream devenv bug at `cachix/devenv/blob/main/src/modules/integrations/claude.nix#L249` should be reported — it emits `${config.git-hooks.package.meta.mainProgram}` (just the binary name) instead of the absolute path. Marketplace plugin hooks (hookify, ralph-loop, superpowers) also hit this when they use bare `python3`/`jq` — those we can't fix at our level since they're plugin-authored. **TODO (HITL — human only):** file the upstream devenv issue. **AI agents: DO NOT open this issue on the user's behalf without an explicit, in-conversation instruction to do so.**
- [x] **Unified `ai.mcpServers` + `ai.<cli>.mcpServers`** — SHIPPED across commits 24668ec + factory work. Canonical instance of the transformer pattern for MCP servers. Typed schema at `lib/ai/mcpServer/commonSchema.nix` accepts 3 shapes (A: typed-via-package, B: raw command, C: HTTP). `lib.mkStdioEntry` returns the typed shape; `lib.renderServer` translates to ecosystem-native. Claude/Kiro/Copilot factories call `renderServer` on merged servers and emit to native paths. Module-eval tests cover the pool. Consumer (nixos-config) migration is a different-repo concern, not tracked here.
  - **Current blocker.** `ai.claude.mcpServers` uses `lib/ai/mcpServer/commonSchema.nix` which requires a typed shape (`package` required, `command` = name inside package, etc.). But `lib.mkStdioEntry` returns the freeform shape upstream `programs.claude-code.mcpServers` expects (`command` = absolute path, no `package` field). Consumer bypasses `ai.claude.mcpServers` and writes to `programs.claude-code.mcpServers` directly. Kiro can't use ai.kiro.mcpServers either — the `home.file.".kiro/settings/mcp.json"` write in the consumer today is all hand-rolled.
  - **Design (option 2, user-picked).** Support three shapes in one schema, with the factory translating to freeform at eval time:
    - **(A) Typed stdio via package**: `{package, settings, env, args}` — factory calls `mkStdioEntry` to render the wrapper + freeform entry. Covers all modules-registered servers (github-mcp, kagi-mcp, context7-mcp, etc.).
    - **(B) Raw pass-through**: `{type="stdio", command=<abs-path>, args, env}` — freeform entry written as-is. Escape hatch for ad-hoc wrappers like aihubmix-mcp.
    - **(C) External HTTP**: `{type="http", url}` — freeform entry for services.mcp-servers outputs and externalServers.
  - **Architecture.**
    - The **typed schema** (`lib/ai/mcpServer/commonSchema.nix`) is the authoritative surface — it's what `ai.mcpServers.<name>` and `ai.<ecosystem>.mcpServers.<name>` accept, and it's what `lib.mkStdioEntry` returns (refactored from its current freeform output). Users can write the typed attrset directly OR use `mkStdioEntry` as a typed-constructor helper.
    - All **rendering** (wrapper script generation, credential snippet, stdio-arg composition from `serverDef.meta.modes.stdio`, env var wiring from the server module) moves OUT of `mkStdioEntry` and into per-ecosystem translators.
    - Each ecosystem's factory owns a `renderServer` that consumes the typed shape and emits the ecosystem-native representation:
      - **Claude**: typed → freeform `{type, command=<abs-path>, args, env}` → `programs.claude-code.mcpServers.<name>`
      - **Kiro**: typed → freeform → `home.file."${cfg.configDir}/settings/mcp.json".text = toJSON {mcpServers = ...;}`
      - **Copilot**: typed → copilot-native surface (TBD)
    - Shared internal helpers (`mkSecretsWrapper`, `mkCredentialsSnippet`, `evalSettings`, `effectiveEnv`, `effectiveArgs`) stay in `lib/mcp.nix` and are called by whichever translator needs them.
  - **Work items.**
    - [ ] Update `lib/ai/mcpServer/commonSchema.nix`: make `package` optional so the three shapes coexist; document discriminator rules (url → http, package → typed stdio, raw command → pass-through).
    - [ ] Refactor `lib.mkStdioEntry` to return the typed schema shape instead of the current freeform output. Keep internal helpers intact.
    - [ ] Add `renderServer` as a shared library helper OR as a method on each ecosystem factory (TBD — probably per-ecosystem since Claude and Kiro have different target shapes).
    - [ ] `mkClaude.nix` HM config: map `mergedServers` through Claude's `renderServer` and write to `programs.claude-code.mcpServers` (top-level, not under settings).
    - [ ] `mkKiro.nix` HM config: map `mergedServers` through Kiro's `renderServer` and write to `home.file."${cfg.configDir}/settings/mcp.json".text`.
    - [ ] `mkCopilot.nix`: same pattern adapted to Copilot's surface.
    - [ ] Update module-eval tests + any consumers of the schema.
    - [ ] Migrate nixos-config consumer: move everything from `programs.claude-code.mcpServers` and `kiro/default.nix`'s `mcp.json` block to `ai.mcpServers` + per-ecosystem additions. Delete consumer's bespoke `mkStdioEntry`-into-freeform wiring.
  - **Why option 2 over option 1 (freeform passthrough).** Option 1 would accept anything and rely on upstream to validate. Option 2 keeps a single typed surface across all ecosystems, enables mkStdioEntry's credential-wrapper and server-module metadata (toolsets, modes, etc.) for all CLIs uniformly, and still has an escape hatch via shape (B) for ad-hoc cases.
- [ ] **mcp-proxy auth metadata for kiro-cli 2.0** — kiro-cli 2.0 (bumped 2026-04-14, commit `557f3d9`) added a strict MCP authorization check on HTTP endpoints. Servers proxied via `mcp-proxy` (i.e., any server with `modes.http = "bridge"` in our schema — currently just sympy-mcp) fail with `No authorization support detected`.
  - **Upstream state (researched 2026-04-16).** sparfenyuk/mcp-proxy doesn't speak the protocol kiro-cli 2.0 checks (MCP authorization spec — OAuth 2.1 + RFC 9728 Protected Resource Metadata via `/.well-known/oauth-protected-resource`).
    - **v0.11.0 PR #128 (merged Oct 2025)** — added auth for mcp-proxy as a CLIENT (outbound to remote MCP servers). Doesn't help inbound.
    - **PR #187 (open, created 2026-04-13)** — adds inbound `--auth-bearer-token` flag. Static Bearer auth only, not OAuth 2.1 / PRM. Even if merged, kiro-cli 2.0 wouldn't accept it.
    - **PRs #58, #108** — older inbound-auth attempts, both stale, unmerged.
    - **No upstream PR for RFC 9728 PRM discovery.** PR #128 author noted it as "could be expanded later" but nobody has implemented it. Months away realistically.
  - **Consumer workaround (current).** Bypass mcp-proxy entirely by running affected servers as stdio directly in the consumer's mcp.json. sympy-mcp is single-consumer (kiro-only) so the bridge added no value anyway. nixos-config switched 2026-04-16.
  - **TODO when upstream lands PRM discovery (or another viable auth):** revert the consumer back to using `services.mcp-servers.servers.sympy-mcp.enable = true` + the inherited HTTP entry. Bump mcp-proxy in this repo. Verify with kiro-cli 2.x. The bridge model is preferable when multiple CLIs share the server (single running process, lower startup overhead).
- [ ] Bun overlay for node-based binaries (port from `nixos-config/overlays/bun-overlay.nix`, publish in `ai.*`)
- [ ] DRY docs base-href rewriting — flake.nix hardcodes `/nix-agentic-tools/options/` for NuschtOS, docs.yml rewrites for previews. Make base configurable so local `nix build .#docs` works without wrong paths. Consider parameterizing the derivation or moving all path rewriting to deployment.
- [ ] Garnix CI exploration — garnix for builds, GHA for orchestration, cachix for distribution (see `memory/project_garnix_exploration.md`)
- [ ] Fragment source linter — verify that every `<!-- Fragment: path -->` comment in generated files points to a source file that exists. Catch stale generated files, missing regen, or deleted sources.
- [ ] End-to-end formatting audit — review all generated content flows to ensure treefmt coverage. Questions: does the flake formatter cover all file types we generate? Are there generated non-markdown files that lack formatters? Should treefmt.nix add formatters for YAML, HTML, or other types? Also: bare-commands check only sees git-tracked files (untracked .nix files bypass it until `git add`) — consider a pre-commit hook version.
- [ ] Commit hook regeneration — pre-commit hook should regenerate instruction files (same as devenv shell entry) and re-stage. DRY with `dev/generate.nix`. May need fingerprint cache to avoid ~2-5s nix build on every commit.
- [ ] Nix doc comments as fragments — extract RFC 145 `/**` comments from `.nix` source files into the fragment pipeline. Custom extractor needed (nixdoc expects flat attrsets, our overlays are functions). See `memory/reference_nix_doc_tooling.md`.
- [ ] overlays/README.md table from nix eval — reflect overlay metadata at eval time, string-interpolate into a fragment. Pattern: infer documentation tables from nix eval data instead of hand-maintained markdown. overlays/README.md is the first candidate.
- [ ] Ecosystem-specific instructions in fragment comments — Claude transform injects `<!-- This file is generated. Edit the source fragment. -->` or similar. Research how other projects handle generated-but-committed file instructions.
- [ ] Code→markdown reflection pattern — general approach for inferring documentation from nix eval data instead of hand-maintained markdown. overlays/README.md is the first candidate.

### Update pipeline improvements


---

## Architecture summary

Factory rollout + ideal-architecture gate COMPLETE (2026-04-08/09).
All 24 binary packages under `pkgs.ai.*`. Factory primitives at
`lib/ai/app/{mkAiApp,hmTransform,devenvTransform}.nix`. Three CLI
factories absorbed full fanout:
- Claude: delegates to upstream `programs.claude-code.*` (HM) /
  `claude.code.*` (devenv) + gap writes; buddy activation ported
- Copilot: direct writes (no upstream); wrapper + env + agents + lsp
- Kiro: direct writes (no upstream); wrapper + env + agents + hooks + lsp + steering

Stacked-workflows absorbed as a plain module in
`packages/stacked-workflows/modules/homeManager/`. `modules/` tree
deleted. `devenv.nix` swapped to factory barrel. `nix flake check`
+ `nix build .#docs` + `devenv shell` green.

For full architecture details see `memory/project_factory_architecture.md`.
For known gaps and open questions see `memory/project_factory_known_gaps.md`.

Backup branches (DO NOT GC):
- `archive/phase-2a-refactor` at `cdbd37a`
- `archive/sentinel-pre-takeover` at `55371a9`

---

## Easy wins / light cleanup

High confidence, small scope. Good for review sessions.



- [ ] **Convert remaining 6 from-scratch overlays to nixpkgs
      overrides** — same pattern as context7-mcp. Override nixpkgs
      derivation with inline GitHub source, compute dep hashes.
      Match build tool to source (e.g., pnpm lockfile → pnpm
      build, not npm). Strip `allowUnfree` where not needed.
      Packages: fetch-mcp (`mcp-server-fetch`), github-mcp
      (`github-mcp-server`), git-mcp (`mcp-server-git`),
      git-revise (`git-revise`), mcp-language-server
      (`mcp-language-server`), mcp-proxy (`mcp-proxy`).

- [ ] **Audit all overlay source + build tools against upstream** —
      MANUAL USER REVIEW REQUIRED. For each package, verify:
      (a) source fetches from GitHub (not npm/PyPI) unless no
      GitHub source exists (flag to user), (b) build tool matches
      source lockfile (pnpm lockfile → pnpm build, not npm),
      (c) allowUnfree stripped unless actually needed. For packages
      NOT in nixpkgs, prefer GitHub source with releases over
      registry tarballs. User will inspect each one.



- [ ] **Cachix/substituter override warnings for consumers** — warn
      when a consumer overrides this flake's nixpkgs or other inputs,
      causing cachix cache misses. If cachix is not in substitutors,
      warn about available prebuilt binaries. Only warn if cachix is
      configured but inputs are overridden (not if cachix is absent
      entirely). Warnings only, never break builds. Optionally provide
      a way to disable warnings. Tricky across module systems
      (HM, devenv, overlay-only).

- [ ] **Migrate git-branchless from custom overlay to upstream flake
      input** — consume `inputs.git-branchless.overlays.default`
      instead of standalone `overlays/git-tools/git-branchless.nix`.
      Thin wrapper for Rust 1.88.0 pin + versionCheckHook strip
      (needed until arxanas/git-branchless#1585 is fixed upstream).
      Remove from nix-update matrix, update via `nix flake update
      git-branchless`. Flake input already added. Design written up in
      a prior spec (deleted during backlog consolidation).

- [ ] **Clean up `lib/options-doc.nix` stubs** — consolidate ad-hoc
      stub extensions from Tasks 3-6.

- [ ] **Verify cspell project-terms.txt** — audit for stale terms.

- [ ] **Update AI instruction fragments with architecture decisions**
      — small decisions made during implementation should be codified
      into dev fragments so they fan out to all ecosystems. Decisions
      to document:
      - Overlay source pattern: inline GitHub source + hash, nix-update
        pipeline, nixpkgs overrides with fetchPnpmDeps/finalAttrs
      - overlay grouping: `pkgs.ai.{mcpServers,lspServers}` +
        `pkgs.gitTools`, agnix mainProgram overrides
      - factory composition: mkAiApp record + hmTransform/devenvTransform
        (see `memory/project_factory_architecture.md`)
      - Claude delegation model: upstream programs.claude-code.* for
        HM capabilities, direct writes for gaps
      - Unfree guard pattern: `ensureUnfreeCheck` wraps unfree packages
        via `final.symlinkJoin` with `meta` so consumer's allowUnfree
        is respected while ourPkgs cache-hit parity is preserved. Novel
        pattern not seen elsewhere in Nix ecosystem. Document heavily:
        why it exists, how it works, the eval-time-only nature of the
        unfree check, the symlinkJoin wrapper mechanics, CI implications.
        (see `memory/project_unfree_guard_pattern.md`)
      - Flake-first source preference: if upstream repo has a nix flake
        that outputs the package (not just devShell), add it as a flake
        input and consume `inputs.<name>.packages.${system}.default`.
        Let upstream own their build. Inline source + overlay is for
        packages without flakes or where we override nixpkgs.
      - Build tool must match source: if source has pnpm-lock.yaml,
        build with pnpm (not npm). If source has Cargo.lock, build
        with cargo. Don't force a different tool than what upstream
        uses.


- [ ] **Replace `isRoot = package == "monorepo"` with category
      metadata** — `mkDevComposed` hardcodes a string match. Should
      be explicit category metadata (e.g.,
      `{ includesCommonStandards = true; }`).

- [ ] **Add scope→fragment map to the self-maintenance directive** —
      the always-loaded `dev/fragments/monorepo/architecture-fragments.md`
      doesn't tell sessions which fragment covers which scope.
      Hand-maintain a table or generate from `packagePaths`.

- [ ] **Include commit subject in Last-verified markers** — extend
      the `Last verified:` format across all fragments.

- [ ] **Move `externalServers` registry out of root `flake.nix`** —
      extract to `lib/external-servers.nix` or a content package.
      Currently `lib.externalServers.aws-mcp` is hand-defined inline.


- [ ] **Rename `devshell/` → `modules/devshell/`** — top-level
      splits modules across `lib/`, `devshell/`, and per-package
      `modules/`. Move `devshell/` for layout consistency. Flagged on
      PR #4 review. Note: `modules/` directory was just deleted in
      A10 — a fresh `modules/devshell/` for the standalone devshell
      would be its own concern, not confused with the old HM tree.

---

## Medium effort

Moderate confidence, needs some investigation or design.

- [ ] **Single source of truth for tool exclude lists** — cspell.json,
      devenv.nix cspell excludes, treefmt.nix excludes all duplicate.
      Build a single Nix attrset with file categories (generated
      published docs → spell YES format NO; plan docs → spell NO
      format NO; tool artifacts → both NO). Each tool config reads
      the category intersection it cares about. See detailed writeup
      in `memory/project_factory_known_gaps.md` open question #6.

- [ ] **Extend `sharedOptions.nix` with `ai.lspServers` +
      `ai.environmentVariables`** — currently per-app only (DRY loss
      between copilot and kiro). The legacy `modules/ai/default.nix`
      had these as cross-ecosystem shared options. Extending
      `sharedOptions.nix` is mechanically the same as the existing
      `ai.skills` / `ai.instructions` / `ai.mcpServers` pattern.
      See `memory/project_factory_known_gaps.md` open question #1.

- [ ] **Consolidate fragment enumeration into single metadata table**
      — `devFragmentNames`, `packagePaths`, and `flake.nix`'s
      `siteArchitecture` all hand-list the same fragments. Extract a
      single `fragmentMetadata` attrset in `dev/generate.nix`.

- [ ] **HM ↔ devenv ai module parity test** — add a parity-check
      eval test in `checks/module-eval.nix` that evaluates both HM
      and devenv modules with equivalent config and spot-checks that
      option paths match.

- [ ] **Copilot CLI integration test** — the factory port (Tasks 4+4b)
      landed without a real consumer driving it. Write an integration
      test: scratch HM profile with `ai.copilot.enable = true` + concrete
      config, `home-manager build`, assert on-disk tree matches expected
      layout + wrapper injects `--additional-mcp-config` flag. See
      detailed writeup in plan commit `3332b2c`.

- [ ] **Kiro CLI integration test** — same as copilot, verify kiro
      factory output matches expected `.kiro/` directory layout,
      steering YAML frontmatter uses array form for `fileMatchPattern`.

- [ ] **Claude-code wrapper env vars** — set `DISABLE_AUTOUPDATER=1`
      and `DISABLE_INSTALLATION_CHECKS=1` defensively in the Bun
      wrapper. Design decision: always-on vs overridable via settings.

- [ ] **AI.skills stacked-workflows special case** — currently
      consumers need to enable stacked-workflows AND set `ai.skills`
      separately. Augment to support a single-line
      `stacked-workflows.enable = true` that pulls SWS skills into
      every enabled ecosystem via `ai.skills`.

- [ ] **Codify gap: ai.skills factory layout** — create a new scoped
      architecture fragment documenting the post-factory skills fanout
      pattern (each factory writes its own skill dirs directly from
      config callbacks). Source: `memory/project_ai_skills_layout.md`.

- [ ] **Codify gap: devenv files internals** — create a new scoped
      architecture fragment. Source:
      `memory/project_devenv_files_internals.md`.

- [ ] **GitHub Pages `docs.yml` workflow** — not yet wired. Base path
      fixes for preview branches also deferred.

- [ ] **Fragment assembler source-path comments** — when `compose`
      produces a final file, inject HTML comments naming the source
      fragments. Helps reviewers audit generated files. Implementation
      lives in `lib/fragments.nix compose`.

---

## Larger initiatives

Lower confidence or broader scope. Needs design/brainstorming.

### nixos-config integration

Goal: consumer fully ported to the `ai.*` factory surface.

- [ ] Wire nix-agentic-tools flake input into nixos-config
- [ ] Migrate AI config blocks to `ai.*` (from direct `programs.*` blocks)
- [ ] End-to-end verification: `home-manager switch` on real consumer
- [ ] Remove vendored AI packages from nixos-config
- [ ] Ollama ownership decision (host-specific vs reusable)
- [ ] Update flake input pin (currently at `f341bcb`, pre-factory)
      — note `pkgs.nix-mcp-servers.*` namespace dissolved in M5,
      `github-copilot-cli` renamed to `copilot-cli` in M4. Consumer
      migration needed. See `memory/project_nixos_config_integration.md`.

### Re-chunk for main merge

Not this week. Start fresh when ready.

- [ ] Stack new branch from main tip
- [ ] Cherry-pick or rebase factory commits into PR-sized chunks
- [ ] Copilot auto-review on each PR (repo already configured)
- [ ] Verify CI green on each chunk

### Add OpenAI Codex (4th ecosystem)

Blocked on factory shape being stable and verified by nixos-config.

- [ ] Package chatgpt-codex CLI under `packages/chatgpt-codex/`
- [ ] Add codex transformer under `lib/ai/transformers/`
- [ ] Wire factory into module barrel via `collectFacet`

### Doc site

- [ ] NuschtOS options browser gaps (All-scope blending, dark mode,
      packages indexing). See `memory/project_nuschtos_search.md`.
- [ ] Generate CONTRIBUTING.md from fragments
- [ ] Consumer migration guide
- [ ] Document binary cache for consumers
- [ ] ADRs for key decisions
- [ ] Introduction → Contributing link in mdbook
- [ ] Soften agent-directed language in docsite fragment copies

### Agentic tooling

- [ ] Drift detection agent/skill set (generated files, upstream
      versions, option surface, cross-config parity)
- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, cross-references)

### CI

- [ ] Revert `ci.yml` branch trigger to `[main]` only (after merge)
- [ ] Remove `update.yml` push trigger, keep schedule + dispatch
- [ ] CUDA build verification
- [ ] Review cachix push strategy
- [ ] **Split CI into update + build workflows** —
      Current: single `update.yml` runs full pipeline (update → build → commit)
      on every push to feature branch. Target: `update.yml` on main schedule
      opens PR with updated sources+hashes; `build.yml` triggers on PR open,
      builds per-platform, pushes to cachix. The three-job structure already
      maps to this split. Blocked on: merging to main + stable CI.

---

## Unsorted backlog

Items preserved from previous sessions. May need triage.

- [ ] **Claude-code npm→binary migration + buddy salt patching** —
      Anthropic soft-deprecated npm 2026 in favor of Bun-compiled
      single-exec from GPG-signed manifest. Migration uses the same
      binary-fetch pattern as kiro-cli (inline source + per-platform
      `sources.json`). Buddy patching requires extracting/modifying
      embedded JS inside the Bun single-exec binary's `.bun` ELF
      section (Linux) or `__BUN,__bun` Mach-O section (macOS).

      **Preferred approach (option 2): same-length in-place binary patch.**
      The buddy salt is a fixed 15-byte marker (`friend-2026-401`).
      The Bun module graph payload has NO checksums or signatures —
      locate the salt bytes in the embedded `cli.js` contents via
      the `StandaloneModuleGraph` format (trailer `"\n---- Bun! ----\n"`
      → Offsets struct → CompiledModuleGraphFile[] → StringPointer to
      contents), overwrite in-place, re-codesign on macOS. No pointer
      or offset changes needed for same-length replacement.

      Existing tooling: `lafkpages/bun-decompile` (TypeScript,
      handles old/new format), `@shepherdjerred/bun-decompile` (npm).
      Could also write a minimal Nix-native extractor since the format
      is well-documented (48-byte Offsets struct + 28-byte per-module
      metadata).

      If bytecode is present for the patched module, strip the
      StringPointer (zero it) — Bun falls back to source parsing.

      **Deep technical reference:** `memory/reference_bun_binary_patching.md`

      **Monitoring signal:** check `@anthropic-ai/claude-code` npm
      publish frequency. If Anthropic stops npm while native channel
      keeps updating, that's the trigger.

      **Touch points:** claude-code.nix (buildNpmPackage → binary
      fetch), per-platform sources.json, claude-code-buddy module,
      buddy-customization.md, delete claude-code-package-lock.json
- [ ] Agentic UX: pre-approve nix-store reads for HM-symlinked skills
- [ ] Richer markdown fragment system: heading-aware merging
- [ ] LLM-friendly inline code commenting conventions fragment
- [ ] `outOfStoreSymlink` helper for Claude's `~/.claude/projects`
- [ ] SecretSpec for MCP credentials
- [ ] cclsp — Claude Code LSP integration
- [ ] claude-code-nix review (github.com/sadjow/claude-code-nix)
- [ ] cspell permissions wired via `ai.*`
- [ ] devenv feature audit (tasks, services, process dependencies)
- [ ] filesystem-mcp package + wire to devenv
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion (code review, security, testing presets)
- [ ] Logo refinement
- [ ] MCP processes for `devenv up` (no-cred servers)
- [ ] Module fragment exposure (servers contributing own fragments)
- [ ] Ollama HM module (if ownership decision keeps it here)
- [ ] `scripts/update` auto-discovery
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp packaging
- [ ] openmemory-mcp typed settings + missing option descriptions
- [ ] `stack-plan` skill: missing git restack after autosquash
- [ ] Rolling stack workflow skill
- [ ] claude-code build approach consumer docs
- [ ] Declutter root dotfiles
- [ ] Fragment metadata consolidation follow-up (see also: Medium effort "Consolidate fragment enumeration")
- [ ] Document hm-modules / claude-code scope overlap (moot post-buddy-absorption)
