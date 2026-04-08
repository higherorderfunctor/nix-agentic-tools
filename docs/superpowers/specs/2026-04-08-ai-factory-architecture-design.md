# AI Factory Architecture Design

**Status:** Draft
**Date:** 2026-04-08
**Branch:** `refactor/ai-factory-architecture`
**Supersedes:** Phase 2a records+adapter design (archived at `archive/phase-2a-refactor:cdbd37a`)

## Goal

Replace the current inline-fanout `modules/ai/default.nix` + nascent records+adapter pattern with a **lib-heavy typed-factory architecture** where:

1. Each package under `packages/<name>/` owns its full slice of the `ai.*` option tree (options + impl), contributed via a per-package barrel file.
2. Shared factory logic (transformers, module boilerplate, typed attrset shapes) lives in `lib/ai/*` and is called via per-package factory-of-factories.
3. The overlay exposes everything under `pkgs.ai.*`, dropping the flat top-level and the `pkgs.nix-mcp-servers.*` sub-scope.
4. `modules/ai/default.nix` goes away entirely — there is no central dispatch module. Fanout for shared options happens inside the generic `lib.ai.app.mkAiApp` factory and is automatically inherited by every AI-app package that uses it (including third-party extensions loaded via lib composition).

**Terminology note:** "AI app" is the generic term for anything that consumes the shared option pool — CLIs (claude-code, copilot-cli, kiro-cli), daemons (openclaw and similar), gateways, LSP bridges, etc. The factory is deliberately named `mkAiApp` rather than `mkCli` so the pattern isn't locked to the CLI form factor.

This spec answers Q1–Q8 from `docs/plan.md` and locks the filesystem layout, factory shapes, and migration milestones. Implementation-plan drafting happens after this spec is approved.

## Context

After two cancelled plans (architecture-foundation Phase 2a and the sentinel→main merge), the pivot dropped:

- The `lib/ai-ecosystems/*.nix` records + `lib/mk-ai-ecosystem-hm-module.nix` adapter layer (records now live on the package itself, no adapter needed).
- The TOP/MIDDLE/LOWER priority framing (replaced with sequential dependency in plan.md).
- Scope-ambiguous `packages/ai-clis/` (mixing overlay files with published fragments).

The pivot kept:

- **Fragment nodes + `mkRenderer`** from `lib/fragments.nix` (ported forward in `f088d40`; reused as the transformer substrate).
- **`dev/generate.nix`** compose-once fix + `composedByPackage` rename.
- The 14 golden tests in `checks/fragments-eval.nix`.
- Conceptually: records-as-data + transformer-per-ecosystem. But records now live in the **package's factory-of-factory call**, not in a separate `lib/ai-ecosystems/` tree.

## Core decisions

### Q1: Three-layer separation

**Decision:** Keep overlay / lib / modules as three separate concerns matching nixpkgs + home-manager + devenv convention. No package returns a "bundle" that carries both the drv and its module.

- **Overlay** (`overlays/`) produces derivations. `pkgs.ai.claude-code` is a real drv — nothing else hanging off it.
- **Lib** (`lib/`) exposes pure functions as a single `flake.lib` output. Consumers compose: `lib = nixpkgs.lib // home-manager.lib // nix-agentic-tools.lib`.
- **Modules** (`packages/<name>/modules/{homeManager,devenv}/`) are standard NixOS module fragments. The flake exposes them merged under `{homeManagerModules,devenvModules}.nix-agentic-tools`.

### Q2: Per-package module ownership, no central adapter

