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

  # ── Fragments from content packages (via overlay) ────────────────────
  commonFragments = builtins.attrValues pkgs.coding-standards.passthru.fragments;
  swsFragments = builtins.attrValues pkgs.stacked-workflows-content.passthru.fragments;

  # ── Dev-only fragment reader ─────────────────────────────────────────
  # Each entry in devFragmentNames may be either:
  #   - A bare string "name" (legacy form, equivalent to location = "dev")
  #     reads ./fragments/<pkg>/<name>.md
  #   - An attrset { location, name, dir ? pkg } for co-located fragments:
  #     - location = "dev" (default): ./fragments/<dir>/<name>.md
  #     - location = "package": ../packages/<dir>/fragments/dev/<name>.md
  #     - location = "module":  ../modules/<dir>/fragments/dev/<name>.md
  #     The `dir` field defaults to `pkg` (the devFragmentNames key) but can
  #     be set explicitly when the category name differs from the directory
  #     name (e.g., category "ai-module" pointing at modules/ai/).
  mkDevFragment = pkg: entry: let
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
        dir = entry.dir or pkg;
      };
    inherit (normalized) location name dir;
    fragmentPath =
      if location == "dev"
      then ./fragments + "/${dir}/${name}.md"
      else if location == "package"
      then ../packages + "/${dir}/fragments/dev/${name}.md"
      else if location == "module"
      then ../modules + "/${dir}/fragments/dev/${name}.md"
      else throw "mkDevFragment: unknown location '${location}' (expected dev|package|module)";
  in
    fragments.mkFragment {
      text = builtins.readFile fragmentPath;
      description = "${location}:${dir}/${name}";
      priority = 5;
    };

  # ── Package path scoping (for ecosystem frontmatter) ─────────────────
  # Lists are the canonical form. The fragments-ai transforms handle
  # per-ecosystem emission: Claude as a YAML list, Copilot as a
  # comma-joined string (native applyTo syntax), Kiro as an inline
  # YAML array (native fileMatchPattern multi-pattern syntax).
  # null means "always-loaded" (no scoping).
  packagePaths = {
    ai-clis = [
      "modules/copilot-cli/**"
      "modules/kiro-cli/**"
      "packages/ai-clis/**"
    ];
    # ai-module: fanout semantics and per-CLI enable-as-sole-gate.
    # Scoped tightly to modules/ai/ because that's where the fanout
    # logic lives; consumers touching the upstream programs.*-cli
    # modules don't need this loaded.
    ai-module = ["modules/ai/**"];
    # ai-skills: uniform delegation pattern (all branches go through
    # programs.<cli>.skills, no direct home.file). Scoped to ai
    # module + the skill helper + ecosystem CLI modules.
    ai-skills = [
      "modules/ai/**"
      "modules/copilot-cli/**"
      "modules/kiro-cli/**"
      "lib/hm-helpers.nix"
    ];
    # claude-code: wrapper chain + buddy activation lifecycle.
    # Spans the claude-code package and the buddy HM module because
    # the two are tightly coupled (Bun wrapper picks writable cli.js
    # from buddy state, activation script patches that cli.js).
    claude-code = [
      "packages/ai-clis/claude-code.nix"
      "packages/ai-clis/any-buddy.nix"
      "modules/claude-code-buddy/**"
    ];
    # devenv: devenv files.* internals + skills layout walker. Scoped
    # to devenv modules and the helper file.
    devenv = [
      "modules/devenv/**"
      "lib/hm-helpers.nix"
    ];
    # flake: binary cache config + flake-level settings. Scoped to
    # files that touch nixConfig or cachix settings so consumers
    # editing their flake inputs get the rule, and consumers
    # editing ai modules don't.
    flake = [
      "flake.nix"
      "devenv.nix"
    ];
    # hm-modules: cross-cutting module conventions. Scoped to every
    # HM module file so conventions load whenever a contributor is
    # touching any module. Excludes modules/devenv/ because devenv
    # modules have different conventions (per-project files rather
    # than home-manager activation).
    hm-modules = [
      "modules/ai/**"
      "modules/claude-code-buddy/**"
      "modules/copilot-cli/**"
      "modules/kiro-cli/**"
      "modules/mcp-servers/**"
      "modules/stacked-workflows/**"
    ];
    mcp-servers = [
      "modules/mcp-servers/**"
      "packages/mcp-servers/**"
    ];
    monorepo = null;
    # nix-standards: broad Nix code conventions. Applies to any
    # .nix file in the tree.
    nix-standards = ["**/*.nix"];
    # overlays: cross-cutting cache-hit parity rule. Scoped to every
    # overlay package file in packages/, excluding the content-only
    # fragments dirs (which ship markdown, no compilation, so the
    # rule doesn't apply).
    overlays = [
      "packages/ai-clis/*.nix"
      "packages/git-tools/*.nix"
      "packages/mcp-servers/*.nix"
    ];
    # packaging: naming conventions + platform handling for overlay
    # packages. Scoped to the packages tree plus nvfetcher.toml
    # (source tracking).
    packaging = [
      "nvfetcher.toml"
      "packages/**/*.nix"
      "packages/**/sources.nix"
    ];
    # pipeline: fragment composition + ecosystem transforms + docsite
    # generators. Scoped to every file that participates in the dev
    # fragment and instruction generation chain.
    pipeline = [
      "lib/fragments.nix"
      "dev/generate.nix"
      "dev/tasks/generate.nix"
      "packages/fragments-ai/**"
      "packages/fragments-docs/**"
    ];
    stacked-workflows = ["packages/stacked-workflows/**"];
  };

  # ── Dev fragment names per package ───────────────────────────────────
  devFragmentNames = {
    ai-clis = ["packaging-guide"];
    ai-module = [
      {
        location = "module";
        name = "ai-module-fanout";
        dir = "ai";
      }
    ];
    ai-skills = ["skills-fanout-pattern"];
    claude-code = [
      {
        location = "package";
        name = "buddy-activation";
        dir = "ai-clis";
      }
      {
        location = "package";
        name = "claude-code-wrapper";
        dir = "ai-clis";
      }
    ];
    devenv = ["files-internals"];
    flake = ["binary-cache"];
    hm-modules = ["module-conventions"];
    mcp-servers = ["overlay-guide"];
    monorepo = [
      "architecture-fragments"
      "build-commands"
      "change-propagation"
      "linting"
      "project-overview"
    ];
    nix-standards = ["nix-standards"];
    overlays = ["cache-hit-parity"];
    packaging = [
      "naming-conventions"
      "platforms"
    ];
    pipeline = [
      "fragment-pipeline"
      "generation-architecture"
    ];
    stacked-workflows = ["development"];
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
    devFrags = map (mkDevFragment package) (devFragmentNames.${package} or []);
    extraFrags = extraPublishedFragments.${package} or [];
    isRoot = package == "monorepo";
  in
    fragments.compose {
      fragments =
        if isRoot
        then commonFragments ++ extraFrags ++ devFrags
        else extraFrags ++ devFrags;
    };

  # ── Ecosystem file transforms ────────────────────────────────────────
  aiTransforms = pkgs.fragments-ai.passthru.transforms;
  mkEcosystemFile = package: let
    paths = packagePaths.${package} or null;
    withPaths = composed:
      if paths != null
      then composed // {inherit paths;}
      else composed;
  in {
    agentsmd = composed: aiTransforms.agentsmd (withPaths composed);
    claude = composed: aiTransforms.claude {inherit package;} (withPaths composed);
    copilot = composed: aiTransforms.copilot (withPaths composed);
    kiro = composed: aiTransforms.kiro {name = package;} (withPaths composed);
  };

  # ── Derived values ───────────────────────────────────────────────────
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devFragmentNames;

  # Bind composition ONCE per package at the top level. All three
  # ecosystem consumers (claudeFiles, copilotFiles, kiroFiles)
  # reference this binding via lazy eval, so composition runs
  # exactly once per package regardless of consumer count.
  #
  # Anti-pattern: do NOT call mkDevComposed inside the per-ecosystem
  # concatMapAttrs lambdas — that creates a fresh thunk per consumer
  # and runs composition 3x.
  composedByPkg = lib.mapAttrs (pkg: _: mkDevComposed pkg) nonRootPackages;

  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";

  # ── AGENTS.md content ────────────────────────────────────────────────
  # AGENTS.md is orientation only. Previously concatenated
  # every scoped architecture fragment into one flat file
  # because the agents.md standard has no scoping primitive —
  # but that bloated the file to ~19k tokens of content mostly
  # irrelevant to any given edit. Flat consumers (Codex,
  # generic agents.md-compatible tooling) get orientation;
  # deep-dive architecture fragments are documented in the
  # mdbook contributing section (siteArchitecture in flake.nix)
  # and in per-ecosystem scoped files for Claude/Copilot/Kiro.
  agentsContent = rootComposed.text;

  # ── Claude rule files ────────────────────────────────────────────────
  # Scoped rule files only. No common.md — the body content is
  # already loaded via CLAUDE.md (which @-imports AGENTS.md), so
  # a separate .claude/rules/common.md byte-identical to the body
  # was pure waste and triple-loaded orientation content at every
  # Claude session start.
  claudeFiles =
    lib.mapAttrs' (pkg: composed: let
      pkgEco = mkEcosystemFile pkg;
    in
      lib.nameValuePair "${pkg}.md" (pkgEco.claude composed))
    composedByPkg;

  # ── Copilot instruction files ────────────────────────────────────────
  copilotFiles =
    {
      "copilot-instructions.md" = monorepoEco.copilot rootComposed;
    }
    // (lib.mapAttrs' (pkg: composed: let
        pkgEco = mkEcosystemFile pkg;
      in
        lib.nameValuePair "${pkg}.instructions.md" (pkgEco.copilot composed))
      composedByPkg);

  # ── Kiro steering files ─────────────────────────────────────────────
  kiroFiles =
    {
      "common.md" = aiTransforms.kiro {name = "common";} rootComposed;
    }
    // (lib.mapAttrs' (pkg: composed: let
        pkgEco = mkEcosystemFile pkg;
      in
        lib.nameValuePair "${pkg}.md" (pkgEco.kiro composed))
      composedByPkg);

  # ── Top-level markdown files ─────────────────────────────────────────
  agentsMd = ''
    # AGENTS.md

    Project instructions for AI coding assistants working in this repository.
    Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
    support the [AGENTS.md standard](https://agents.md).

    Deep-dive architecture documentation (fanout semantics, wrapper chains,
    buddy activation, fragment pipeline, overlay cache-hit parity, HM module
    conventions, etc.) lives in the mdbook contributing section and in
    path-scoped per-ecosystem files (`.claude/rules/<name>.md`,
    `.github/instructions/<name>.instructions.md`,
    `.kiro/steering/<name>.md`). Those files load on demand when editing
    matching paths; they are not duplicated here to keep this file small.

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
  inherit (data) aiCliDescriptions gitToolDescriptions mcpServerMeta skillDescriptions;
  inherit (data) mcpServerCount;

  # ── Table generators ─────────────────────────────────────────────────
  mcpServerNames = lib.sort lib.lessThan (builtins.attrNames mcpServerMeta);
  mcpServerRows = lib.concatMapStringsSep "\n" (name: let
    meta = mcpServerMeta.${name};
  in "| `${name}` | ${meta.description} | ${meta.credentials} |")
  mcpServerNames;

  gitToolNames = lib.sort lib.lessThan (builtins.attrNames gitToolDescriptions);
  gitToolRows =
    lib.concatMapStringsSep "\n" (name: "| `${name}` | ${gitToolDescriptions.${name}} |")
    gitToolNames;

  aiCliNames = lib.sort lib.lessThan (builtins.attrNames aiCliDescriptions);
  aiCliRows =
    lib.concatMapStringsSep "\n" (name: "| `${name}` | ${aiCliDescriptions.${name}} |")
    aiCliNames;

  skillNames = lib.sort lib.lessThan (builtins.attrNames skillDescriptions);
  skillRows =
    lib.concatMapStringsSep "\n" (name: "| `/${name}` | ${skillDescriptions.${name}} |")
    skillNames;

  # ── Full README content ──────────────────────────────────────────────
  readmeMd = ''
    # nix-agentic-tools

    Stacked commit workflows, MCP servers, and declarative configuration for
    AI coding CLIs (Claude Code, Copilot, Kiro). Works without Nix; Nix
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

    # Kiro
    cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/

    # GitHub Copilot
    cp -r packages/stacked-workflows/skills/stack-* .github/skills/
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
      copilot.enable = true;
      kiro.enable = true;
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

    See [Home-Manager Setup](docs/src/getting-started/home-manager.md) for
    the full guide.

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
      imports = [inputs.nix-agentic-tools.devenvModules.default];

      ai.claude.enable = true;

      claude.code = {
        mcpServers.github-mcp = {
          type = "stdio";
          command = "github-mcp-server";
          args = ["--stdio"];
        };
      };
    }
    ```

    See [DevEnv Setup](docs/src/getting-started/devenv.md) for the full
    guide.

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
    | `stacked-workflows-content` | Skills, references, and routing-table fragment |

    Content packages are derivations with `passthru.fragments` for
    composable instruction building. See
    [Fragments & Composition](docs/src/concepts/fragments.md).

    </details>

    ## Feature Matrix

    <!-- prettier-ignore -->
    | Feature | Without Nix | Home-Manager | DevEnv |
    |---------|-------------|--------------|--------|
    | Stacked workflow skills | Copy skills/ | `stacked-workflows.enable` | `ai.skills.*` |
    | MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
    | MCP server config | Manual JSON | `services.mcp-servers.*` | `claude.code.mcpServers.*` |
    | Typed MCP settings | N/A | Per-server typed options | N/A (raw JSON) |
    | MCP credentials | Manual env vars | `file` or `helper` | Manual env vars |
    | Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
    | Unified AI config | N/A | `ai.*` fans out to all CLIs | `ai.*` fans out to all CLIs |
    | LSP server config | N/A | `ai.lspServers.*` | `ai.lspServers.*` |
    | Fragment composition | N/A | `lib.compose` | `lib.compose` |

    ## Configuration

    <details>
    <summary><strong>Unified ai.* Module</strong></summary>

    Single source of truth for shared config across Claude, Copilot, and
    Kiro. Settings fan out at `mkDefault` priority — per-CLI overrides
    always win.

    ```nix
    ai = {
      claude.enable = true;
      copilot.enable = true;

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

      settings = {
        model = "claude-sonnet-4";
        telemetry = false;
      };
    };
    ```

    See [The Unified ai.\* Module](docs/src/concepts/unified-ai-module.md)
    for the full fanout behavior and mapping table.

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

    See [MCP Server Configuration](docs/src/guides/mcp-servers.md) for
    per-server settings and credential patterns.

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

    See [Stacked Workflows](docs/src/guides/stacked-workflows.md) for git
    presets and skill details.

    </details>

    ## Documentation

    Full documentation is available in `docs/`:

    ```bash
    # Preview locally (requires mdbook)
    mdbook serve docs/

    # Or with devenv
    devenv up  # starts docs server at localhost:3000
    ```

    - [Getting Started](docs/src/getting-started/choose-your-path.md)
    - [Core Concepts](docs/src/concepts/unified-ai-module.md)
    - [Guides](docs/src/guides/home-manager.md)
    - [API Reference](docs/src/reference/lib-api.md)
    - [Troubleshooting](docs/src/troubleshooting.md)

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
    devenv up docs        # start doc preview at localhost:3000
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
    devenv tasks run update:all   # update all nvfetcher sources and lock files
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
    treefmt              # format and lint everything
    treefmt <file>       # format a single file after editing
    ```

    All commits must pass `nix flake check` (includes formatting, linting,
    spelling, structural checks, and module evaluation).

    ${commitConvention}

    ## Adding a Package

    ### AI CLI or MCP Server

    See the **AI CLI Packages** and **MCP Server Packages** sections in
    [AGENTS.md](AGENTS.md) for the full overlay pattern, nvfetcher
    integration, and step-by-step instructions.

    ### General pattern

    1. Add an nvfetcher entry in `nvfetcher.toml`
    2. Run `nvfetcher` to update the generated sources
    3. Create `packages/<group>/<name>.nix` using the appropriate builder
    4. Register in `packages/<group>/default.nix`
    5. Export in `flake.nix` under `packages`
    6. Add a module under `modules/` (HM) and `modules/devenv/` (devenv)
    7. Run `nix flake check` to verify

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
    | Published SWS routing table | `packages/stacked-workflows/fragments/<name>.md` | Yes |

    To add a dev-only fragment:

    1. Create `dev/fragments/<pkg>/<name>.md`
    2. Add the name to `devFragmentNames.<pkg>` in `dev/generate.nix`
    3. Run `devenv tasks run generate:instructions` to regenerate

    To add a published fragment (consumed by external users):

    1. Create `packages/<pkg>/fragments/<name>.md`
    2. Register it in `packages/<pkg>/default.nix` under `passthru.fragments`
    3. Run `devenv tasks run generate:all` to regenerate everything

    ## Pull Requests

    <!-- TODO: refine with maintainer input -->

    - One logical change per PR
    - CI must pass (formatting, linting, spelling, module evaluation)
    - Generated files (CLAUDE.md, AGENTS.md, README.md, CONTRIBUTING.md,
      Copilot and Kiro instruction files) must be regenerated if their
      source fragments changed: run `devenv tasks run generate:all`
    - Keep commits atomic using the stacked workflow skills
      (`/stack-plan`, `/stack-fix`, `/stack-submit`)
  '';
in {
  inherit agentsMd claudeFiles claudeMd contributingMd copilotFiles kiroFiles readmeMd;
}
