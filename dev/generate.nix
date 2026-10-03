# Content for this repository's agent instructions and front-door documents.
#
# This file PRODUCES CONTENT. It writes no instruction file: `dev/ai.nix` hands
# `context` and `rules` to the `ai.*` module, which owns and writes every
# runtime's files exactly as it would for any consumer. Only the two human
# documents, which are not agent steering, are rendered here.
#
# Takes { lib, pkgs } where pkgs has all content overlays applied
# (coding-standards, stacked-workflows).
#
# Returns:
#   context        — the always-loaded orientation (`ai.context.text`)
#   rules          — one path-scoped rule per registry category:
#                    { text; matcher; references; } (`ai.rules`)
#   readmeMd       — README.md content string
#   contributingMd — CONTRIBUTING.md content string
{
  lib,
  pkgs,
}: let
  fragments = import ../lib/fragments.nix {inherit lib;};

  # Owner metadata uses the same registry as the public flake assembly.
  registry = import ../lib/facets/registry.nix {
    inherit lib;
    root = ../.;
  };
  fragmentCategories = registry.config.fragments.categories;

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
      else "packages/${dir}/docs/${name}.md";
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
  # The always-loaded routing rules (delegate routing, stacked-workflow skill
  # routing) are not orientation text: `ai.*` delivers each as a rule of its
  # own, from the same source the programs use.
  extraPublishedFragments = {
    stacked-workflows = swsFragments;
  };

  # ── Compose fragments for a dev package profile ──────────────────────
  # The monorepo (root) profile includes shared content (coding standards,
  # commit conventions, etc. from commonFragments) because its output is
  # the always-loaded context. Scoped profiles include ONLY their
  # scope-specific content — repeating the shared content in every scoped
  # rule amplifies context rot (duplicate tokens loaded when a scoped rule
  # triggers alongside the always-loaded context).
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

  # ── Instruction content ──────────────────────────────────────────────
  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") fragmentCategories;

  # The always-loaded orientation. Every runtime receives it through
  # `ai.context`; Codex, Kiro and Kimchi share it in AGENTS.md.
  context =
    ''
      # nix-agentic-tools

      Project instructions for AI coding assistants working in this repository.

    ''
    + (mkDevComposed "monorepo").text;

  # One rule per scoped category. `matcher` is the registry's scope globs,
  # which each runtime lowers to its own scoping (Claude `paths:`, Copilot
  # `applyTo:`, Kiro `fileMatchPattern`). `references` names the source
  # documents: Codex, which has no path scoping, lists the rule in AGENTS.md's
  # path-scoped index with links to them instead of inlining every body. Link
  # the SOURCES, not runtime projections: they exist in every checkout, and a
  # projection is regenerated over any edit.
  rules =
    lib.mapAttrs (category: record: {
      inherit (mkDevComposed category) text;
      matcher = record.scopes;
      references = map (entry: (normalizeDevFragmentSource category entry).repoRelative) (record.sources or []);
    })
    nonRootPackages;

  mkInlineCodeList = values:
    lib.concatMapStringsSep ", " (value: "`${value}`") values;
  # Read from Kimchi's extracted sidecar, the same list devenv rejects.
  kimchiUserScopeHarnessKeys =
    (import ../packages/kimchi/lib/extracted.nix {
      inherit lib pkgs;
      extracted = builtins.fromJSON (builtins.readFile ../packages/kimchi/extracted.json);
    }).userScopeHarnessKeys;

  # ── README.md generation ─────────────────────────────────────────────

  # Descriptions are authored alongside their packages.
  data = registry.config.documentation;
  inherit (data) aiCliDescriptions devToolDescriptions genericDescriptions gitToolDescriptions mcpServerMeta skillDescriptions;
  mcpServerCount = builtins.length (builtins.attrNames mcpServerMeta);

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
    unlocks overlays, home-manager modules, and devenv modules.

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
      programs.delegate-routing.enable = true;
      programs.stacked-workflows.enable = true;
      settings.reasoningEffort = "high";
    };

    # Git companion: mkDefault values on the git.* options, which Home Manager
    # applies user-global and devenv at repository scope.
    stacked-workflows.gitPreset = "full";

    services.mcp-servers.servers.github-mcp = {
      enable = true;
      settings.credentials.file = "/run/secrets/github-token";
    };
    ```

    > **Static runtime files:** every runtime exposes
    > `ai.<runtime>.files."<relative-path>" = { text = "…"; };`. An entry can
    > instead set `source = ./file`. Generated context/rule outputs use the same final map at default
    > priority, so an ordinary whole entry replaces them and `null` suppresses
    > them. Paths are relative to HOME here and to the project under devenv.

    </details>

    <details open>
    <summary><strong>DevEnv (per-project dev shell)</strong></summary>

    ```yaml
    # devenv.yaml
    inputs:
      nix-agentic-tools:
        url: github:higherorderfunctor/nix-agentic-tools
    ```

    ```nix
    # devenv.nix
    {inputs, ...}: {
      imports = [inputs.nix-agentic-tools.devenvModules.nix-agentic-tools];

      # The overlay is required when a runtime installs its default package
      # (`pkgs.ai.*`) because the module does not apply it itself.
      # `package = null` configures a runtime without installing one.
      overlays = [inputs.nix-agentic-tools.overlays.default];

      ai = {
        claude.enable = true;
        codex.enable = true;

        mcpServers.github-mcp = {
          type = "stdio";
          command = "github-mcp-server";
          args = ["--stdio"];
        };
      };
    }
    ```

    </details>

    ### Package sets and toolchains

    The overlay builds recipes with your nixpkgs package set. Your overrides and
    `allowUnfree` policy apply. Go and Rust compilers come from this flake's locked
    toolchain inputs, constructed over your package set.

    `packages.<system>` uses this flake's `nixpkgs` input with
    `config.allowUnfree = true`, so named proprietary CLIs work with `nix run`.
    Their licenses remain labelled unfree. Use the overlay to apply your own unfree
    policy. Setting `inputs.nix-agentic-tools.inputs.nixpkgs.follows = "nixpkgs"`
    is supported; toolchain inputs can also follow your own inputs.

    Cache reuse depends on matching derivation inputs. A different nixpkgs or
    consumer override can require a rebuild.

    ## Skills

    Delegate routing for models and effort, plus stacked commit workflows using
    git-branchless, git-absorb, and git-revise.

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

    The same `git.*` options exist on Home Manager and devenv. Each tool's
    settings are typed from a census of its source and mirror the git key;
    `enable` installs the tool:

    ```nix
    git = {
      absorb = {
        enable = true;
        settings.maxStack = 50; # absorb.maxStack
      };
      branchless = {
        enable = true; # devenv also runs `git branchless init` on entry
        scopedSync = true; # bare `git sync` moves the current stack only
        settings.test.strategy = "worktree"; # branchless.test.strategy
      };
      settings.merge.conflictStyle = "zdiff3"; # any other git key
    };
    ```

    Home Manager delivers them through `programs.git.settings` (`git.settings`
    is an alias of it). devenv writes a repository-local include kept after
    every other repository setting, so its values win key by key over
    user-global ones and hand edits, while keys it does not set fall through.

    </details>

    <details>
    <summary><strong>Dev Tools</strong></summary>

    Agent-adjacent development utilities exposed as `pkgs.ai.devTools.*`.

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

    Temporarily unclassified supporting packages live in the split-ready
    `packages/<owner>/packages/ai/generic/` trees and are exposed as `pkgs.ai.generic.*`.

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
    | `delegate-routing-content` | Per-runtime model/effort sizing skills and a short routing rule |
    | `stacked-workflows-content` | Skills, references, and skill-routing fragment |

    Content packages are derivations with `passthru.fragments` for
    composable instruction building.

    </details>

    ## Feature Matrix

    <!-- prettier-ignore -->
    | Feature | Without Nix | Home-Manager | DevEnv |
    |---------|-------------|--------------|--------|
    | Delegate routing | Copy a generated runtime skill | `ai.programs.delegate-routing.enable` (Claude + Codex + Kiro) | Same; project-native paths |
    | Stacked workflow skills | Copy skills/ | `ai.programs.stacked-workflows.enable` | `ai.programs.stacked-workflows.enable` |
    | MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
    | Unified MCP config | Manual native config | `ai.mcpServers.*` (all five CLIs) | `ai.mcpServers.*` (all five CLIs) |
    | Typed MCP settings | N/A | Shared schema + native extensions | Shared schema + native extensions |
    | MCP credentials | Manual env vars | `plain`, `file`, or `helper` | `plain`, `file`, or `helper` |
    | Semble search integrations | Manual install | `ai.programs.semble` (Claude + Codex + Kiro) | Same; project-native paths |
    | Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
    | Git configuration | `git config` | `git.settings` + typed `git.{branchless,absorb,revise}.settings` → `programs.git.settings` | Same options; a repository-local include that wins key by key |
    | GitLab CLI config | `glab config set` | `glab.*` | `glab.*` |
    | GitLab CLI credentials | Manual env vars | `plain`, `file` or `helper` | `plain`, `file` or `helper` |
    | Context and rules | Copy native files | `ai.{context,rules}` (runtime capability-gated) | Same; project-native paths. Files a repository commits (AGENTS.md, `.github/` instructions) and Kiro steering are read-only copies, not store links |
    | Generated files | N/A | `ai.formatter`, `ai.guards.<name>`, and `ai.checks` (Nix-owned build-time files; formatters exclude supplied skill trees, checks include their generated entries; runtime-rendered files excluded) | Same; project-native static files included |
    | Skills | Copy native directories | `ai.skills.*` (all five CLIs) | Same; project-native paths |
    | Portable reasoning effort | Per-CLI config | `ai.settings.reasoningEffort` (Claude + Codex + Copilot + Kimchi) | Same; Copilot's lands in `.github/copilot/settings.json`, which only its interactive session reads, Kimchi's in its project harness settings (see below). Kiro has only per-model native effort |
    | Semantic agents | Per-CLI config | `ai.agents.*` (Claude + Codex + Copilot + Kimchi + Kiro) | Same; project-native paths |
    | Portable lifecycle hooks | Per-CLI config | `ai.hooks.*` (Claude + Codex) | Same, plus Kimchi's project `.kimchi/hooks.json` |
    | LSP server config | Per-CLI config | `ai.lspServers.*` (Claude + Copilot + Kiro) | Copilot + Kiro; Claude has no project LSP route (warns); Codex has no native LSP registry |
    | CLI process environment | Shell config | `ai.environmentVariables` (Codex + Copilot + Kimchi + Kiro) | Same; baked into each launcher wrapper, never the shell. Claude uses `ai.claude.native.settings.env` |
    | Command shell | Per-CLI config or `$SHELL` | `ai.shell` / `ai.<cli>.shell` (Claude + Codex + Kiro) | Same; takes a package. Copilot and Kimchi are explicit exclusions |
    | Fragment composition | N/A | `lib.ai.compose` | `lib.ai.compose` |

    ### Kimchi project delivery

    | Pool | devenv delivery | Boundary |
    | ---- | --------------- | -------- |
    | Context | root `AGENTS.md` | Available without project trust; reader walks ancestors, but the wrapper remains root-only |
    | MCP servers | `.kimchi/mcp.json` | Requires project trust and launch from the devenv root |
    | Kimchi settings | `.kimchi/config.json` | Requires project trust and launch from the devenv root; an owner-only copy. `region` and `telemetry.enabled` reach Kimchi through the launcher environment instead |
    | Skills | `.kimchi/skills` | Requires project trust; nearest ancestor wins, but the wrapper remains root-only |
    | Project harness settings | `.config/kimchi/harness/settings.json` | Requires project trust and launch from the devenv root; user-scope-only keys are rejected during evaluation. `ai.settings.reasoningEffort` lands here as `defaultThinkingLevel`, so setting it alone creates the file |
    | Agents | `.kimchi/agents/<name>.md` | Requires project trust and launch from the devenv root; Kimchi's /agents commands cannot edit a declared agent |
    | Permissions | `.kimchi/permissions.json` | Requires project trust and launch from the devenv root |
    | Hooks | `.kimchi/hooks.json` | Requires project trust and launch from the devenv root; PermissionRequest is not a Kimchi event and is left out. Home Manager has no user-scope hook file it can own, so shared `ai.hooks` do not reach Kimchi there (silently) and `ai.kimchi.hooks` warns |

    devenv rejects Kimchi's user-scope-only harness settings:
    ${mkInlineCodeList kimchiUserScopeHarnessKeys}. Set those with Home
    Manager or through Kimchi itself. Every project file is a read-only copy,
    written only when something is declared; an in-app change Kimchi renames
    over one is backed up and replaced at the next shell entry.

    Kimchi's user-global files live under `~/.config/kimchi`, which devenv never
    writes. Who manages each setting there depends on whether you use Home
    Manager:

    | User-global setting | Home Manager | devenv only |
    | ------------------- | ------------ | ----------- |
    | Harness `settings.json` | Nix owns the keys it declares inside Kimchi's own file; `/model` and other in-app writes persist | Kimchi |
    | `mcp.json`, `permissions.json` | Nix, as read-only copies; in-app changes are reset at the next activation | Kimchi |
    | Project trust (`harness/trust.json`) | Nix (`ai.kimchi.projectTrust`); `defaultProjectTrust = "never"`, and `/trust` cannot persist (it may exit) | Kimchi's trust prompt |
    | `telemetry.enabled`, `region` | Nix; telemetry defaults off, region must be declared, and Kimchi reads both from global `config.json` | Kimchi, unless declared: then the launcher passes the Nix value |
    | `skillPaths` | Nix; default skill paths include the ai.* directory | Kimchi |
    | API key | Nix when `ai.kimchi.apiKey` is set (read from its secret at launch, so an in-app login has no effect); otherwise `/login`, which persists in `config.json` beside the Nix-owned keys | Same as Home Manager |
    | Git tokens | Nix for each host in `ai.kimchi.gitTokens` (read from secrets at activation), which makes `config.json` a read-only copy again, so `/login` stops persisting; Kimchi for the rest | Kimchi |
    | `config.json` migration, onboarding and survey markers | Kimchi; they persist beside the Nix-owned keys | Kimchi |
    | Device id | Kimchi; none is written while telemetry is off | Kimchi |

    Project settings, MCP servers, harness settings, permissions, agents, and
    hooks resolve under the exact working directory. The devenv wrapper rejects descendant launches
    instead of silently missing them. Context and skills walk ancestors, so a
    devenv that declares none of the exact-cwd files leaves the launch directory
    unrestricted.
    `skillPaths` defaults to unset: Kimchi reads the project list in place of
    the user's global one, so only an explicit list, empty included, replaces
    it.

    Trust gates every project-scope reader except root `AGENTS.md`. On a Home
    Manager machine, declare the root or a parent in `ai.kimchi.projectTrust`
    before a devenv project's Kimchi config is read. Without Home Manager,
    grant trust at Kimchi's prompt; `--approve` is a run-scoped CLI/TUI
    override, while ACP resolves trust separately.

    ### Copilot user-global settings

    Copilot's user-global files live under `~/.copilot`, which devenv never
    writes. Who manages each one depends on whether you use Home Manager:

    | User-global setting | Home Manager | devenv only |
    | ------------------- | ------------ | ----------- |
    | `settings.json`, `mcp-config.json`, `lsp-config.json` | Nix, as read-only copies (empty when nothing is declared); in-app changes such as `/model` or `copilot mcp add` are reset at the next activation | Copilot |
    | Trusted folders (`trustedFolders` in `config.json`) | Nix (`ai.copilot.trustedFolders`, absolute paths; a folder covers its subfolders); a folder trusted at Copilot's prompt stays trusted only until the next activation | Copilot's trust prompt |
    | Sign-in, tokens, session and acknowledgement state (the rest of `config.json`) | Copilot | Copilot |

    devenv writes the repository `.github/copilot/settings.json` as a read-only
    copy only when `ai.copilot.native.settings` declares something, and rejects
    `ai.copilot.trustedFolders`. Copilot reads that repository file only in a
    trusted folder: with Home Manager, add the clone (or a parent folder) to
    `ai.copilot.trustedFolders`; without it, trust the project at Copilot's
    prompt.

    ## Configuration

    <details>
    <summary><strong>Unified ai.* Module</strong></summary>

    Single source of truth for shared config across Claude, Codex, Copilot,
    Kimchi, and Kiro. Only semantics a runtime can preserve fan out; the feature
    matrix above names deliberate exclusions. Scalar defaults use `mkDefault`
    priority, so per-CLI overrides always win.

    ```nix
    ai = {
      claude.enable = true;
      codex.enable = true;
      copilot.enable = true;
      kimchi.enable = true;
      kiro.enable = true;

      skills.my-skill = ./skills/my-skill;

      rules.standards = {
        text = "Use strict mode everywhere";
        matcher = ["src/**"];
        description = "Project standards";
      };

      lspServers.nixd = {
        package = pkgs.nixd;
        extensions = ["nix"];
      };

      settings.reasoningEffort = "high";

      # Runtime-native escape hatch: model identifiers are not portable.
      codex.native.settings.model = "gpt-5.6-sol";
    };
    ```

    A scoped rule can also name the documents that hold its text in
    `references`. Runtimes with path scoping ignore them; Codex, which reads
    one flat `AGENTS.md`, lists such a rule in a compact path-scoped index
    (globs plus links) instead of inlining its body into every turn.

    Enabling any harness also installs a sandbox-safe Git SSH default. It
    preserves Home Manager's `~/.ssh/config` host/key routing when a Linux
    user-namespace sandbox remaps the Nix-store target's owner; devenv exports
    the same wrapper as `GIT_SSH_COMMAND`, so ordinary dev-shell Git and
    harness-launched Git behave the same. OpenSSH batch mode makes missing
    credentials fail instead of opening a password dialog. Set
    `ai.gitSshConfigWorkaround = false` to manage this yourself.

    Codex supports either the legacy `sandbox_mode` model or named permissions
    through `ai.codex.native.settings.default_permissions` and
    `ai.codex.native.settings.permissions`. Do not mix those models in any loaded
    config layer. Same-named permission tables merge across user and project
    files. The distinct `ai.codex.profiles` option, which would have
    materialized whole extra files selected with `codex --profile`, was
    removed as unreachable; per-agent visibility belongs to the sandbox-stack
    work instead.

    With legacy `workspace-write`, the module automatically adds the Nix cache
    and, under devenv, the current repository's `.git`. With a selected custom
    permission profile, integration-owned roots become direct filesystem writes
    in that profile. Integration modules add their own state only when enabled:
    Semble adds its cache and glab adds its effective `configDir`. Explicit rules
    in the same emitted layer win at identical paths. A parent containing
    multiple worktrees remains an explicit consumer root.

    > **Kiro steering-copy upgrade:** when upgrading from a release that
    > materialized steering as real copies, keep the previous
    > `ai.kiro.configDir` for one Home Manager activation or devenv shell entry.
    > The manifest-guarded retirement runs even when `ai.kiro.enable = false`.
    > If a custom `configDir` must change or be removed, perform that retirement
    > generation first, then change the directory; the legacy manifest records
    > owned filenames and hashes, but not an invertible target path, so a later
    > generation cannot safely infer the old custom directory.

    </details>

    <details>
    <summary><strong>Generated-file formatting</strong></summary>

    Every live, Nix-owned whole file whose bytes exist at build time is built
    into one store tree per delivery-router invocation. The flake's exported
    `treefmtModules.default` is always the base; the consumer's `ai.formatter`
    treefmt-nix module is layered on top. One treefmt run formats every composed
    file, including Markdown headers. Each formatted path must use the
    conventional extension for its declared format (`.json`, `.md`, `.toml`,
    `.yaml`, or `.yml`). An unmatched composed file fails the build and names
    its target-relative path. Raw files and recursive directory sources are
    copied byte-identically and never passed to treefmt. A failed formatter or
    check fails the build.

    On devenv, every delivered path is automatically excluded from the
    repository's own treefmt run. Other module consumers can use the read-only
    `ai.deliveredPaths` list for the same purpose.

    Generated-file checks form a three-tier default chain, all with
    `types.lines`: `ai.checks.all`, `ai.checks.<surface>`, then
    `ai.<runtime>.checks.<surface>`. The seven surfaces are `agents`, `context`,
    `hooks`, `mcpServers`, `rules`, `settings`, and `skills`. Only the resolved
    runtime-and-surface leaf runs; shared internal documents run the root surface
    tier with `AI_RUNTIME=internal`. Defining a lower tier replaces its inherited
    default; splice `''${config.ai.checks.all}` or the surface tier into a lower
    definition when composition is wanted. There is no per-runtime `all` tier.

    A non-empty snippet runs once for each surface represented in the built
    runtime tree, with the tree root as its working directory, that surface's
    target-relative paths in `"$@"`, and `AI_RUNTIME` exported to the runtime
    name. Empty snippets and surfaces with no files do not run. Checks see only
    build-time whole files. Generated raw skill entries participate even though
    formatters skip their bytes; runtime-rendered files, shared reconciled
    documents, and unstamped raw `ai.<runtime>.files` entries do not. Checks run
    in the Nix build sandbox, so only store-provided tools are available and
    network access is unavailable.

    ```nix
    ai.checks = {
      all = "test -n \"$AI_RUNTIME\"";
      rules = config.ai.checks.all + "\n''${pkgs.ai.devTools.markdownlint-cli2}/bin/markdownlint-cli2 \"$@\"";
    };
    ```

    Supply a treefmt-nix module to customize generated-file formatting:

    ```nix
    ai.formatter = ./treefmt.nix;
    ```

    Generated context, rules, AGENTS.md and agent Markdown participate on both
    Home Manager and devenv, including Claude's direct Home Manager files.
    Static JSON, TOML and YAML entries participate when their file entry names
    the corresponding `format`; raw files and supplied directory trees
    participate without a formatter. Switch-time overlays and private documents
    rendered by `content.run` are excluded because their final bytes do not
    exist at build time. Shared document entries are excluded because they own
    reconciled leaves rather than a whole file.

    | Runtime | Static JSON/TOML/YAML in scope | Outside the build tree |
    | ------- | ------------------------------ | ---------------------- |
    | Claude | `settings.json` on both backends; devenv `.mcp.json`; Home Manager plugin `.mcp.json`, `.lsp.json` and manifest | `.claude.json` shared mutable state |
    | Codex | Agent TOML files, `hooks.json`, both `config.toml` locations, Home Manager daemon settings | Runtime-rendered files |
    | Copilot | Home Manager `lsp-config.json`; devenv `.github/lsp.json`; `mcp-config.json`; both `settings.json` locations | Home Manager `config.json` shared trust and state |
    | Kimchi | Static config, harness settings, MCP, permissions and devenv hooks | `trust.json` and credential-rendered `config.json` |
    | Kiro | `cli.json`, `lsp.json`, Home Manager `permissions.yaml`, agent and hook JSON files | Runtime-rendered `mcp.json` |

    A single file can opt out of formatting and guards with
    `ai.<runtime>.files."<path>".format = "raw"`; it remains in the store tree.
    Byte limits still apply to opted-out paths. A `content.run` replacement of a
    generated entry requires `format = "raw"`; replacing an entire AGENTS.md
    entry may state `format = "markdown"` to retain formatting.

    `mkAgenticShell` generates no files in this delivery router, so it has no
    corresponding option.

    </details>

    ### `ai.guards`

    Guards check semantic and structural properties independently of the
    selected formatter and of `ai.checks`. They use this flake's pinned tools.
    Each guard can be disabled by name. `splitCodeSpans` and
    `tableCells` default to enabled only when the mounted `ai.formatter` enables
    Prettier; the other guards default to enabled.

    | Guard | What it catches | Disable |
    | ----- | --------------- | ------- |
    | `kiroFrontmatterFlow` | Multi-line YAML flow sequences in Markdown frontmatter after formatting; Kiro only | `ai.guards.kiroFrontmatterFlow = false;` |
    | `parseCompare` | Invalid or changed JSON, TOML or YAML data; changed parsed Markdown frontmatter values, after formatting | `ai.guards.parseCompare = false;` |
    | `splitCodeSpans` | A newline inside a Markdown inline code span in the input, before formatting | `ai.guards.splitCodeSpans = false;` |
    | `tableCells` | Inconsistent input Markdown table cells before formatting; rumdl and markdownlint catch different forms | `ai.guards.tableCells = false;` |

    The builder formats whole Markdown files, including their YAML headers.
    `parseCompare` compares parsed frontmatter values, allowing presentation
    changes such as re-quoting while rejecting changed data. Files without
    frontmatter compare as `null`. JSON, TOML and YAML also compare parsed values.

    For example, these formatter outcomes differ:

    | Example | Guard result | Reason |
    | ------- | ------------ | ------ |
    | Default Biome JSON and Taplo TOML | Good | They change presentation while preserving parsed values |
    | Default Prettier Markdown and YAML | Good | Whole files are formatted while parsed values stay unchanged |
    | A formatter that changes JSON `true` to `false` | Bad | `parseCompare` detects changed data |
    | Input with an unescaped pipe inside a Markdown table cell | Bad | `tableCells` detects an extra input cell |

    A format guard error names what failed and why, then gives three choices:
    fix the input or formatter; disable that named guard if its invariant is
    unsuitable; or set the specific file's `format = "raw"` to opt out
    explicitly. The Kiro shape guard offers only fix or disable because a
    runtime still reads a raw file.

    #### Using the guards on your own files

    The same guards are exported as `lib.ai.guards pkgs` for files you author.
    `pkgs` must include this flake's overlay for rumdl and markdownlint-cli2.
    `tableCells` reports MD056 only. Configuration files in the checked tree
    cannot change it; inline lint suppression comments still apply.

    | Attribute | Program | Arguments |
    | --------- | ------- | --------- |
    | `kiroFrontmatterFlow` | `ai-guard-kiro-frontmatter-flow` | Markdown file paths |
    | `parseCompare` | `ai-guard-parse-compare` | `TYPE BEFORE AFTER`, where `TYPE` is `json`, `markdown`, `toml` or `yaml` |
    | `splitCodeSpans` | `ai-guard-split-code-spans` | Markdown file paths |
    | `tableCells` | `ai-guard-table-cells` | Markdown file paths |
    | `check` | Markdown shape guards in one derivation; `kiroFrontmatterFlow` is on by default for files under `<kiroDir>/steering/` and `<kiroDir>/agents/` | `{ src; guards ? {}; kiroDir ? ".kiro"; }` |

    `check` is a build-time gate for `nix flake check` or CI. It returns a
    derivation that runs `splitCodeSpans` and `tableCells` over every `*.md`
    under `src` and fails the build on a finding. `kiroFrontmatterFlow` is on
    by default for Markdown in `<kiroDir>/steering/` recursively and directly
    in `<kiroDir>/agents/`, wherever that layout occurs under `src`.
    `kiroDir` defaults to `.kiro`; an empty Kiro selection passes.
    It checks the store copy of `src`, not the files you staged, so it is
    not a pre-commit hook:

    ```nix
    checks.''${system}.markdown-guards =
      (inputs.nix-agentic-tools.lib.ai.guards pkgs).check {
        src = ./docs;
        # kiroDir = "custom"; # select a custom Kiro layout
        # guards.tableCells = false; # disable a guard by name
      };
    ```

    For a pre-commit hook, add the programs to your shell's packages and call
    them on the staged paths:

    ```bash
    git diff --cached --name-only -z --diff-filter=d -- '*.md' \
      | xargs -0 -r sh -c 'ai-guard-kiro-frontmatter-flow "$@" && ai-guard-split-code-spans "$@" && ai-guard-table-cells "$@"' _
    ```

    `check` does not run `parseCompare`, because it needs two versions of the
    same file and a source tree holds one. Call it in a hook after your
    formatter rewrites a file: pass the staged version and the formatted
    result. JSON, TOML and YAML compare parsed values. Markdown compares parsed
    YAML frontmatter values, allowing the formatter to re-present the header.
    A file without frontmatter has the value `null`. Fenced frontmatter must
    close and hold valid YAML between the fences. If BEFORE does not parse,
    nothing is compared and the program exits 2. If AFTER does not parse, that
    is a finding. In a bash hook, a process substitution passes the staged
    version:

    ```bash
    ai-guard-parse-compare yaml <(git show :config.yaml) config.yaml
    ```

    A finding exits 1 and names what failed and why. The format guards offer
    three options, worded for your files: fix the file or formatter; disable the
    guard by name in `check`, or stop running its program; or leave the file out
    of the guarded set. `kiroFrontmatterFlow` offers only fix or disable because
    Kiro still reads a raw file. Exit 2 means nothing was checked, for example
    an unreadable file.

    <details>
    <summary><strong>Semble code search</strong></summary>

    Semble never enables AI runtimes implicitly. The program switch enables its
    package and MCP server; CLI guidance and the `semble-search` subagent are
    independent opt-ins. Separately enable whichever runtimes should consume
    the generated configuration:

    ```nix
    ai.programs.semble.enable = true;

    ai.claude.enable = true;
    ai.codex.enable = true;
    ai.kiro.enable = true;
    ```

    Portable defaults live at `ai.programs.semble`. Each supported runtime has
    the same nullable option tree under `ai.<runtime>.programs.semble`: null
    inherits the root value and a non-null value wins. Program-level enable
    overrides replace runtime lists:

    ```nix
    ai = {
      programs.semble = {
        enable = true;
        cli.instructions.enable = true;
        defaultContent = ["code" "docs"];
        subagent = {
          enable = true;
          interface = "mcp";
        };
      };

      claude.programs.semble.enable = false;
      codex.programs.semble.subagent.enable = true;
      kiro.programs.semble.mcp.enable = false;
    };
    ```

    Claude writes the guidance as the always-on rule file
    `.claude/rules/semble.md`, and Codex inlines it in `AGENTS.md`. Kiro writes
    it to `.kiro/steering/semble.md` under Home Manager and, under devenv,
    where it shares the repository `AGENTS.md`, inlines it there.
    `ai.programs.semble.install = false` keeps every rule but skips installing
    the package, for a shell that must not carry it.

    `models` routes searches across embedding models by content: a search uses
    the entry whose content set equals its `--content` (or `defaultContent`)
    exactly, and `defaultModel` otherwise. The CLI and the MCP server route the
    same way, and the generated guidance tells agents which content has which
    model. Each model is a pinned package such as a
    `lib.packaging.fetchHuggingFaceModel` output:

    ```nix
    ai.programs.semble = {
      models = [
        {
          model = let
            files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
          in
            inputs.nix-agentic-tools.lib.packaging.fetchHuggingFaceModel {
              inherit pkgs files;
              repoId = "minishlab/potion-base-32M";
              rev = "1e5a03f8eeb2c98b928fbbd846f22f816360919f";
              hash = "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=";
              license = lib.licenses.mit;
              # Lets evaluation check the files against model2vec's layouts.
              passthru = {inherit files;};
            };
          content = "docs";
          description = "Prose: READMEs, design notes, architecture docs.";
        }
      ];
      # Files Semble cannot place by suffix. The first matching entry wins.
      pathMappings = [
        {
          language = "json";
          content = "docs";
          patterns = ["docs/*.json"];
        }
        {
          language = "json";
          content = "config";
          patterns = ["*.json" "flake.lock"];
        }
      ];
    };
    ```

    With `mcp.enable = false` and an MCP-backed subagent, Kiro keeps the Semble
    server inside the agent file and out of the root MCP pool. Claude and Codex
    cannot scope a server to one agent, so they fail evaluation instead of
    silently exposing it.

    Home Manager fixes the cache at its owned XDG location. A devenv integration
    relocates it to a project-local state directory and tells Semble where by
    baking `SEMBLE_CACHE_LOCATION` into the launcher wrapper — never into the
    project shell's environment. The relocation is unconditional on devenv;
    only the Codex writable-root grant is conditional, on a selected feature
    targeting Codex in `workspace-write` mode. The module does not select the
    sandbox mode itself.

    Direct configuration remains available when the convenience feature is
    disabled:

    ```nix
    ai.codex = {
      mcpServers.semble =
        inputs.nix-agentic-tools.lib.ai.mcpServers.mkSemble {
          inherit lib pkgs;
        } {
          content = "docs";
        };
      agents.semble-search =
        inputs.nix-agentic-tools.lib.ai.semble.semanticAgent;
      rules.semble = inputs.nix-agentic-tools.lib.ai.semble.rule;
    };

    ai.kiro = {
      native.agents.semble-search =
        inputs.nix-agentic-tools.lib.ai.semble.kiroAgent;
      rules.semble = inputs.nix-agentic-tools.lib.ai.semble.rule;
    };
    ```

    Semble does not declare `ai.copilot.programs.semble`; configure Copilot
    directly through `ai.copilot.*` with the same exported helpers when desired.

    </details>

    <details>
    <summary><strong>Codex config ownership</strong></summary>

    Settings are Nix's alone. Both backends deliver `config.toml` as a read-only
    store symlink: Home Manager always owns the user file under
    `ai.codex.configDir`, and devenv writes the trusted project's
    `.codex/config.toml` when something is declared. Codex refuses to save an in-app
    change into it (`/model`, `/experimental` and `codex mcp add` fail with "failed
    to persist config"), so declare those settings under `ai.codex.native.settings`.

    Project trust lives in that file too. With Home Manager, declare each clone you
    trust:

    ```nix
    ai.codex.native.settings.projects."/home/me/src/my-repo".trust_level = "trusted";
    ```

    Codex matches the working directory or its repository root exactly, and resolves
    a linked worktree to its main checkout, so one entry covers a clone and its
    worktrees. In a directory with no entry the trust prompt cannot save its answer,
    so the interactive session can only quit there; `codex exec` is unaffected.
    Devenv rejects `projects` because project config cannot grant the trust required
    to load itself.

    Codex runs a hook only once its current hash is trusted, and `/hooks` cannot
    record trust into a Nix-owned file. Nix declares the trust of every hook it
    generates: Home Manager in user `config.toml`, devenv through its launcher.
    Declare trust for any other hook, such as a plugin's, in
    `ai.codex.native.settings.hooks.state` with Home Manager.

    Codex's user-global files live under `~/.codex`, which devenv never writes. Who
    manages each setting there depends on whether you use Home Manager:

    | User-global setting                                               | Home Manager                                                                                                  | devenv only                                                                                |
    | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
    | `config.toml`: model, features, MCP servers, preferences          | Nix, as a read-only store symlink; in-app saves fail                                                          | Codex                                                                                      |
    | Project trust (`projects` in `config.toml`)                       | Nix (`ai.codex.native.settings.projects`)                                                                     | Codex's trust prompt                                                                       |
    | Hook trust (`hooks.state` in `config.toml`)                       | Nix for the hooks it generates; `ai.codex.native.settings.hooks.state` for others                             | Codex's `/hooks`, except for the project hooks devenv generates, which its launcher trusts |
    | Daemon settings (`app-server-daemon/settings.json`)               | Nix (`ai.codex.native.daemonSettings`), as a read-only copy; an in-app change is reset at the next activation | Codex; devenv runs Codex without the daemon                                                |
    | Daemon package selection                                          | Nix (`ai.codex.pinDaemonToPackage`)                                                                           | Codex's own updater                                                                        |
    | Saved command approvals (`rules/default.rules`), sign-in, history | Codex                                                                                                         | Codex                                                                                      |

    Upgrading from a release that reconciled `config.toml`: before the first switch,
    move the real `~/.codex/config.toml` aside, along with any `config.toml.hm-bak`
    beside it, and declare your trusted clones. Home Manager refuses to replace a
    real file with its link, and with `backupFileExtension` set an existing backup
    blocks it too.

    Native-only settings remain under `ai.codex.native.settings`. Normalized
    settings live under `ai.codex.settings` and narrow `ai.settings` field by
    field. The named whole-file `ai.codex.profiles` layer was removed as
    unreachable — see the sandbox section above for why. Native Starlark
    command policy uses `ai.codex.execpolicyRules` rather than Markdown
    `ai.rules`.

    Codex 0.157+ runs tool calls in a shared background daemon, which runs
    whatever package `~/.codex/packages/app-server-daemon/current` selects and
    otherwise updates itself from GitHub every hour. Home Manager points that
    selection at `ai.codex.package`, turns the updater off, and stops the daemon
    after a switch that changes the package; `ai.codex.pinDaemonToPackage = false`
    hands it back to upstream. Upstream's copy of this package carries patched
    voice and zsh resources that point into store paths no GC root holds, so they break
    after garbage collection until its updater replaces the copy. Home Manager
    also defaults
    `features.daemon_auto_start` to false, because a daemon keeps the environment
    of whichever session started it. Devenv runs Codex with `--no-daemon`, so
    project sessions use the project shell and the project's Codex version.
    `ai.codex.pinDaemonToPackage` is Home Manager-only and has no devenv
    counterpart at all; devenv rejects `features.daemon_auto_start = true`,
    which would do nothing there.

    </details>

    <details>
    <summary><strong>Claude Delegation-Clamp Mitigation (off by default)</strong></summary>

    Claude Code injects a system-prompt section telling the model not to use
    subagents, workflows, or deep research "unless the user requested it". It is
    gated on a **model capability**, not on your configuration — on for Opus 5 —
    and no setting, flag, or environment variable turns it off. It never appears
    in the transcript, so a session with delegation silently suppressed looks
    identical to a normal one. It also directly contradicts
    `ai.claude.ultracodeOnLaunch`, which asks for the opposite.

    Opting in installs a mitigation that patches nothing: a `UserPromptSubmit`
    hook supplies the request that the clamp's own escape clause is asking for,
    as user-side context. It is injected once per session and re-armed by a
    `PreCompact` hook, so the cost is roughly 75 tokens per session rather than
    per turn.

    ```nix
    ai.claude.delegationClampMitigation = {
      enable = true;          # off by default; set true to enable
      text = "…";             # the standing request — wording is load-bearing
    };
    ```

    Upstream: [anthropics/claude-code#80988](https://github.com/anthropics/claude-code/issues/80988).
    A dated CI step re-surfaces this roughly every 90 days, once
    `config/heron-brook-tripwire.json`'s `reviewBy` passes, so the mitigation
    does not outlive its cause. See
    `packages/claude-code/docs/heron-brook-clamp.md`.

    </details>

    <details>
    <summary><strong>Claude Memory-Collision Guard (off by default)</strong></summary>

    Concurrent Claude Code sessions share one agent-memory directory and neither
    sees the other's writes — no locking, no notification. A session reads the
    memory index once at start, then writes into a directory that may have moved
    underneath it. The failure is silent: a duplicate saved under a *different*
    filename raises no conflict, it just stops being findable, because the
    wikilink graph resolves by name.

    A `PreToolUse` hook on `Write|Edit`, scoped to memory directories, pauses the
    first write to each file per session and hands the model that directory's
    recently-modified neighbours — filename, mtime, and `description:`
    frontmatter, with anything written in the last few minutes flagged as a live
    concurrent session. The model decides whether to extend an existing file or
    proceed; re-issuing the same write goes through.

    ```nix
    ai.claude.memoryCollisionGuard = {
      enable = true;          # default false
      windowMinutes = 10;     # mtime window counted as "a session is active now"
      listCount = 10;         # neighbours to show, most recent first
      extraDirectories = [];  # stores outside <claude config>/projects/*/memory/
    };
    ```

    Off by default because it **blocks a tool call** and its cadence is an
    untuned judgement call, not a measured one. The alternative instrumentation —
    allow the write and inject the listing as `additionalContext`, reactive
    rather than blocking — is documented alongside the chosen one in
    `packages/claude-code/lib/memory-collision-guard.sh`, so revisiting the
    trade-off does not mean re-deriving it.

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
    <summary><strong>Delegate Routing</strong></summary>

    ```nix
    ai.programs.delegate-routing.enable = true;
    ai.claude.programs.delegate-routing = {
      extraRuntimes = ["codex"];
      manualExternalDelegates = ["kiro"];
    };
    ```

    Enable each auto-selectable external runtime with `ai.<runtime>.enable`.
    Manual-only entries require an explicit user request and do not require that
    runtime's module to be enabled. Codex and Kiro default to their own models.
    Kimchi and Copilot are excluded because supported delegation controls are absent
    or unestablished.

    Runtime-only overrides include `settings.delegateTools`,
    `settings.introspectModels`, `settings.checkUsage` and `settings.launch`:
    set `.text` (or `.source`) to replace a preset, and `.enable = false` to omit
    a block. Launch instructions are used when that runtime appears as an external
    delegate in another skill. The package intersects Kiro models with its catalog
    and requires a live list before pinning. Both Home Manager and devenv expose
    the same options.

    </details>

    <details>
    <summary><strong>Stacked Workflows</strong></summary>

    ```nix
    ai.programs.stacked-workflows.enable = true;

    # mkDefault values on the git.* options (see Git Tools): Home Manager
    # applies them user-global, devenv repository-local.
    stacked-workflows.gitPreset = "full"; # or "minimal" or "none"

    # Optional runtime override: null inherits, false disables one runtime.
    ai.codex.programs.stacked-workflows.enable = false;
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
    are documented in [AGENTS.md](AGENTS.md), the always-loaded instructions
    every agent runtime shares. Do not duplicate — read that file first.

    ## Linting

    Run the meta-formatter before committing:

    ```bash
    treefmt              # format everything (formats only — lints nothing)
    treefmt <file>       # format a single file after editing
    ```

    Linting is separate from formatting: the linters (deadnix, statix,
    shellcheck, cspell) run as prek pre-commit hooks on staged files, which
    `--no-verify` skips locally.

    `nix flake check` is the CI gate. Besides formatting, structural checks
    and module evaluation, it runs the same linters over every tracked file
    (`checks.repo-lints`, plus `checks.shellcheck-corpus`), so spelling is
    checked in CI even when a local commit skipped the hooks.

    ${commitConvention}

    ## Adding a Package

    ### AI CLI or MCP Server

    See [Packaging](docs/packaging.md) and the scoped architecture routing
    in [AGENTS.md](AGENTS.md) for recipe patterns and package-specific guidance.

    ### General pattern

    1. Create `packages/<owner>/packages/<namespace>/<name>/package.nix` with inline `rev` + `hash`
    2. Add update, cache, and documentation entries to the owner's `registry.nix`
    3. Put consumer modules, helpers, and checks in the same owner directory
    4. Add HM and devenv modules in `packages/<owner>/modules/` when applicable
    5. Run `nix flake check` to verify

    See [Repository ownership and layout](docs/repository-layout.md) for a
    worked tree. Register checks through the owner's native `checks.nix` module.

    Owner discovery exports native package namespaces, flat flake packages,
    and backend modules automatically. New owners need no root export entry.

    See [Change Propagation](AGENTS.md#change-propagation) — when removing
    or renaming a concept, all surfaces must be updated in the same commit.

    ## Adding a Fragment

    Fragments are composable instruction blocks. `dev/generate.nix` composes
    them into the context and rules that `ai.*` writes for every runtime
    (AGENTS.md, Claude, Copilot, Kiro), and into CONTRIBUTING.md.

    <!-- TODO: refine with maintainer input -->

    | Fragment type | Location | Exported? |
    |---------------|----------|-----------|
    | Dev-only (monorepo/tooling) | `dev/fragments/<pkg>/<name>.md` | No |
    | Published coding standards | `packages/coding-standards/fragments/<name>.md` | Yes |
    | Published delegate-routing rule | `packages/delegate-routing/fragments/<name>.md` | Yes |
    | Published SWS skill-routing rule | `packages/stacked-workflows/fragments/<name>.md` | Yes |

    To add a dev-only fragment:

    1. Create `dev/fragments/<pkg>/<name>.md`
    2. Add the name to `config.fragments.categories.<pkg>.sources` in
       `config/fragment-categories.nix` (scope globs for the category live
       alongside it as `.scopes`)
    3. Run `devenv tasks run --mode before generate:all` to regenerate

    To add a published fragment (consumed by external users):

    1. Create `packages/<owner>/fragments/<name>.md`
    2. Use the owner's `lib/fragments.nix` directory discovery to expose the
       fragment through its native content recipe and public library. Existing
       content owners discover markdown files automatically.
    3. If the fragment also belongs in this repository's generated instructions,
       add it to the relevant owner `registry.nix` category or workspace category
       in `config/fragment-categories.nix`
    4. Run `devenv tasks run --mode before generate:all` to regenerate everything

    ## Pull Requests

    <!-- TODO: refine with maintainer input -->

    - One logical change per PR
    - CI must pass (formatting, linting, spelling, module evaluation)
    - Committed generated files (AGENTS.md, README.md, CONTRIBUTING.md,
      `.github/copilot-instructions.md`, `.github/instructions/`) must be
      regenerated if their source fragments changed: run
      `devenv tasks run --mode before generate:all`. `nix flake check`
      fails on drift.
    - Keep commits atomic using the stacked workflow skills
      (`/stack-plan`, `/stack-fix`, `/stack-submit`)
  '';
in {
  inherit context contributingMd readmeMd rules;
}
