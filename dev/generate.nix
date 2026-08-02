# Fragment composition for instruction file generation.
#
# Single source of truth for composing fragments into ecosystem-specific
# instruction files. Consumed by both devenv tasks and flake derivations.
#
# Takes { lib, pkgs } where pkgs has all content overlays applied
# (coding-standards, fragments-ai, stacked-workflows).
#
# Returns:
#   agentsMd    — full AGENTS.md content string
#   claudeFiles — { "filename.md" = content; } for Claude rule files
#   claudeMd    — full CLAUDE.md content string
#   copilotFiles — { "filename.md" = content; } for Copilot instruction files
#   kiroFiles   — { "filename.md" = content; } for Kiro steering files
{
  lib,
  pkgs,
}: let
  fragments = import ../lib/fragments.nix {inherit lib;};

  # ── Fragment category registry ───────────────────────────────────────
  # The per-category scope globs + fragment sources, merged from
  # config/fragment-categories.nix against the option declaration in
  # lib/fragments-registry.nix. Replaces the two parallel hand-maintained
  # attrsets (`packagePaths` and `devFragmentNames`) that used to sit
  # inline here.
  #
  # This is an internal lib.evalModules rather than a flake output like
  # `.#updateTargets` / `.#cacheHitParityTargets` because this file is
  # imported directly as a bare `{lib, pkgs}` function by BOTH flake.nix
  # (via dev/instructions.nix) and the standalone devenv path, neither of
  # which passes `self` — so it structurally cannot read a flake output,
  # and an output with no consumer would be dead surface. It already
  # direct-imports ../lib/fragments.nix and ./data.nix the same way.
  fragmentCategories =
    (lib.evalModules {
      modules = [
        ../config/fragment-categories.nix
        ../lib/fragments-registry.nix
      ];
    })
    .config.fragments.categories;

  # ── Fragments from content packages (via overlay) ────────────────────
  commonFragments = builtins.attrValues pkgs.coding-standards.passthru.fragments;
  swsFragments = builtins.attrValues pkgs.stacked-workflows-content.passthru.fragments;

  # ── Dev-only fragment reader ─────────────────────────────────────────
  # Each entry in a category's `sources` list may be either:
  #   - A bare string "name" (legacy form, equivalent to location = "dev")
  #     reads ./fragments/<pkg>/<name>.md
  #   - An attrset { location, name, dir } for co-located fragments:
  #     - location = "dev" (default): ./fragments/<dir>/<name>.md
  #     - location = "package": ../packages/<dir>/docs/<name>.md
  #     - location = "devshell": ../devshell/<dir>/docs/<name>.md
  #     The `dir` field defaults to null, which falls back to `pkg` (the
  #     config.fragments.categories key), and is set explicitly when the
  #     category name differs from the directory name.
  #
  #     Post-factory rollout, "package" location now reads from
  #     packages/<name>/docs/ (the Bazel-style per-package docs dir)
  #     instead of the legacy packages/<name>/fragments/dev/ path.
  normalizeDevFragmentSource = pkg: entry: let
    normalized =
      if builtins.isString entry
      then {
        location = "dev";
        name = entry;
        dir = pkg;
      }
      else {
        location = entry.location or "dev";
        inherit (entry) name;
        # The submodule always supplies `dir` (default null), so this is a
        # present-but-null fallback rather than an absent-attr one.
        dir =
          if (entry.dir or null) != null
          then entry.dir
          else pkg;
      };
    inherit (normalized) location name dir;
    locationBases = {
      dev = ./fragments;
      package = ../packages;
      devshell = ../devshell;
    };
    base =
      locationBases.${location}
        or (throw "mkDevFragment: unknown location '${location}' (expected ${builtins.concatStringsSep "|" (builtins.attrNames locationBases)})");
    fragmentPath =
      if location == "dev"
      then base + "/${dir}/${name}.md"
      else base + "/${dir}/docs/${name}.md";
    # Repo-relative source path for provenance comments
    repoRelative =
      if location == "dev"
      then "dev/fragments/${dir}/${name}.md"
      else if location == "package"
      then "packages/${dir}/docs/${name}.md"
      else if location == "devshell"
      then "devshell/${dir}/docs/${name}.md"
      else "${location}/${dir}/${name}.md";
  in
    normalized
    // {
      inherit fragmentPath repoRelative;
    };

  mkDevFragment = pkg: entry: let
    sourceInfo = normalizeDevFragmentSource pkg entry;
  in
    fragments.mkFragment {
      text = builtins.readFile sourceInfo.fragmentPath;
      description = "${sourceInfo.location}:${sourceInfo.dir}/${sourceInfo.name}";
      source = sourceInfo.repoRelative;
      priority = 5;
    };

  # ── Extra published fragments per package (beyond commonFragments) ───
  extraPublishedFragments = {
    monorepo = swsFragments;
    stacked-workflows = swsFragments;
  };

  # ── Compose fragments for a dev package profile ──────────────────────
  # The monorepo (root) profile includes shared content (coding standards,
  # commit conventions, etc. from commonFragments) because its output is
  # the always-loaded CLAUDE.md / common.md. Scoped profiles include ONLY
  # their scope-specific content — repeating the shared content in every
  # scoped rule file amplifies context rot (duplicate tokens loaded when
  # a scoped rule triggers alongside the always-loaded common.md).
  # Per Checkpoint 2 research on context dilution.
  mkDevComposed = package: let
    devFrags = map (mkDevFragment package) (fragmentCategories.${package}.sources or []);
    extraFrags = extraPublishedFragments.${package} or [];
    isRoot = package == "monorepo";
  in
    fragments.compose {
      fragments =
        if isRoot
        then commonFragments ++ extraFrags ++ devFrags
        else extraFrags ++ devFrags;
      generator = "dev/generate.nix";
    };

  # ── Ecosystem file transforms ────────────────────────────────────────
  # Transformer functions live in lib/ai/transformers/ (moved from
  # packages/fragments-ai/default.nix passthru.transforms during the
  # factory rollout — Milestone 9). Each exposes a `render` function
  # that takes a composed fragment (optionally merged with
  # ecosystem-specific extras like `package` for claude or `name`
  # for kiro) and returns a rendered byte string.
  aiTransforms = (import ../lib/ai {inherit lib;}).transformers;
  mkEcosystemFile = package: let
    paths = fragmentCategories.${package}.scopes or null;
    withPaths = composed:
      if paths != null
      then composed // {inherit paths;}
      else composed;
  in {
    agentsmd = composed: aiTransforms.agentsmd.render (withPaths composed);
    claude = composed: aiTransforms.claude.render (withPaths composed // {inherit package;});
    copilot = composed: aiTransforms.copilot.render (withPaths composed);
    kiro = composed: aiTransforms.kiro.render (withPaths composed // {name = package;});
  };

  # ── Derived values ───────────────────────────────────────────────────
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") fragmentCategories;
  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";

  # ── AGENTS.md content ────────────────────────────────────────────────
  # AGENTS.md keeps scoped fragment BODIES out of its always-loaded context.
  # It previously concatenated every body because the agents.md standard has
  # no glob-scoping primitive, bloating the file to ~19k mostly irrelevant
  # tokens. Dropping them entirely created the opposite failure for Codex:
  # unlike Claude/Copilot/Kiro, it does not load the generated scoped files and
  # had no way to discover which authoritative source fragment applied.
  #
  # The compact index below is the progressive-disclosure bridge. Deriving its
  # match globs and source links from the SAME registry prevents a fifth,
  # hand-maintained routing surface from drifting. Link the source fragments,
  # not runtime projections: source paths exist in every checkout, while the
  # Claude/Kiro projections are gitignored shell-entry artifacts and editing
  # any generated projection would be overwritten on the next reload.
  agentsContent = rootComposed.text;

  mkInlineCodeList = values:
    lib.concatMapStringsSep ", " (value: "`${value}`") values;
  mkSourceLinks = package:
    lib.concatMapStringsSep ", " (entry: let
      path = (normalizeDevFragmentSource package entry).repoRelative;
    in "[`${path}`](${path})")
    (fragmentCategories.${package}.sources or []);
  scopedArchitectureRouting = lib.concatMapStringsSep "\n" (package: ''
    - **`${package}`**
      - Match: ${mkInlineCodeList fragmentCategories.${package}.scopes}
      - Read: ${mkSourceLinks package}
  '') (lib.sort lib.lessThan (builtins.attrNames nonRootPackages));

  # ── Claude rule files ────────────────────────────────────────────────
  # Scoped rule files only. No common.md — the body content is
  # already loaded via CLAUDE.md (which @-imports AGENTS.md), so
  # a separate .claude/rules/common.md byte-identical to the body
  # was pure waste and triple-loaded orientation content at every
  # Claude session start.
  claudeFiles =
    lib.concatMapAttrs (pkg: _: let
      composed = mkDevComposed pkg;
      pkgEco = mkEcosystemFile pkg;
    in {
      "${pkg}.md" = pkgEco.claude composed;
    })
    nonRootPackages;

  # ── Copilot instruction files ────────────────────────────────────────
  copilotFiles =
    {
      "copilot-instructions.md" = monorepoEco.copilot rootComposed;
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.instructions.md" = pkgEco.copilot composed;
      })
      nonRootPackages);

  # ── Kiro steering files ─────────────────────────────────────────────
  kiroFiles =
    {
      "common.md" = aiTransforms.kiro.render (rootComposed // {name = "common";});
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.md" = pkgEco.kiro composed;
      })
      nonRootPackages);

  # ── Top-level markdown files ─────────────────────────────────────────
  agentsMd = ''
    # AGENTS.md

    Project instructions for AI coding assistants working in this repository.
    Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
    support the [AGENTS.md standard](https://agents.md).

    Deep-dive architecture documentation (fanout semantics, wrapper chains,
    fragment pipeline, overlay cache-hit parity, HM module conventions, etc.)
    comes from the source fragments routed below. Claude, Copilot, and Kiro
    receive generated path-scoped projections of those sources. Codex and other
    AGENTS-only consumers do not load those projections, so they must use the
    routing index before editing a matching path. Fragment bodies are not
    duplicated here, keeping always-loaded context focused.

    ## Scoped architecture routing

    Before editing a path that matches one or more entries, read every listed
    source document for those entries. When multiple entries match, their
    guidance composes. The registry-generated index is authoritative for
    routing; source documents are authoritative for content. Do not edit
    generated `.claude/rules/`, `.github/instructions/`, or `.kiro/steering/`
    projections directly.

    ${scopedArchitectureRouting}

    ${agentsContent}
  '';

  # CLAUDE.md is a one-liner that @-imports AGENTS.md. All
  # orientation content lives in AGENTS.md. Keeping CLAUDE.md
  # body content alongside the @AGENTS.md import would
  # double-load the content at every session start (the import
  # expansion plus the inline body).
  claudeMd = ''
    # CLAUDE.md

    @AGENTS.md
  '';
  # ── README.md generation ─────────────────────────────────────────────

  # ── Shared description mappings (from dev/data.nix) ──────────────────
  data = import ./data.nix {inherit lib;};
  inherit (data) aiCliDescriptions devToolDescriptions genericDescriptions gitToolDescriptions mcpServerMeta skillDescriptions;
  inherit (data) mcpServerCount;

  # ── Table generators ─────────────────────────────────────────────────
  # Four of the README package tables are the same two-column
  # `| `name` | description |` shape over a name → description attrset,
  # name-sorted. One generator serves all four so a fifth package group
  # is a one-line call rather than a fourth copy of the same three lines.
  # The MCP-server table (extra Credentials column) and the skill table
  # (`/name` in the first cell) have their own shapes below.
  mkDescriptionRows = descriptions:
    lib.concatMapStringsSep "\n"
    (name: "| `${name}` | ${descriptions.${name}} |")
    (lib.sort lib.lessThan (builtins.attrNames descriptions));

  aiCliRows = mkDescriptionRows aiCliDescriptions;
  devToolRows = mkDescriptionRows devToolDescriptions;
  genericRows = mkDescriptionRows genericDescriptions;
  gitToolRows = mkDescriptionRows gitToolDescriptions;

  mcpServerNames = lib.sort lib.lessThan (builtins.attrNames mcpServerMeta);
  mcpServerRows = lib.concatMapStringsSep "\n" (name: let
    meta = mcpServerMeta.${name};
  in "| `${name}` | ${meta.description} | ${meta.credentials} |")
  mcpServerNames;

  skillNames = lib.sort lib.lessThan (builtins.attrNames skillDescriptions);
  skillRows =
    lib.concatMapStringsSep "\n" (name: "| `/${name}` | ${skillDescriptions.${name}} |")
    skillNames;

  # ── Full README content ──────────────────────────────────────────────
  # The AI feature matrix is intentionally capability-oriented rather than a
  # blanket "all CLIs" claim. Codex lacks some native surfaces (notably LSP
  # registration and process-environment fanout), while agents and hooks only
  # have smaller semantic intersections. Keeping those distinctions visible at
  # the front door prevents documentation parity from becoming fake runtime
  # parity.
  readmeMd = ''
    # nix-agentic-tools

    Stacked commit workflows, MCP servers, and declarative configuration for
    AI coding CLIs (Claude Code, Codex, Copilot, Kiro). Works without Nix; Nix
    unlocks overlays, home-manager modules, and devshell integration.

    ## Quick Start

    <details>
    <summary><strong>Non-Nix (copy skills into your project)</strong></summary>

    Prerequisites: [git-branchless](https://github.com/arxanas/git-branchless),
    [git-absorb](https://github.com/tummychow/git-absorb),
    [git-revise](https://github.com/mystor/git-revise).

    ```bash
    # Claude Code
    cp -r packages/stacked-workflows/skills/stack-* .claude/skills/

    # OpenAI Codex
    cp -r packages/stacked-workflows/skills/stack-* .agents/skills/

    # GitHub Copilot
    cp -r packages/stacked-workflows/skills/stack-* .github/skills/

    # Kiro
    cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/
    ```

    Each skill is self-contained with a `SKILL.md` and bundled reference docs.

    </details>

    <details>
    <summary><strong>Home-Manager (system-level declarative config)</strong></summary>

    ```nix
    # flake.nix
    inputs.nix-agentic-tools = {
      url = "github:higherorderfunctor/nix-agentic-tools";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Apply overlay
    nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

    # Home-manager config
    imports = [inputs.nix-agentic-tools.homeManagerModules.default];

    ai = {
      claude.enable = true;
      codex = {
        enable = true;
        settings.model = "gpt-5.6-sol";
      };
      copilot.enable = true;
      kiro.enable = true;
      settings.reasoningEffort = "high";
    };

    stacked-workflows = {
      enable = true;
      gitPreset = "full";
      integrations.claude.enable = true;
    };

    services.mcp-servers.servers.github-mcp = {
      enable = true;
      settings.credentials.file = "/run/secrets/github-token";
    };
    ```

    > **Note (Kiro steering uninstall):** Kiro steering files are
    > materialized as read-only real files (the Kiro v3 engine ignores
    > symlinks — kirodotdev/Kiro#9787). Disabling `ai.kiro` removes the
    > materializer itself, so already-written steering files are NOT
    > pruned. To uninstall cleanly, first empty the steering surface (or
    > set `ai.kiro.steeringStrategy = "symlink"`) for one activation,
    > then disable.

    </details>

    <details open>
    <summary><strong>DevEnv (per-project dev shell)</strong></summary>

    ```yaml
    # devenv.yaml
    inputs:
      nix-agentic-tools:
        url: github:higherorderfunctor/nix-agentic-tools
        inputs:
          nixpkgs:
            follows: nixpkgs
    ```

    ```nix
    # devenv.nix
    {inputs, ...}: {
      imports = [inputs.nix-agentic-tools.devenvModules.nix-agentic-tools];

      ai = {
        claude.enable = true;
        codex.enable = true;
      };

      claude.code = {
        mcpServers.github-mcp = {
          type = "stdio";
          command = "github-mcp-server";
          args = ["--stdio"];
        };
      };
    }
    ```

    </details>

    ## Skills

    Stacked commit workflow skills using git-branchless, git-absorb, and
    git-revise.

    <!-- prettier-ignore -->
    | Skill | Description |
    |-------|-------------|
    ${skillRows}

    ## Packages

    <details>
    <summary><strong>MCP Servers</strong> (${toString mcpServerCount} servers)</summary>

    <!-- prettier-ignore -->
    | Server | Description | Credentials |
    |--------|-------------|-------------|
    ${mcpServerRows}

    ```bash
    nix build .#github-mcp
    ```

    </details>

    <details>
    <summary><strong>Git Tools</strong></summary>

    <!-- prettier-ignore -->
    | Package | Description |
    |---------|-------------|
    ${gitToolRows}

    ```bash
    nix build .#git-absorb
    ```

    </details>

    <details>
    <summary><strong>Dev Tools</strong></summary>

    <!-- prettier-ignore -->
    | Package | Description |
    |---------|-------------|
    ${devToolRows}

    ```bash
    nix build .#oxlint
    ```

    </details>

    <details>
    <summary><strong>Generic Packages</strong></summary>

    Nothing agentic about these — they live in a split-ready
    `overlays/generic/` subtree and are exposed as `pkgs.generic.*`.

    <!-- prettier-ignore -->
    | Package | Description |
    |---------|-------------|
    ${genericRows}

    ```bash
    nix build .#dns-root-hints
    ```

    </details>

    <details>
    <summary><strong>AI CLIs</strong></summary>

    <!-- prettier-ignore -->
    | Package | Description |
    |---------|-------------|
    ${aiCliRows}

    </details>

    <details>
    <summary><strong>Content Packages</strong></summary>

    <!-- prettier-ignore -->
    | Package | Description |
    |---------|-------------|
    | `coding-standards` | Reusable coding standard fragments (DRY, conventional commits, etc.) |
    | `stacked-workflows-content` | Skills, references, and skill-routing fragment |

    Content packages are derivations with `passthru.fragments` for
    composable instruction building.

    </details>

    ## Feature Matrix

    <!-- prettier-ignore -->
    | Feature | Without Nix | Home-Manager | DevEnv |
    |---------|-------------|--------------|--------|
    | Stacked workflow skills | Copy skills/ | `stacked-workflows.enable` | `ai.skills.*` |
    | MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
    | Unified MCP config | Manual native config | `ai.mcpServers.*` (all four CLIs) | `ai.mcpServers.*` (all four CLIs) |
    | Typed MCP settings | N/A | Shared schema + native extensions | Shared schema + native extensions |
    | MCP credentials | Manual env vars | `plain`, `file`, or `helper` | `plain`, `file`, or `helper` |
    | Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
    | GitLab CLI config | `glab config set` | `glab.*` | `glab.*` |
    | GitLab CLI credentials | Manual env vars | `plain`, `file` or `helper` | `plain`, `file` or `helper` |
    | Context, instructions, rules | Copy native files | `ai.{context,instructions,rules}` (all four CLIs) | Same; project-native paths |
    | Skills | Copy native directories | `ai.skills.*` (all four CLIs) | Same; project-native paths |
    | Portable reasoning effort | Per-CLI config | `ai.settings.reasoningEffort` (Claude + Codex) | Same |
    | Semantic agents | Per-CLI config | `ai.agents.*` (Claude + Codex + Copilot) | Same; project-native paths |
    | Portable lifecycle hooks | Per-CLI config | `ai.hooks.*` (Claude + Codex) | Same |
    | LSP server config | Per-CLI config | `ai.lspServers.*` (Claude + Copilot + Kiro) | Same; Codex has no native LSP registry |
    | CLI process environment | Shell config | `ai.environmentVariables` (Copilot + Kiro) | Same; Claude/Codex use other mechanisms |
    | Fragment composition | N/A | `lib.ai.compose` | `lib.ai.compose` |

    ## Configuration

    <details>
    <summary><strong>Unified ai.* Module</strong></summary>

    Single source of truth for shared config across Claude, Codex, Copilot,
    and Kiro. Only semantics a runtime can preserve fan out; the feature matrix
    above names deliberate exclusions. Scalar defaults use `mkDefault`
    priority, so per-CLI overrides always win.

    ```nix
    ai = {
      claude.enable = true;
      codex.enable = true;
      copilot.enable = true;
      kiro.enable = true;

      skills.my-skill = ./skills/my-skill;

      instructions.standards = {
        text = "Use strict mode everywhere";
        paths = ["src/**"];
        description = "Project standards";
      };

      lspServers.nixd = {
        package = pkgs.nixd;
        extensions = ["nix"];
      };

      settings.reasoningEffort = "high";

      # Runtime-native escape hatch: model identifiers are not portable.
      codex.settings.model = "gpt-5.6-sol";
    };
    ```

    </details>

    <details>
    <summary><strong>Codex config ownership</strong></summary>

    Codex writes ad-hoc project trust into its user `config.toml`. Home Manager
    therefore keeps that file writable and reconciles only the exact TOML leaves
    declared by Nix, preserving native state and removing formerly managed
    leaves on later activations. It does **not** use a read-only store symlink.

    Devenv owns `.codex/config.toml` statically because no project-local Codex
    writer has been observed. User-global trust remains outside the project:
    trust the repository once when Codex prompts, or declare
    `ai.codex.settings.projects."<absolute-path>".trust_level` through Home Manager.
    Devenv rejects that bootstrap-global setting because project config cannot
    grant the trust required to load itself.

    Native-only settings remain under `ai.codex.settings`; Home Manager-only
    named profile files use `ai.codex.profiles`, and native Starlark command
    policy uses `ai.codex.execpolicyRules` rather than Markdown `ai.rules`.

    </details>

    <details>
    <summary><strong>Claude Delegation-Clamp Mitigation (on by default)</strong></summary>

    Claude Code injects a system-prompt section telling the model not to use
    subagents, workflows, or deep research "unless the user requested it". It is
    gated on a **model capability**, not on your configuration — on by default
    for Opus 5 — and no setting, flag, or environment variable turns it off. It
    never appears in the transcript, so a session with delegation silently
    suppressed looks identical to a normal one. It also directly contradicts
    `ai.claude.ultracodeOnLaunch`, which asks for the opposite.

    Enabling Claude through `ai.claude` installs a mitigation automatically. It
    patches nothing: a `UserPromptSubmit` hook supplies the request that the
    clamp's own escape clause is asking for, as user-side context. It is
    injected once per session and re-armed by a `PreCompact` hook, so the cost
    is roughly 75 tokens per session rather than per turn.

    ```nix
    ai.claude.delegationClamp = {
      mitigate = true;        # default; set false for stock behavior
      text = "…";             # the standing request — wording is load-bearing
    };
    ```

    Upstream: [anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988).
    Two tripwires force re-evaluation instead of letting this calcify — a flake
    check fails when the pinned Claude Code version moves, and a dated CI step
    fails once `config/heron-brook-tripwire.json`'s `reviewBy` passes. See
    `packages/claude-code/docs/heron-brook-clamp.md`.

    </details>

    <details>
    <summary><strong>MCP Servers (Home-Manager)</strong></summary>

    ```nix
    services.mcp-servers.servers = {
      github-mcp = {
        enable = true;
        settings.credentials.file = config.sops.secrets.github-token.path;
      };
      nixos-mcp.enable = true;
      context7-mcp.enable = true;
    };
    ```

    </details>

    <details>
    <summary><strong>Stacked Workflows</strong></summary>

    ```nix
    stacked-workflows = {
      enable = true;
      gitPreset = "full";     # or "minimal" or "none"
      integrations = {
        claude.enable = true;
        copilot.enable = true;
        kiro.enable = true;
      };
    };
    ```

    See the `stacked-workflows` package for git presets and skill
    details.

    </details>

    ## License

    Released under the [Unlicense](LICENSE).
  '';
  # ── CONTRIBUTING.md content ─────────────────────────────────────────
  contributingMd = let
    buildCommands = builtins.readFile ./fragments/monorepo/build-commands.md;
    generationArch = builtins.readFile ./fragments/pipeline/generation-architecture.md;
    commitConvention = builtins.readFile ../packages/coding-standards/fragments/commit-convention.md;
  in ''
    # Contributing to nix-agentic-tools

    <!-- TODO: refine with maintainer input -->

    ## Development Setup

    All tools are provided by the devenv shell. No global installs required.

    ```bash
    devenv shell          # enter dev shell with all tools
    ```

    ${buildCommands}

    ## Tests

    ```bash
    devenv test           # run all devenv checks
    nix flake check       # linters + evaluation (does NOT build packages)
    ```

    ${generationArch}

    ## Updating Dependencies

    ```bash
    devenv tasks run update:all   # update all inputs and packages via ninja DAG
    ```

    After updating, rebuild affected packages to verify hashes:

    ```bash
    nix build .#<package>
    ```

    If a hash mismatch occurs, copy the expected hash from the error and
    update `packages/mcp-servers/hashes.json` (or the relevant sidecar).

    ## Code Standards

    Coding standards, ordering rules, DRY principle, and Bash strict mode
    are documented in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).
    Do not duplicate — read those files first.

    ## Linting

    Run the meta-formatter before committing:

    ```bash
    treefmt              # format everything (formats only — lints nothing)
    treefmt <file>       # format a single file after editing
    ```

    Linting is separate from formatting: the linters (deadnix, statix,
    shellcheck, cspell) run as prek pre-commit hooks, which are disabled in
    CI and can be skipped with `--no-verify`.

    `nix flake check` is the CI gate (formatting, structural checks, and
    module evaluation). Spelling is NOT part of it — cspell runs only as a
    prek hook, so CI never checks it.

    ${commitConvention}

    ## Adding a Package

    ### AI CLI or MCP Server

    See the **AI CLI Packages** and **MCP Server Packages** sections in
    [AGENTS.md](AGENTS.md) for the full overlay pattern and step-by-step
    instructions.

    ### General pattern

    1. Create `overlays/<name>.nix` with inline `rev` + `hash`
    2. Register in `overlays/default.nix`
    3. Add a `config.update.targets.<name>` row in `config/update-targets.nix` with appropriate flags
    4. Export in `flake.nix` under `packages`
    5. Add HM and devenv modules in `packages/<name>/modules/`
    6. Run `nix flake check` to verify

    See [Change Propagation](AGENTS.md#change-propagation) — when removing
    or renaming a concept, all surfaces must be updated in the same commit.

    ## Adding a Fragment

    Fragments are composable instruction blocks used to build AI instruction
    files (CLAUDE.md, AGENTS.md, Copilot, Kiro) and CONTRIBUTING.md.

    <!-- TODO: refine with maintainer input -->

    | Fragment type | Location | Exported? |
    |---------------|----------|-----------|
    | Dev-only (monorepo/tooling) | `dev/fragments/<pkg>/<name>.md` | No |
    | Published coding standards | `packages/coding-standards/fragments/<name>.md` | Yes |
    | Published SWS skill-routing rule | `packages/stacked-workflows/fragments/<name>.md` | Yes |

    To add a dev-only fragment:

    1. Create `dev/fragments/<pkg>/<name>.md`
    2. Add the name to `config.fragments.categories.<pkg>.sources` in
       `config/fragment-categories.nix` (scope globs for the category live
       alongside it as `.scopes`)
    3. Run `devenv tasks run --mode before generate:all` to regenerate

    To add a published fragment (consumed by external users):

    1. Create `packages/<pkg>/fragments/<name>.md`
    2. Register it in `packages/<pkg>/default.nix` under `passthru.fragments`
    3. Run `devenv tasks run --mode before generate:all` to regenerate everything

    ## Pull Requests

    <!-- TODO: refine with maintainer input -->

    - One logical change per PR
    - CI must pass (formatting, linting, spelling, module evaluation)
    - Generated files (CLAUDE.md, AGENTS.md, README.md, CONTRIBUTING.md,
      Copilot and Kiro instruction files) must be regenerated if their
      source fragments changed: run
      `devenv tasks run --mode before generate:all`
    - Keep commits atomic using the stacked workflow skills
      (`/stack-plan`, `/stack-fix`, `/stack-submit`)
  '';
in {
  inherit agentsMd claudeFiles claudeMd contributingMd copilotFiles kiroFiles readmeMd;
}
