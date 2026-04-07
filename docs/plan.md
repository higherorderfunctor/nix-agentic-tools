# nix-agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Branch: `sentinel/monorepo-plan`

## Authoring notes

Pre-commit runs cspell over this file. When writing backlog entries,
avoid strings that trip the spellchecker on every commit:

- **No literal Nix store hashes.** Use `<HASH>-<name>-<version>` or
  `/nix/store/...-name-version` as placeholders. Real 32-char base32
  store hashes will always contain novel letter runs cspell flags.
- **No raw narinfo URLs.** Describe the path
  (`cachix.org/<hash>.narinfo`) or add the word to
  `.cspell/project-terms.txt` once and reuse.
- **Jargon goes in `.cspell/project-terms.txt`**, not the prose.
  Words like `narinfo` should be added to the allowlist the first
  time they appear. Keep the list alphabetical.

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
- [ ] **Overlays must instantiate their own pkgs from `inputs.nixpkgs`
      so cachix substituters actually serve compiled packages**

  ### Problem

  Every compiled overlay package in this repo currently builds against
  the **consumer's** nixpkgs/rust-overlay/etc. when the overlay is
  composed into a downstream flake. CI builds them standalone against
  this repo's pinned `inputs.nixpkgs` and pushes to
  `nix-agentic-tools.cachix.org`. The two store paths differ because
  rustc/glibc/openssl/python/nodejs/go-toolchain/build-helpers come
  from different nixpkgs revs. Result: cache miss on every consumer
  rebuild even though the cachix substituter is wired up correctly.

  Real-world surfaced 2026-04-06 when nixos-config consumed
  `inputs.nix-agentic-tools.overlays.default` after the overlay swap
  to use the full overlay (not just `ai-clis`). git-branchless forced
  a local Rust compile despite `nix-agentic-tools.cachix.org` being
  in `nix.settings.substituters`. Verified by computing both store
  paths and querying narinfo:
  - Standalone (this repo, `nix eval --raw .#git-branchless`):
    `/nix/store/<HASH_A>-git-branchless-0.10.0`
    → `curl cachix.org/<HASH_A>.narinfo` → **HTTP 200**
  - Consumer (nixos-config, eval via `import nixpkgs { overlays = ...; }`):
    `/nix/store/<HASH_B>-git-branchless-0.10.0`
    → narinfo lookup against all known caches → **HTTP 404 everywhere**

  This is the consequence of commit `e5406977` ("drop input follows
  that defeat cachix substituters") — cachix substituters require this
  repo's inputs to be a closed closure independent of consumers. The
  deliberate trade-off was accepted: consumers get TWO nixpkgs in their
  /nix/store (theirs + ours, mostly content-addressed dedup), flake.lock
  grows, but cache hits work. The current overlay code only completes
  HALF of that decision: cargoHash/src/version are pinned to this repo's
  nvfetcher data, but the build infrastructure (rustc, build helpers,
  base derivations) borrows from the consumer. Need to commit fully.

  ### Fix pattern

  Each compiled overlay package must instantiate `ourPkgs` from
  `inputs.nixpkgs` (with whatever sub-overlays it needs from
  `inputs.rust-overlay` etc.) and use `ourPkgs` for ALL build inputs
  AND the base derivation. The overlay function signature still
  receives `final`/`prev` from the consumer (overlay protocol
  requirement), but only uses `final.system` to know the platform.

  Threading: `inputs` is currently passed to the top-level overlay
  composition functions (e.g. `packages/git-tools/default.nix:5`
  takes `{inputs, ...}`), but is NOT threaded down to per-package
  overlay files. The fix requires threading `inputs` (or at minimum
  `inputs.nixpkgs` and `inputs.rust-overlay`) into each per-package
  function.

  Example transformation for `packages/git-tools/git-branchless.nix`:

  ```nix
  # BEFORE — uses consumer's pkgs for everything except src/cargoHash
  sources: final: prev: let
    nv = sources.git-branchless;
    rust = final.rust-bin.stable."1.88.0".default;
    rustPlatform = final.makeRustPlatform { cargo = rust; rustc = rust; };
  in {
    git-branchless = prev.git-branchless.override (_: {
      rustPlatform.buildRustPackage = args:
        rustPlatform.buildRustPackage (finalAttrs: let
          a = (final.lib.toFunction args) finalAttrs;
        in a // {
          version = final.lib.removePrefix "v" nv.version;
          inherit (nv) src cargoHash;
          postPatch = null;
        });
    });
  }

  # AFTER — instantiates ourPkgs internally, uses it for everything
  {inputs}: sources: final: _prev: let
    ourPkgs = import inputs.nixpkgs {
      inherit (final) system;
      overlays = [(import inputs.rust-overlay)];
      config.allowUnfree = true;
    };
    nv = sources.git-branchless;
    rust = ourPkgs.rust-bin.stable."1.88.0".default;
    rustPlatform = ourPkgs.makeRustPlatform { cargo = rust; rustc = rust; };
  in {
    git-branchless = ourPkgs.git-branchless.override (_: {
      rustPlatform.buildRustPackage = args:
        rustPlatform.buildRustPackage (finalAttrs: let
          a = (ourPkgs.lib.toFunction args) finalAttrs;
        in a // {
          version = ourPkgs.lib.removePrefix "v" nv.version;
          inherit (nv) src cargoHash;
          postPatch = null;
        });
    });
  }
  ```

  Note: `final.system` is still used to discover platform; everything
  else is `ourPkgs.X`. The result is a derivation whose closure traces
  back entirely to `inputs.nixpkgs` (this repo's pin), not the
  consumer's. Store path is byte-identical to `nix build .#git-branchless`
  run from this repo standalone → cache hit.

  ### Threading inputs into per-package files

  `packages/git-tools/default.nix` currently:

  ```nix
  {inputs, ...}: let
    withSources = overlayPaths: final: prev: let
      sources = import ./sources.nix { inherit (final) fetchurl ...; };
      applyOverlay = path: (import path) sources final prev;  # ← no inputs
    in lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);
  in
    lib.composeManyExtensions [
      inputs.rust-overlay.overlays.default
      (withSources localOverlays)
    ]
  ```

  Update `applyOverlay` to pass `inputs` and drop the top-level
  `inputs.rust-overlay.overlays.default` (since each package now
  applies it internally to its own ourPkgs):

  ```nix
  {inputs, ...}: let
    withSources = overlayPaths: final: prev: let
      sources = import ./sources.nix { inherit (final) fetchurl ...; };
      applyOverlay = path: (import path) {inherit inputs;} sources final prev;
    in lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);
  in
    withSources localOverlays
  ```

  Same threading change applies to `packages/mcp-servers/default.nix`
  (already has the `{inputs, ...}` pattern via `callPkg` for some
  packages — needs to be applied to ALL).

  ### Files to modify (audit completed 2026-04-06)

  **packages/git-tools/** — every package builds Rust or Python:
  - `default.nix` — thread `inputs` into per-package overlays; drop
    top-level `inputs.rust-overlay.overlays.default` (now per-package)
  - `git-absorb.nix` — Rust, uses `final.rust-bin.stable.latest.default`
  - `git-branchless.nix` — Rust, pinned to 1.88.0
  - `git-revise.nix` — `final.python3Packages.buildPythonApplication`
    - hatchling. Python version-sensitive.
  - `agnix.nix` — Rust, uses `final.rust-bin.stable.latest.default`,
    `final.pkg-config`, `final.apple-sdk_15` (darwin)

  **packages/mcp-servers/** — npm/Python/Go builds, all currently use `final`:
  - `default.nix` — `callPkg` already supports `{inputs, ...}` pattern
    but most package files don't take `inputs`. Update each package file.
  - npm: `context7-mcp.nix`, `effect-mcp.nix`, `git-intel-mcp.nix`,
    `openmemory-mcp.nix`, `sequential-thinking-mcp.nix` — use
    `final.buildNpmPackage`, `final.nodejs`, `final.makeWrapper`
  - Python: `fetch-mcp.nix`, `git-mcp.nix`, `kagi-mcp.nix`,
    `mcp-proxy.nix`, `nixos-mcp.nix`, `serena-mcp.nix`, `sympy-mcp.nix`
    — use `final.python3Packages.X` or `final.python3.withPackages`
  - Go: `github-mcp.nix`, `mcp-language-server.nix` — use
    `final.buildGoModule`

  **packages/ai-clis/** — mixed:
  - `claude-code.nix` — `prev.claude-code.override` (npm build) +
    `final.symlinkJoin` + `final.writeShellScript` + `final.bun`. The
    Bun runtime in the wrapper will close over consumer's bun version
    → AFFECTED. Fix: build everything against ourPkgs.
  - `copilot-cli.nix` — `prev.github-copilot-cli.overrideAttrs` with
    just `src`/`version`. Pure binary install, low impact but still
    technically affected (base derivation comes from consumer). Lower
    priority unless verified to be cache-missing.
  - `kiro-cli.nix` — same as copilot-cli plus `final.makeWrapper` for
    postFixup. Same priority.
  - `kiro-gateway.nix` — uses `final.python314.withPackages` with
    explicit Python 3.14 + fastapi/httpx/etc. AFFECTED — Python env
    closure changes with consumer's nixpkgs.

  **packages/coding-standards/, fragments-ai/, fragments-docs/,
  stacked-workflows/** — pure content (markdown files in derivations,
  no compilation). NOT affected. Skip.

  ### Verification protocol

  After fixing each package, verify the consumer-side store path
  matches the standalone-build store path:

  ```bash
  # 1. Standalone path (CI builds this)
  cd ~/Documents/projects/nix-agentic-tools
  STANDALONE=$(nix eval --raw .#git-branchless)
  echo "standalone: $STANDALONE"

  # 2. Consumer path (eval the overlay through consumer's nixpkgs)
  cd ~/Documents/projects/nixos-config
  CONSUMER=$(nix eval --raw --impure --expr '
    let
      flake = builtins.getFlake (toString ./.);
      pkgs = import flake.inputs.nixpkgs {
        system = "x86_64-linux";
        overlays = import ./overlays { inherit (flake) inputs; lib = flake.inputs.nixpkgs.lib; };
        config.allowUnfree = true;
      };
    in pkgs.git-branchless.outPath')
  echo "consumer:   $CONSUMER"

  # 3. Must be identical
  [ "$STANDALONE" = "$CONSUMER" ] && echo "✓ MATCH" || echo "✗ DRIFT"

  # 4. Confirm cache hit possible
  HASH=$(basename "$STANDALONE" | cut -d- -f1)
  curl -sI "https://nix-agentic-tools.cachix.org/${HASH}.narinfo" | head -1
  # Expect: HTTP/2 200
  ```

  Repeat for each package after fixing it. Add a flake check or CI
  test that runs this comparison automatically — would catch any
  future drift where someone introduces `final.X` for a build input.

  ### Why this isn't free (the trade-off the user already accepted)

  The consumer's /nix/store ends up holding TWO nixpkgs evaluations:
  their own (used for everything else) and ours (used to build our
  packages). Most of the closure deduplicates via content-addressing
  (glibc, bash, coreutils are byte-identical when source content
  matches), but anything that drifted between the two pins is
  duplicated. flake.lock grows because nix-agentic-tools' inputs
  aren't deduped against the consumer's. Disk usage goes up, but
  cache hits become reliable instead of theoretical.

  This is the deliberate cost of `e5406977`. The fix here finishes
  what that commit started.

  ### Lower-priority follow-ups
  - Add a flake check `checks.x86_64-linux.cache-hit-parity` that
    fails if any consumer-side eval produces a store path different
    from the standalone build. Prevents regression.
  - Document this pattern in `dev/docs/concepts/` so future overlay
    additions follow it from day one.
  - Consider abstracting the `ourPkgs = import inputs.nixpkgs { ... }`
    boilerplate into a `lib/our-pkgs.nix` helper that takes `inputs`
    and `final.system` and returns a configured pkgs set. Each
    package file becomes a one-liner `{inputs}: ... let pkgs =
ourPkgs inputs final.system; in { ... };`.

- [ ] **ai HM module should `imports` its deps** — `homeManagerModules.ai`
      should pull in `claude-code-buddy`, `copilot-cli`, `kiro-cli` (and
      whatever else it references) via `imports = [ ... ]` so consumers
      get a single import. Currently the `ai` module references
      `programs.copilot-cli` / `programs.kiro-cli` unconditionally inside
      `mkIf cfg.copilot.enable` blocks, which forces consumers to manually
      import those modules even when they're not using them, because the
      NixOS module system requires option paths to exist regardless of
      mkIf condition. Real-world surfaced this in nixos-config consumer
      integration (2026-04-06): had to add four surgical imports
      (ai, claude-code-buddy, copilot-cli, kiro-cli) where one should
      have sufficed. Either:
      (a) `ai/default.nix` adds `imports = [ ../claude-code-buddy ../copilot-cli ../kiro-cli ];`
      (b) Guard the `programs.{copilot,kiro}-cli` references with
      `lib.optionalAttrs (hasModule [...])` and keep modules separate
      Pick (a) for least consumer friction.
- [ ] **Drop standalone `claude-code-buddy` HM module** — fold the buddy
      option into a single nix-agentic-tools `claude-code` HM module that
      augments upstream `programs.claude-code` (mirrors how copilot-cli
      and kiro-cli modules work). Eliminates the awkward
      `homeManagerModules.claude-code-buddy` consumers have to know
      about. The `ai` module's `imports` (above) brings it in
      transparently. Naming question: keep as `programs.claude-code.buddy`
      or move to `programs.claude-code-extras.buddy` to avoid conflict
      with upstream HM's claude-code module if it ever adds its own
      `buddy` option.
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
- [ ] **Bundle any-buddy into claude-code package** — `any-buddy-source`
      is currently its own overlay package
      (`packages/ai-clis/any-buddy.nix`), exposed at
      `pkgs.any-buddy-source`, solely so the activation script in
      `modules/claude-code-buddy/default.nix` can reference
      `${pkgs.any-buddy-source}/src/finder/worker.ts`. It's not
      consumed by anything else. Move the source tree into the
      claude-code package as a private passthru (e.g.
      `pkgs.claude-code.passthru.anyBuddySource`) and update the
      buddy module to pull it from there. Removes one top-level
      package export and one nvfetcher entry's exposed surface
      (nvfetcher entry stays; just not re-exported). Touch points:
      `packages/ai-clis/claude-code.nix` (add passthru),
      `packages/ai-clis/default.nix` (stop exporting
      any-buddy-source), `packages/ai-clis/any-buddy.nix` (keep
      but feed into claude-code only, or inline),
      `modules/claude-code-buddy/default.nix` (switch worker
      reference), `flake.nix` packages attrset (drop
      any-buddy-source), `README.md` if it enumerates packages.

      General refactor pattern to apply when any
      `packages/<group>/<name>.nix` gets too big: convert to
      `packages/<group>/<name>/default.nix` with sibling files
      under the same directory (e.g. `wrapper.nix`, `patching.nix`)
      keeping all concerns for that one package co-located. Keeps
      the overlay entry point stable (`<name>`) and the flake
      output path unchanged. Don't pre-split — do it when a single
      file gets unwieldy.

- [ ] **`ai.skills` stacked-workflows special case** — currently
      `ai.skills` is raw data: it takes an attrset of name → path
      and fans out to each enabled ecosystem's skills attribute.
      Consumer wanting stacked-workflows skills today has to use
      `stacked-workflows.integrations.<ecosystem>.enable = true`
      per ecosystem, separate from `ai.skills`. Augment `ai.skills`
      to support a structured "include stacked-workflows" flag
      (e.g. `ai.skills.stackedWorkflows.enable = true` or a
      similar scheme) that pulls SWS skills + routing table into
      every enabled ecosystem in one line, without forcing
      consumers to touch `stacked-workflows.integrations.*`
      directly. Keep the raw `ai.skills.<name> = path` form for
      bring-your-own skills. Design question: whether to move
      stacked-workflows.integrations under ai.skills entirely
      (deprecate the old option) or keep it as a parallel path
      that ai.skills delegates to.
- [ ] outOfStoreSymlink helper for runtime state dirs — Claude writes
      ~/.claude/projects mid-session, can't use regular HM files.
      Document the outOfStoreSymlink pattern or wrap as an option
      (ai.claude.persistentDirs)
- [ ] Secret scanning — integrate gitleaks into pre-commit hook or CI.
      Currently clean (406 commits verified 2026-04-06). Wire via
      git-hooks.hooks in devenv or as a CI step in ci.yml