**Decision:** Each package owns its entire `ai.<name>.*` slice end-to-end via its own `packages/<name>/modules/homeManager/default.nix` (and devenv counterpart). The flake's `homeManagerModules.nix-agentic-tools` output is just `{ imports = [ … every package's modules/homeManager … ]; }`.

**`modules/ai/default.nix` goes away entirely.** There is no central fanout module, no adapter, no dispatch table. The NixOS module system handles merging for free when every package declares `options.ai.<name>.*` at the same path.

The `mk-ai-ecosystem-hm-module.nix` adapter from Phase 2a is dissolved — it existed to bridge `lib/ai-ecosystems/*.nix` records to module output, but under this design the "record" and the "module" are the same thing: a factory-of-factory call in the package's module file.

### Q3: Barrel imports, no filesystem walking

**Decision:** Two-level explicit barrel pattern.

- **Per-package barrel** (`packages/<name>/default.nix`) aggregates everything that package owns: module paths, fragments dir, dev docs dir, lib contributions (factory-of-factories).
- **Top-level barrel** (`packages/default.nix`) is a flat one-line-per-package attrset that imports each package directory.
- **`flake.nix`** maps over the top-level barrel and pulls each facet independently.

**No `builtins.readDir`, no filesystem walking.** Adding a new package is two steps: create the directory, add one line to `packages/default.nix`.

### Q4: Top-level shared options with automatic fanout via `mkAiApp`

**Decision:** Top-level `ai.mcpServers`, `ai.instructions`, `ai.skills` are declared once (in `lib/ai/sharedOptions.nix`). Each AI app has matching per-app overrides (`ai.<name>.mcpServers`, etc.). The generic `lib.ai.app.mkAiApp` factory contains the fanout line:

```nix
mergedServers = config.ai.mcpServers // config.ai.${name}.mcpServers;
```

Every AI app built via `mkAiApp` inherits this fanout for free. Third-party AI apps (e.g. openclaw, which is a daemon rather than a CLI — its interaction surface doesn't change the factory contract) participate automatically as long as they're built using our `mkAiApp` and loaded in the same HM eval context. No central registry, no dispatch table.

### Q5: Milestone-driven step-sized rollout

**Decision:** Neither one giant atomic commit nor review-sized micro-commits. **Step-sized commits** with verification checkpoints between each, allowing rapid iteration while keeping `nix flake check` green at every step. User re-chunks the commits for the main merge next week.

See "Migration milestones" below for the specific step list.

### Q6: Buddy as a custom factory option, not a separate DSL

**Decision:** The "typed extras contract" (`{type, default, description, onSet}`) from the Phase 2a pivot memory is **dissolved**. Custom per-package options are just standard NixOS module options passed via the factory's `options = { ... }` parameter. No custom DSL.

`buddy` for claude-code lives inside `lib/ai/apps/mkClaude.nix` as a regular `lib.mkOption` declaration, and its activation logic lives in the factory's `config = { cfg, lib, pkgs }: …` callback.

### Q7: Named MCP server duplication via factory-of-factory, not a registry

**Decision:** Consumers invoke `lib.ai.mcpServers.mk<Name>` from their config to produce named instances. Multiple instances of the same upstream server are just multiple calls:

```nix
ai.claude.mcpServers = {
  gitLab1 = lib.ai.mcpServers.mkGitLab { endpoint = "https://gitlab.com"; };
  gitLab2 = lib.ai.mcpServers.mkGitLab { endpoint = "https://gitlab.corp.example"; };
};
```

No central registry to register names; the attr key IS the name. The factory-of-factory returns a **typed attrset** (not a discriminated union or a module function) so the HM module can consume every entry uniformly.

### Q8: Custom options via standard module options, no handler lambdas

**Decision:** Same as Q6. The `options` parameter to `mkAiApp` / `mkMcpServer` takes standard `lib.mkOption` declarations. The factory merges them into its base option tree. Custom config logic comes through the factory's `config` callback, which is a normal module config fragment (not a free-form `{hmConfig, devenvConfig, packages}` trio).

The pivot memory's typed-extras handler signature is abandoned in favor of full module-system idioms.

## Architecture

### Filesystem layout

```
nix-agentic-tools/
├── nvfetcher.toml              # ONE, at repo root (shared by all binary packages)
│
├── overlays/                   # FLAT — binary drvs only (the exception to Bazel-style)
│   ├── .nvfetcher/             # nvfetcher output dump
│   ├── default.nix             # aggregator: composeManyExtensions + withSources pattern
│   ├── sources.nix             # bridges nvfetcher output into `final.nv-sources`
│   ├── hashes.json             # sidecar hashes for cargoHash etc
│   ├── claude-code.nix
│   ├── copilot-cli.nix
│   ├── kiro-cli.nix
│   ├── kiro-gateway.nix
│   ├── agnix.nix
│   ├── git-absorb.nix
│   ├── git-branchless.nix
│   ├── git-revise.nix
│   ├── context7-mcp.nix
│   ├── effect-mcp.nix
│   ├── fetch-mcp.nix
│   ├── git-intel-mcp.nix
│   ├── git-mcp.nix
│   ├── github-mcp.nix
│   ├── kagi-mcp.nix
│   ├── mcp-language-server.nix
│   ├── mcp-proxy.nix
│   ├── nixos-mcp.nix
│   ├── openmemory-mcp.nix
│   ├── sequential-thinking-mcp.nix
│   ├── serena-mcp.nix
│   ├── sympy-mcp.nix
│   └── ...
│
├── packages/                   # PUBLISHED — Bazel-style, per-package dirs
│   ├── default.nix             # TOP-LEVEL BARREL (flat one-line-per-package imports)
│   │
│   ├── claude-code/            # coupled to overlays/claude-code.nix
│   │   ├── default.nix         # per-package barrel
│   │   ├── fragments/          # PUBLISHED markdown (composed into CLAUDE.md/AGENTS.md)
│   │   ├── docs/               # DEV fragments (path-scoped auto-load for contributors)
│   │   ├── lib/                # lib contributions (mkClaude factory-of-factory)
│   │   │   └── mkClaude.nix
│   │   └── modules/
│   │       ├── homeManager/    # contributes to ai.claude.* option tree
│   │       │   └── default.nix # thin call to lib.ai.apps.mkClaude
│   │       └── devenv/         # contributes to devenv's ai.claude.* option tree
│   │           └── default.nix
│   │
│   ├── copilot-cli/            # same shape
│   ├── kiro-cli/
│   ├── kiro-gateway/
│   ├── agnix/
│   ├── git-absorb/             # minimal — just default.nix pointing at the overlay
│   ├── git-branchless/
│   ├── git-revise/
│   ├── context7-mcp/
│   ├── effect-mcp/
│   ├── ... (every MCP server that's in overlays/)
│   ├── coding-standards/       # content-only (no overlays/ entry; default.nix IS the drv)
│   └── stacked-workflows/      # content-only
│
├── devshell/                   # INTERNAL — Bazel-style but NOT published
│   ├── default.nix             # aggregator — walked by devenv.nix
│   ├── lib/                    # internal-only lib, NOT exposed as flake.lib
│   │   └── default.nix
│   ├── shell/                  # mkAgenticShell-ish bits
│   ├── git-hooks/              # sub-package if grows beyond one file
│   ├── treefmt/                # sub-package if grows
│   ├── docs-site/              # ← replaces packages/fragments-docs
│   │   ├── default.nix         # mdbook derivation
│   │   ├── docs/               # dev fragments about the docs site itself
│   │   └── src/                # (or generated into it)
│   └── monorepo/               # repo-level dev fragments not tied to any package
│       └── docs/               # architecture-fragments, flake/*, nix-standards/*, etc
│
├── lib/                        # PUBLISHED lib, exposed as flake.lib
│   ├── default.nix             # entry point
│   ├── fragments.nix           # node constructors + mkRenderer (ported in f088d40)
│   ├── devshell.nix            # mkAgenticShell (stays for consumer-facing dev shells)
│   └── ai/
│       ├── default.nix         # lib.ai namespace root
│       ├── sharedOptions.nix   # declares ai.mcpServers / ai.instructions / ai.skills ONCE
│       ├── transformers/       # pure functions: fragment data → ecosystem bytes
│       │   ├── claude.nix
│       │   ├── copilot.nix
│       │   ├── kiro.nix
│       │   └── agentsmd.nix
│       ├── app/                # SINGULAR — generic AI-app factory
│       │   └── mkAiApp.nix     # lib.ai.app.mkAiApp
│       ├── apps/               # PLURAL — factory-of-factory instances
│       │   ├── (populated dynamically from packages/*/lib/mk<Name>.nix via barrel merge)
│       │   └── ...
│       ├── mcpServer/          # SINGULAR — generic MCP server factory
│       │   └── mkMcpServer.nix # lib.ai.mcpServer.mkMcpServer
│       ├── mcpServers/         # PLURAL — factory-of-factory instances
│       │   └── (populated dynamically from packages/*/lib/mk<Name>.nix)
│       └── fragments/          # fragment rendering helpers (if any beyond lib/fragments.nix)
│
├── checks/                     # flake checks (golden tests + eval assertions)
│   └── fragments-eval.nix      # 14 tests ported in f088d40; more to come
│
├── devenv.nix                  # dev shell config (uses devshell/* internally)
├── treefmt.nix                 # shared treefmt config
└── flake.nix                   # the root flake
```

**Key differences from the current layout:**

| Current (main branch tip)                            | New                                                                                       |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `packages/ai-clis/claude-code.nix` (overlay file)    | `overlays/claude-code.nix`                                                                |
| `packages/ai-clis/fragments/dev/buddy-activation.md` | `packages/claude-code/docs/buddy-activation.md`                                           |
| `packages/ai-clis/any-buddy.nix`                     | Dissolved — lives as a custom option in `packages/claude-code/lib/mkClaude.nix`           |
| `packages/mcp-servers/context7-mcp.nix`              | `overlays/context7-mcp.nix` + `packages/context7-mcp/`                                    |
| `packages/git-tools/git-absorb.nix`                  | `overlays/git-absorb.nix` + `packages/git-absorb/` (minimal)                              |
| `packages/fragments-ai/`                             | Dissolved — transformers become `lib/ai/transformers/*.nix`                               |
| `packages/fragments-docs/`                           | Moved → `devshell/docs-site/`                                                             |
| `lib/buddy-types.nix`                                | Deleted — buddy option lives in claude-code's factory                                     |
| `modules/ai/default.nix`                             | Deleted — each package owns its slice                                                     |
| `modules/claude-code-buddy/`                         | Deleted — buddy folds into claude-code                                                    |
| `modules/devenv/ai.nix`                              | Deleted — same reasoning; devenv modules live per-package                                 |
| `devshell/*.nix` (flat)                              | `devshell/shell/`, `devshell/git-hooks/`, etc (Bazel-style internal)                      |
| `dev/fragments/<category>/*.md`                      | Split: package-specific → `packages/<name>/docs/`; repo-level → `devshell/monorepo/docs/` |

### Overlay

Scoped namespace: **`pkgs.ai.*`**. Every binary in `overlays/<name>.nix` registers under `pkgs.ai.<name>`. The `overlays/default.nix` aggregator uses the same `withSources` pattern from `nix-mcp-servers/overlays/default.nix` so individual package files only need to import their `final.nv-sources.<key>` entry.

```nix
# overlays/default.nix
{ inputs, ... }: final: prev: let
  inherit (inputs.nixpkgs) lib;

  sourcesOverlay = import ./sources.nix { } final prev;
  nv-sources = sourcesOverlay.nv-sources;

  callPkg = path: let
    fn = import path;
    args = builtins.functionArgs fn;
  in
    if args ? inputs
    then fn { inherit inputs; } (final // { inherit nv-sources; })
    else fn (final // { inherit nv-sources; });

  drvs = {
    claude-code = callPkg ./claude-code.nix;
    copilot-cli = callPkg ./copilot-cli.nix;
    kiro-cli    = callPkg ./kiro-cli.nix;
    # ... every binary under overlays/
    git-absorb  = callPkg ./git-absorb.nix;
    context7-mcp = callPkg ./context7-mcp.nix;
    # ...
  };
in {
  inherit nv-sources;
  ai = drvs;  # ← scoped under pkgs.ai.*
}
```

Consumer writes:

```nix
pkgs.ai.claude-code   # the claude-code drv
pkgs.ai.context7-mcp  # an MCP server drv
pkgs.ai.git-absorb    # a git tool drv
```

No collision with top-level nixpkgs attrs, explicit provenance, matches `nix-mcp-servers` convention (but with `ai` instead of `nix-mcp-servers` as the scope name, since our repo is broader).

### Lib

Single flake output `nix-agentic-tools.lib`. Consumer composes:

```nix
lib = nixpkgs.lib
  // home-manager.lib
  // nix-agentic-tools.lib;
```

Structure of the published lib:

```
nix-agentic-tools.lib
├── fragments                   # node constructors, mkRenderer, compose (from lib/fragments.nix)
│   ├── mkRaw
│   ├── mkLink
│   ├── mkInclude
│   ├── mkBlock
│   ├── defaultHandlers
│   ├── mkRenderer
│   └── compose
├── devshell                    # mkAgenticShell (for consumer dev shells)
│   └── mkAgenticShell
└── ai
    ├── sharedOptions           # (imported as a module, not called directly)
    ├── transformers
    │   ├── claude             # pure function: fragment data → claude bytes
    │   ├── copilot
    │   ├── kiro
    │   └── agentsmd
    ├── cli                    # singular — generic factory
    │   └── mkAiApp              # lib.ai.app.mkAiApp
    ├── clis                   # plural — factory-of-factories
    │   ├── mkClaude           # from packages/claude-code/lib/mkClaude.nix
    │   ├── mkCopilot
    │   ├── mkKiro
    │   └── mkCodex            # (future)
    ├── mcpServer              # singular — generic factory
    │   └── mkMcpServer        # lib.ai.mcpServer.mkMcpServer
    └── mcpServers             # plural — factory-of-factories
        ├── mkContext7         # from packages/context7-mcp/lib/mkContext7.nix
        ├── mkGitLab
        ├── mkGitHub
        └── ... (one per published MCP server)
```

The `ai.clis.*` and `ai.mcpServers.*` attrsets are populated by `flake.nix` merging each package's `lib` contribution via `recursiveUpdate`. No central curation — each package owns its factory-of-factory.

### Factory layering

**Generic AI-app factory** (`lib/ai/app/mkAiApp.nix`):

```nix
# Pseudocode — actual implementation uses evalModules for typed validation
{ lib, pkgs, ... }:
{
  name,                  # required: "claude" | "copilot" | "kiro" | ...
  transformers,          # required: { markdown = lib.ai.transformers.claude; }
  defaults,              # required: { package = pkgs.ai.claude-code; ... }
  options ? { },         # optional: custom NixOS options added to ai.<name>.*
  config ? _: { },       # optional: custom config fragment callback
}:
  { config = moduleConfig, lib, pkgs, ... }: let
    cfg = moduleConfig.ai.${name};

    # Fanout: merge top-level shared pool with per-app overrides
    mergedServers = moduleConfig.ai.mcpServers // cfg.mcpServers;
    mergedInstructions = moduleConfig.ai.instructions ++ cfg.instructions;
    mergedSkills = moduleConfig.ai.skills // cfg.skills;

    # Render merged data into app-specific output bytes
    renderedBytes = transformers.markdown {
      fragments = mergedInstructions;
      servers = mergedServers;
      skills = mergedSkills;
    };
  in {
    options.ai.${name} = {
      enable = lib.mkEnableOption "${name}";
      package = lib.mkPackageOption pkgs "ai.${name}" { default = defaults.package; };
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith { modules = [ /* common shape */ ]; });
        default = { };
        description = "${name}-specific MCP servers (merged with top-level ai.mcpServers, per-app overrides win).";
      };
      instructions = lib.mkOption { /* same pattern */ };
      skills = lib.mkOption { /* same pattern */ };
    } // options;  # merge in factory-of-factory's custom options

    config = lib.mkIf cfg.enable (lib.mkMerge [
      # baseline: render into app-specific output files
      { home.file."${defaults.outputPath}".text = renderedBytes; }
      # per-app custom config (e.g. buddy activation for claude)
      (options.config { inherit cfg lib pkgs; })
    ]);
  };
