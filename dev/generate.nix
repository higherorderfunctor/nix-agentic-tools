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
  mkDevFragment = pkg: name:
    fragments.mkFragment {
      text = builtins.readFile ./fragments/${pkg}/${name}.md;
      description = "dev/${pkg}/${name}";
      priority = 5;
    };

  # ── Package path scoping (for ecosystem frontmatter) ─────────────────
  packagePaths = {
    ai-clis = ''"modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"'';
    mcp-servers = ''"modules/mcp-servers/**,packages/mcp-servers/**"'';
    monorepo = null;
    stacked-workflows = ''"packages/stacked-workflows/**"'';
  };

  # ── Dev fragment names per package ───────────────────────────────────
  devFragmentNames = {
    ai-clis = ["packaging-guide"];
    monorepo = [
      "build-commands"
      "change-propagation"
      "generation-architecture"
      "linting"
      "naming-conventions"
      "nix-standards"
      "project-overview"
    ];
    mcp-servers = ["overlay-guide"];
    stacked-workflows = ["development"];
  };

  # ── Extra published fragments per package (beyond commonFragments) ───
  extraPublishedFragments = {
    monorepo = swsFragments;
    stacked-workflows = swsFragments;
  };

  # ── Compose fragments for a dev package profile ──────────────────────
  mkDevComposed = package: let
    devFrags = map (mkDevFragment package) (devFragmentNames.${package} or []);
    extraFrags = extraPublishedFragments.${package} or [];
  in
    fragments.compose {fragments = commonFragments ++ extraFrags ++ devFrags;};

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
  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";

  # ── AGENTS.md content ────────────────────────────────────────────────
  agentsContent = let
    packageContents = lib.mapAttrsToList (pkg: _: let
      pkgOnly = fragments.compose {
        fragments = map (mkDevFragment pkg) (devFragmentNames.${pkg} or []);
      };
    in
      pkgOnly.text)
    nonRootPackages;
  in
    rootComposed.text
    + lib.optionalString (packageContents != [])
    ("\n" + builtins.concatStringsSep "\n" packageContents);

  # ── Claude rule files ────────────────────────────────────────────────
  claudeFiles =
    {
      "common.md" = monorepoEco.claude rootComposed;
    }
    // (lib.concatMapAttrs (pkg: _: let
        composed = mkDevComposed pkg;
        pkgEco = mkEcosystemFile pkg;
      in {
        "${pkg}.md" = pkgEco.claude composed;
      })
      nonRootPackages);

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
      "common.md" = aiTransforms.kiro {name = "common";} rootComposed;
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

    ${agentsContent}
  '';

  claudeMd = ''
    # CLAUDE.md

    @AGENTS.md

    ${rootComposed.text}
  '';
  # ── README.md generation ─────────────────────────────────────────────

  # ── Static description mappings ──────────────────────────────────────
  # Using explicit descriptions rather than meta.description because
  # README wording may differ from upstream/nixpkgs descriptions.

  mcpServerMeta = {
    context7-mcp = {
      description = "Library documentation lookup";
      credentials = "None";
    };
    effect-mcp = {
      description = "Effect-TS documentation";
      credentials = "None";
    };
    fetch-mcp = {
      description = "HTTP fetch + HTML-to-markdown";
      credentials = "None";
    };
    git-intel-mcp = {
      description = "Git repository analytics";
      credentials = "None";
    };
    git-mcp = {
      description = "Git operations";
      credentials = "None";
    };
    github-mcp = {
      description = "GitHub platform integration";
      credentials = "Required";
    };
    kagi-mcp = {
      description = "Kagi search and summarization";
      credentials = "Required";
    };
    mcp-language-server = {
      description = "LSP-to-MCP bridge";
      credentials = "None";
    };
    mcp-proxy = {
      description = "stdio-to-HTTP bridge proxy";
      credentials = "None";
    };
    nixos-mcp = {
      description = "NixOS and Nix documentation";
      credentials = "None";
    };
    openmemory-mcp = {
      description = "Persistent memory + vector search";
      credentials = "None";
    };
    sequential-thinking-mcp = {
      description = "Step-by-step reasoning";
      credentials = "None";
    };
    serena-mcp = {
      description = "Codebase-aware semantic tools";
      credentials = "Optional";
    };
    sympy-mcp = {
      description = "Symbolic mathematics";
      credentials = "None";
    };
  };

  gitToolDescriptions = {
    agnix = "Linter, LSP, and MCP for AI config files";
    git-absorb = "Automatic fixup commit routing";
    git-branchless = "Anonymous branching, in-memory rebases";
    git-revise = "In-memory commit rewriting";
  };

  aiCliDescriptions = {
    claude-code = "Claude Code CLI";
    github-copilot-cli = "GitHub Copilot CLI";
    kiro-cli = "Kiro CLI";
    kiro-gateway = "Python proxy API for Kiro";
  };

  skillDescriptions = {
    stack-fix = "Absorb fixes into correct stack commits";
    stack-plan = "Plan and build a commit stack from description or existing commits";
    stack-split = "Split a large commit into reviewable atomic commits";
    stack-submit = "Sync, validate, push stack, and create stacked PRs";
    stack-summary = "Analyze stack quality, flag violations, produce planner-ready summary";
    stack-test = "Run tests or formatters across every commit in a stack";
  };

  # ── Table generators ─────────────────────────────────────────────────
  mcpServerNames = lib.sort lib.lessThan (builtins.attrNames mcpServerMeta);
  mcpServerCount = builtins.length mcpServerNames;
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
      enable = true;
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

      ai = {
        enable = true;
        claude.enable = true;
      };

      claude.code = {
        enable = true;
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
      enable = true;
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
in {
  inherit agentsMd claudeFiles claudeMd copilotFiles kiroFiles readmeMd;
}