```

**Factory-of-factory** (`packages/claude-code/lib/mkClaude.nix`):

```nix
{ lib, pkgs, ... }:
lib.ai.app.mkAiApp {
  name = "claude";
  transformers.markdown = lib.ai.transformers.claude;
  defaults = {
    package = pkgs.ai.claude-code;
    outputPath = ".config/claude/CLAUDE.md";  # wherever claude reads its config
  };
  options = {
    buddy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Claude buddy activation";
          statePath = lib.mkOption {
            type = lib.types.str;
            default = ".local/state/claude-buddy";
          };
          # ... all buddy-specific options
        };
      };
      default = { enable = false; };
      description = "Claude buddy activation script (Claude-specific).";
    };
    memory = lib.mkOption { /* claude-specific memory config */ };
    settings = lib.mkOption { /* freeform JSON passthrough */ };
  };
  config = { cfg, lib, pkgs }: lib.mkMerge [
    (lib.mkIf cfg.buddy.enable {
      home.activation.claudeBuddy = /* buddy bootstrap script */;
    })
    (lib.mkIf (cfg.memory != null) {
      home.file."${cfg.memory.path}".source = /* rendered memory bytes */;
    })
  ];
}
```

**Package barrel** (`packages/claude-code/default.nix`):

```nix
{
  modules = {
    homeManager = ./modules/homeManager;
    devenv = ./modules/devenv;
  };

  fragments = ./fragments;
  docs = ./docs;

  # contribute factory-of-factory to lib.ai.apps.mkClaude
  lib.ai.apps.mkClaude = import ./lib/mkClaude.nix;
}
```

**Package HM module** (`packages/claude-code/modules/homeManager/default.nix`):

```nix
# Thin stub — the factory-of-factory does all the work
{ lib, pkgs, config, ... } @ args:
(lib.ai.apps.mkClaude { inherit lib pkgs; }) args
```

Each package's module file is essentially 2 lines: pull the factory-of-factory out of lib, apply it with module args. Zero boilerplate.

### Generic MCP server factory

Same pattern as `mkAiApp`, but returns a **typed attrset** (not a module function) because MCP servers are consumed per-instance at config time, not per-package at module time.

```nix
# lib/ai/mcpServer/mkMcpServer.nix
{ lib, pkgs, ... }:
{
  name,                  # required: "gitlab" | "github" | ...
  defaults,              # required: { package = pkgs.ai.gitlab-mcp; type = "stdio"; ... }
  argsTranslator,        # required: function building args list from consumer inputs
  options ? { },         # optional: custom typed fields for this specific server
  config ? _: { },       # optional: custom config fragment (e.g. for activation scripts)
}: consumerArgs: let
  # Validate consumerArgs against base schema + custom options via evalModules
  validated = lib.evalModules {
    modules = [
      { options = baseMcpServerOptions // options; }
      { config = defaults // consumerArgs; }
    ];
  };
in
  validated.config  # → typed attrset conforming to base + custom schema
```

**Factory-of-factory** (`packages/github-mcp/lib/mkGitHub.nix`):

```nix
{ lib, pkgs, ... }:
lib.ai.mcpServer.mkMcpServer {
  name = "github";
  defaults = {
    package = pkgs.ai.github-mcp;
    type = "stdio";
  };
  argsTranslator = args: [ "--token" args.token ];
  options = {
    copilotIntegration.enable = lib.mkEnableOption "GitHub Copilot integration";
  };
}
```

**Consumer call** (in their `home.nix`):

```nix
ai.claude.mcpServers.gh1 = lib.ai.mcpServers.mkGitHub {
  token = config.sops.secrets.github-token.path;
  copilotIntegration.enable = true;
};
```

The call-site returns a typed attrset that gets assigned into `ai.claude.mcpServers.gh1`. The HM module for claude-code then reads `config.ai.claude.mcpServers.gh1` and knows exactly what to do because it conforms to the known schema.

### Shared options and automatic fanout

**`lib/ai/sharedOptions.nix`** declares cross-app options ONCE:

```nix
{ lib, ... }:
{
  options.ai = {
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [ lib.ai.mcpServer.commonSchema ];
      });
      default = { };
      description = ''
        MCP servers fanned out to every enabled AI app. Per-app overrides
        (ai.<name>.mcpServers) merge on top and win on conflict.
      '';
    };
    instructions = lib.mkOption {
      type = lib.types.listOf /* fragment node type */;
      default = [ ];
      description = "Cross-app instructions (fanned out to every enabled AI app).";
    };
    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Cross-app skills (fanned out to every enabled AI app).";
    };
  };
}
```

**`flake.nix`** imports it alongside per-package modules:

```nix
homeManagerModules.nix-agentic-tools = {
  imports = [
    ./lib/ai/sharedOptions.nix
  ] ++ collectFacet [ "modules" "homeManager" ];
};
```

**The fanout line** inside `lib.ai.app.mkAiApp` picks up the shared pool:

```nix
mergedServers = config.ai.mcpServers // cfg.mcpServers;
```

Every AI app built via `mkAiApp` inherits this one line. Third-party apps (e.g. openclaw, which is a daemon with multiple interaction surfaces rather than a plain CLI) using our factory get fanout for free.

**Disabling an AI app** (`ai.<name>.enable = false`) means its module's `config = lib.mkIf cfg.enable …` block is inert — it never processes `ai.mcpServers`, so servers aren't leaked to apps the consumer doesn't want.

### Barrel composition in flake.nix

```nix
# flake.nix
{
  outputs = { self, nixpkgs, ... } @ inputs: let
    inherit (nixpkgs) lib;
    systems = [ "x86_64-linux" "aarch64-darwin" ];
    forAllSystems = lib.genAttrs systems;

    # Per-package barrels (each packages/<name>/default.nix)
    packages = import ./packages;

    # Pull one facet out of every package, skipping packages that lack it
    collectFacet = attrPath: lib.pipe packages [
      (lib.filterAttrs (_: p: lib.hasAttrByPath attrPath p))
      (lib.mapAttrsToList (_: p: lib.getAttrFromPath attrPath p))
    ];

    # Merge each package's lib contribution into a single attrset
    packageLibs = lib.foldl' lib.recursiveUpdate { }
      (lib.mapAttrsToList (_: p: p.lib or { }) packages);

    ownLib = import ./lib { inherit (nixpkgs) lib; };
  in {
    overlays.default = import ./overlays { inherit inputs; };

    lib = lib.recursiveUpdate ownLib packageLibs;

    homeManagerModules.nix-agentic-tools = {
      imports = [
        ./lib/ai/sharedOptions.nix
      ] ++ collectFacet [ "modules" "homeManager" ];
    };

    devenvModules.nix-agentic-tools = {
      imports = [
        ./lib/ai/sharedOptions.nix  # or a devenv-specific shared options module
      ] ++ collectFacet [ "modules" "devenv" ];
    };

    packages = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
    in
      # flake packages output: flat for CLI ergonomics
      pkgs.ai  # or filtered subset
    );

    checks = forAllSystems (system: let
      pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
    in
      import ./checks { inherit lib pkgs; }
    );
  };
}
```

### Consumer usage example

```nix
# consumer's flake.nix
{
  inputs.nix-agentic-tools.url = "github:higherorderfunctor/nix-agentic-tools/refactor/ai-factory-architecture";

  outputs = { nixpkgs, home-manager, nix-agentic-tools, ... }: let
    lib = nixpkgs.lib
      // home-manager.lib
      // nix-agentic-tools.lib;
  in {
    homeConfigurations.daisy = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ nix-agentic-tools.overlays.default ];
      };
      modules = [
        nix-agentic-tools.homeManagerModules.nix-agentic-tools
        ./home.nix
      ];
      extraSpecialArgs = { inherit lib; };
    };
  };
}
```

```nix
# consumer's home.nix
{ lib, pkgs, config, ... }:
{
  ai.claude.enable = true;
  ai.copilot.enable = true;
  ai.kiro.enable = true;

  # Shared MCP servers — fan out to all three enabled apps automatically
  ai.mcpServers = {
    gitLab1 = lib.ai.mcpServers.mkGitLab {
      token = config.sops.secrets.gitlab-token.path;
    };
    gh1 = lib.ai.mcpServers.mkGitHub {
      token = config.sops.secrets.github-token.path;
    };
    context7 = lib.ai.mcpServers.mkContext7 { };
  };

  # Claude-only configuration
  ai.claude.buddy.enable = true;
  ai.claude.mcpServers.claudeOnly = lib.ai.mcpServers.mkSomething { };

  # Copilot-only override
  ai.copilot.settings.someFlag = true;
}
```

## Migration milestones

Step-sized commits with verification checkpoints. Each step leaves `nix flake check` green. User re-chunks these for the main merge next week.

**Milestone 1: Lib scaffolding + shared options + core factories**

- Create `lib/ai/{transformers,cli,clis,mcpServer,mcpServers}/` with empty-or-stub files.
- Write `lib/ai/sharedOptions.nix` declaring top-level options.
- Write `lib/ai/app/mkAiApp.nix` (generic factory) — correct signature, stub config body.
- Write `lib/ai/mcpServer/mkMcpServer.nix` (generic factory).
- Port transformer functions from `dev/generate.nix` (or from `archive/phase-2a-refactor:lib/ai-ecosystems/*.nix`) into `lib/ai/transformers/{claude,copilot,kiro,agentsmd}.nix`.
- Wire `flake.lib` to include the new `ai.*` namespace.
- **Verification:** `nix flake check` green; new golden tests in `checks/` exercise factory signatures and transformer output.

**Milestone 2: Port claude-code as proof-of-concept**

- Create `packages/claude-code/` with full Bazel shape: `default.nix` barrel, `modules/{homeManager,devenv}/default.nix`, `lib/mkClaude.nix`, `fragments/`, `docs/`.
- Move existing `packages/ai-clis/claude-code.nix` → `overlays/claude-code.nix`, update overlay to expose under `pkgs.ai.claude-code` (possibly temporary — real rename in milestone 8).
- Fold buddy into `mkClaude` as a custom option. Delete `lib/buddy-types.nix`, `modules/claude-code-buddy/`, `packages/ai-clis/any-buddy.nix` in the same commit.
- Update `packages/default.nix` to add `claude-code = import ./claude-code;`.
- **Verification:** `nix flake check` green; claude-code HM module still produces the same store path for `home.file."<rule-file>"` as before (or documented diff with rationale); buddy activation script still runs end-to-end in a smoke test.

**Milestone 3: Port one MCP server as proof-of-concept**

- Pick a zero-credential server (e.g. `context7-mcp` or `fetch-mcp`) as the easiest full port.
- Create `packages/context7-mcp/` with barrel + `lib/mkContext7.nix` + fragments/docs.
- Move overlay file to `overlays/context7-mcp.nix`.
- Wire claude-code's HM module to fan out MCP servers from `config.ai.mcpServers` + `config.ai.claude.mcpServers`.
- **Verification:** A test config with `ai.mcpServers.context7 = lib.ai.mcpServers.mkContext7 { };` produces a rendered claude config file with the context7 entry.

**Milestone 4: Drop `programs.{copilot-cli,kiro-cli}` HM modules**

- Port copilot-cli and kiro-cli to the factory (`packages/{copilot-cli,kiro-cli}/`).
- Delete the stand-alone `programs.copilot-cli.*` / `programs.kiro-cli.*` HM modules.
- **Verification:** All three apps (claude, copilot, kiro) render correct config output for a shared `ai.mcpServers` pool; option diff vs the old modules is documented in the commit message.

**Milestone 5: Port every remaining MCP server**

- Mechanical port of the remaining ~13 MCP servers. Each gets its own `packages/<name>/` directory, factory-of-factory, overlay entry under `overlays/`.
- Update the `packages/default.nix` top-level barrel accordingly.
- **Verification:** `nix flake check` green; every MCP server is callable as `lib.ai.mcpServers.mk<Name>`.

**Milestone 6: Port remaining AI apps and auxiliary binaries**

- `kiro-gateway`, `agnix`, `git-absorb`, `git-branchless`, `git-revise` — port their overlays to `overlays/` and create minimal `packages/<name>/default.nix` barrels (no modules if they don't need them).
- **Verification:** `pkgs.ai.<every-binary>` resolves; overlays aggregator `overlays/default.nix` enumerates them all.

**Milestone 7: Delete `modules/ai/default.nix` and the central fanout adapter**

- If anything still imports `modules/ai/default.nix`, update to use the per-package merged modules directly.
- Delete `modules/ai/`, `modules/devenv/ai.nix`.
- **Verification:** Grep for references; `nix flake check` green; each app's option tree is still declared exactly once (by its package's module file).

**Milestone 8: Scope overlay under `pkgs.ai.*`**

- Final rename pass. `pkgs.nix-mcp-servers.context7-mcp` → `pkgs.ai.context7-mcp`; `pkgs.claude-code` → `pkgs.ai.claude-code`; etc.
- Update every consumer reference inside this repo.
- Nixos-config updates its flake input pin to this branch; user confirms the pin flexibility in plan.md.
- **Verification:** `nix flake check` green; nixos-config builds against the new branch.

**Milestone 9: Dissolve `packages/fragments-ai/`**

- The transformers from `packages/fragments-ai/` should have moved to `lib/ai/transformers/` in Milestone 1. This milestone is the cleanup: delete the old `packages/fragments-ai/` dir, update any lingering references.
- **Verification:** Grep for `fragments-ai` produces zero hits in source files.

**Milestone 10: Move `packages/fragments-docs/` → `devshell/docs-site/`**

- Relocate the doc site generator into the internal tree.
- Update `devenv.nix` tasks to invoke `devshell/docs-site/` for `generate:docs`.
- **Verification:** `devenv tasks run generate:docs` still produces the same mdbook output.

**Milestone 11: Reorganize dev fragments**

- Move package-specific dev fragments (e.g. `dev/fragments/ai-clis/buddy-activation.md`) into their respective `packages/<name>/docs/` directories.
- Move repo-level dev fragments (e.g. `dev/fragments/monorepo/architecture-fragments.md`) into `devshell/monorepo/docs/`.
- Delete the now-empty `dev/` tree.
- **Verification:** Every path-scoped fragment auto-loads correctly in a fresh session; `dev/` directory is gone or reduced to just `dev/notes/` if anything needs to stay.

**Milestone 12: Restructure `devshell/`**

- Reshape the existing flat `devshell/*.nix` files into Bazel-style `devshell/<thing>/default.nix` subdirs if any grow beyond one file.
- Add internal `devshell/lib/` if internal helper functions materialize.
- **Verification:** Dev shell still enters cleanly; `devenv test` green.

**Checkpoint after each milestone:**

1. `nix flake check` green
2. Golden tests in `checks/fragments-eval.nix` (and new ones added each milestone) pass
3. Smoke test: enable at least one AI app in a test HM config, verify the expected output files land in `home.file.*`

## Out of scope for this spec

- **nixos-config migration** — happens in the Post-factory tier (plan.md). Flake input pin will follow this branch during rollout.
- **OpenAI Codex addition** (4th ecosystem, whatever form factor ends up shipping) — happens post-factory.
- **Fragment heading-aware merging** — backlog item, not needed for the factory itself.
- **Drift detection agent** — parallel track backlog.
- **NuschtOS options browser fixes** — parallel track backlog.
- **Doc site refinements** — happens after the devshell/docs-site/ move.
- **LLM-friendly inline code commenting conventions** — parallel track backlog.

## Risks and mitigations

| Risk                                                                                 | Mitigation                                                                                                                       |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `evalModules`-based factory validation performance                                   | Benchmark early; fall back to direct attrset merge if eval time explodes                                                         |
| Module-system option type collisions between `sharedOptions.nix` and per-app modules | Use `lib.mkOption` with matching types throughout; tests in `checks/module-eval.nix` validate option merge                       |
| Rollout step breaks HM eval for nixos-config                                         | Pin to refactor branch tip; user updates pin as each milestone lands; smoke-test nixos-config build at milestones 2, 4, 8        |
| Fragment-node renderer assumes claude-only layout                                    | Transformers were designed multi-ecosystem from the start; golden tests in `checks/fragments-eval.nix` exercise all 4 ecosystems |
| Third-party AI-app extension model doesn't actually work                             | Write a smoke test for a fake "openclaw" overlay (daemon form factor) in `checks/third-party-extension.nix` during Milestone 4   |

## References

- **Plan.md pointer:** `docs/plan.md` "Now: target architecture spec" (Q1-Q8 answered here)
- **Pivot memory:** `memory/project_factory_architecture_pivot.md`
- **Branch graveyard:** `memory/project_branch_graveyard.md`
- **Velocity mode:** `memory/feedback_refactor_velocity_mode.md`
- **Archive branches:**
  - `archive/phase-2a-refactor` at `cdbd37a` — records+adapter reference
  - `archive/sentinel-pre-takeover` at `55371a9` — pre-pivot sentinel
- **Reference repos** (patterns to mirror):
  - `nix-mcp-servers` — `overlays/` layout, `pkgs.<scope>.*` overlay scoping, `withSources` aggregator
  - `stacked-workflow-skills` — `overlays/` layout (lighter), barrel-pattern precedent in consumer's nixos-config
- **Current branch:** `refactor/ai-factory-architecture` at `e863336` (as of spec draft)
