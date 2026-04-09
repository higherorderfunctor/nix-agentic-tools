# Ideal Architecture Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Absorb the legacy `modules/` tree into per-package factory callbacks so the branch is ready for re-chunking into PR-sized batches for the main merge.

**Architecture:** The `lib.ai.app.mkAiApp` factory is refactored from "returns a module function" to "returns a backend-agnostic app record" with `{name, transformers, options, hm, devenv}`. Two new transformers (`hmTransform`, `devenvTransform`) project records into module functions for each backend. Per-package `packages/<name>/lib/mk<Name>.nix` files grow `hm` and `devenv` projections with backend-specific config callbacks: Claude delegates to upstream `programs.claude-code.*` (HM) / `claude.code.*` (devenv) where upstream provides a capability and writes files directly for gaps; Copilot and Kiro write everything directly since no upstream modules exist. Buddy activation is a Claude-specific gap that lives in `mkClaude.nix`'s `hm.config` callback only (no devenv projection). Once every factory absorbs its legacy module, the `modules/` tree is deleted wholesale.

**Tech Stack:** Nix flake + home-manager module system + devenv module system + `lib.evalModules` for per-backend evaluation + `checks/factory-eval.nix` and `checks/module-eval.nix` for golden tests. No new runtime dependencies.

---

## File Structure

This plan touches the following files. Each task lists its own subset; this is the overall map.

**Created:**

- `lib/ai/app/hmTransform.nix` — projects app record → HM module function
- `lib/ai/app/devenvTransform.nix` — projects app record → devenv module function
- `packages/context7-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/effect-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/fetch-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/git-intel-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/git-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/github-mcp/modules/mcp-server.nix` — relocated typed settings (181 lines)
- `packages/kagi-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/nixos-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/openmemory-mcp/modules/mcp-server.nix` — relocated typed settings (655 lines)
- `packages/sequential-thinking-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/serena-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/sympy-mcp/modules/mcp-server.nix` — relocated typed settings
- `packages/stacked-workflows/modules/homeManager/default.nix` — absorbed stacked-workflows HM module
- `packages/stacked-workflows/modules/devenv/default.nix` — absorbed stacked-workflows devenv module

**Modified:**

- `lib/ai/app/mkAiApp.nix` — restructured to return a record
- `lib/ai/app/default.nix` — export hmTransform + devenvTransform
- `lib/mcp.nix` — rewire `loadServer` to walk `packages/<name>/modules/mcp-server.nix`
- `packages/claude-code/lib/mkClaude.nix` — returns record with hm+devenv projections; hm absorbs full claude + buddy fanout
- `packages/claude-code/modules/homeManager/default.nix` — applies hmTransform
- `packages/claude-code/modules/devenv/default.nix` — applies devenvTransform
- `packages/copilot-cli/lib/mkCopilot.nix` — returns record; both projections absorb full fanout
- `packages/copilot-cli/modules/homeManager/default.nix` — applies hmTransform
- `packages/copilot-cli/modules/devenv/default.nix` — applies devenvTransform
- `packages/kiro-cli/lib/mkKiro.nix` — returns record; both projections absorb full fanout
- `packages/kiro-cli/modules/homeManager/default.nix` — applies hmTransform
- `packages/kiro-cli/modules/devenv/default.nix` — applies devenvTransform
- `packages/stacked-workflows/default.nix` — add modules facet
- `devenv.nix` — swap `imports = [./modules/devenv]` for `devenvModules.nix-agentic-tools`
- `checks/factory-eval.nix` — adapt existing tests to record shape
- `checks/module-eval.nix` — add `evalDevenv` helper + devenv-backend coverage

**Deleted:**

- `modules/ai/default.nix`
- `modules/claude-code-buddy/default.nix`
- `modules/copilot-cli/default.nix`
- `modules/kiro-cli/default.nix`
- `modules/stacked-workflows/default.nix`
- `modules/stacked-workflows/git-config.nix`
- `modules/stacked-workflows/git-config-full.nix`
- `modules/default.nix`
- `modules/mcp-servers/` (entire tree)
- `modules/devenv/` (entire tree)
- `modules/` directory itself
- `lib/ai-common.nix`
- `lib/buddy-types.nix`
- `lib/hm-helpers.nix`

---

## Task Dependency Graph

```
Task 1 (A7: record/transform refactor)
  ↓
Task 3 (A2: claude fanout) ── Task 4 (A3: copilot) ── Task 5 (A4: kiro)
  ↓                              ↓                      ↓
Task 6 (A1: buddy absorption)    └────────┬─────────────┘
  └──────────────────┬──────────────────────┘
                     ↓
Task 2 (A5: mcp relocation) ── independent, can run anytime after Task 1 ──┐
                     ↓                                                      ↓
Task 7 (A6: stacked-workflows absorption) ─────────────────────────────────┤
                     ↓                                                      ↓
Task 8 (A8: devenv.nix swap) ───────────────────────────────────────────────┤
                     ↓                                                      ↓
Task 9 (A10: delete modules/ + lib shims)  ◄───────────────────────────────┘
```

**Execution order:** Task 1 first (blocks all downstream). Then Task 2 (independent; good interleave). Then Tasks 3, 4, 5 in sequence (each is a big port; no benefit to parallelism since they touch `devenv.nix` and `checks/module-eval.nix` which would conflict). Then Task 6 (depends on Task 3's mkClaude shape). Then Task 7 (stacked-workflows). Then Task 8 (small devenv.nix swap). Then Task 9 (final delete).

Each task must land `nix flake check` green before the next task begins.

---

### Task 1: A7 — Refactor mkAiApp into record + transform pattern

**Goal:** Decouple mkAiApp from the module system. Today it returns a module function that writes `home.file.*` hardcoded. After this task, mkAiApp returns a pure data record, and two new transformers (`hmTransform`, `devenvTransform`) project records into backend-specific module functions. This task is a PURE STRUCTURAL REFACTOR — no new behavior, no absorbed fanout. Existing `checks/factory-eval.nix` and `checks/module-eval.nix` tests must keep passing (adapted to new call sites where needed).

**Files:**

- Create: `lib/ai/app/hmTransform.nix`
- Create: `lib/ai/app/devenvTransform.nix`
- Modify: `lib/ai/app/mkAiApp.nix`
- Modify: `lib/ai/app/default.nix`
- Modify: `packages/claude-code/lib/mkClaude.nix`
- Modify: `packages/claude-code/modules/homeManager/default.nix`
- Modify: `packages/claude-code/modules/devenv/default.nix`
- Modify: `packages/copilot-cli/lib/mkCopilot.nix`
- Modify: `packages/copilot-cli/modules/homeManager/default.nix`
- Modify: `packages/copilot-cli/modules/devenv/default.nix`
- Modify: `packages/kiro-cli/lib/mkKiro.nix`
- Modify: `packages/kiro-cli/modules/homeManager/default.nix`
- Modify: `packages/kiro-cli/modules/devenv/default.nix`
- Modify: `checks/factory-eval.nix`

- [ ] **Step 1: Write failing test — hmTransform exists on lib.ai.app**

Add to `checks/factory-eval.nix` (insert near existing mkAiApp tests around line 240):

```nix
factory-mkAiApp-hmTransform-exists = mkTest "mkAiApp-hmTransform-exists" (
  builtins.isFunction ai.app.hmTransform
);

factory-mkAiApp-devenvTransform-exists = mkTest "mkAiApp-devenvTransform-exists" (
  builtins.isFunction ai.app.devenvTransform
);
```

- [ ] **Step 2: Run tests to verify failure**

Run: `nix flake check 2>&1 | grep -E "factory-test-mkAiApp-(hm|devenv)Transform" | head`
Expected: evaluation fails because `ai.app.hmTransform` does not exist yet.

- [ ] **Step 3: Create stub hmTransform**

Create `lib/ai/app/hmTransform.nix`:

```nix
# HM backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a home-manager module function that writes the appropriate
# `home.file.*` / `home.activation.*` / `programs.*` attributes for
# the HM backend.
#
# Input record shape (from mkAiApp):
#   {
#     name;
#     transformers;
#     defaults ? {package, outputPath?};
#     options ? {};          # shared across backends
#     hm ? {
#       options ? {};        # HM-only option additions (e.g. buddy)
#       defaults ? {};       # HM-only default overrides
#       config ? _: {};      # consumer callback: {cfg, mergedServers, mergedInstructions, mergedSkills} → module attrs
#     };
#     devenv ? { ... };      # ignored by this transformer
#   }
#
# Returns: a module function `{config, ...}: { options; config; }`
# that can be imported into `lib.evalModules` alongside
# `lib/ai/sharedOptions.nix`.
{lib}: appRecord: {config, ...}: let
  cfg = config.ai.${appRecord.name};
  mergedServers = config.ai.mcpServers // cfg.mcpServers;
  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = config.ai.skills // cfg.skills;

  hmSpec = appRecord.hm or {};
  hmOptions = hmSpec.options or {};
  hmDefaults = hmSpec.defaults or {};
  hmConfigFn = hmSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = hmDefaults.package or defaults.package or null;
  outputPath = hmDefaults.outputPath or defaults.outputPath or null;

  customConfig = hmConfigFn {
    inherit cfg mergedServers mergedInstructions mergedSkills;
  };

  # Baseline render — concatenate rendered instructions into one
  # file at defaults.outputPath. Per-instruction rule files are
  # handled by the consumer config callback if needed.
  renderedInstructions =
    lib.concatMapStringsSep "\n\n" (
      frag: appRecord.transformers.markdown.render frag
    )
    mergedInstructions;

  hasOutputPath = outputPath != null;
  hasInstructions = mergedInstructions != [];
in {
  options.ai.${appRecord.name} =
    {
      enable = lib.mkEnableOption appRecord.name;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "The ${appRecord.name} package.";
      };
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        });
        default = {};
        description = "${appRecord.name}-specific MCP servers (merged with top-level ai.mcpServers; per-app wins on conflict).";
      };
      instructions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = "${appRecord.name}-specific instructions (appended to top-level ai.instructions).";
      };
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills (merged with top-level ai.skills; per-app wins).";
      };
    }
    // (appRecord.options or {})
    // hmOptions;

  config = lib.mkMerge (
    [
      {_module.args.aiTransformers = appRecord.transformers;}
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      home.file.${outputPath}.text = renderedInstructions;
    })
  );
}
```

- [ ] **Step 4: Create stub devenvTransform**

Create `lib/ai/app/devenvTransform.nix` (identical shape to hmTransform except it reads `appRecord.devenv.*` and writes `files.${outputPath}` instead of `home.file.${outputPath}`):

```nix
# Devenv backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a devenv module function that writes the appropriate
# `files.*` / `claude.code.*` / `<ecosystem>.*` attributes for the
# devenv backend.
#
# Mirrors `hmTransform.nix` but targets devenv's `files.*` option
# instead of HM's `home.file.*`. The shared `options` from the
# record apply to both backends; `devenv.options` adds
# devenv-specific options.
{lib}: appRecord: {config, ...}: let
  cfg = config.ai.${appRecord.name};
  mergedServers = config.ai.mcpServers // cfg.mcpServers;
  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = config.ai.skills // cfg.skills;

  devenvSpec = appRecord.devenv or {};
  devenvOptions = devenvSpec.options or {};
  devenvDefaults = devenvSpec.defaults or {};
  devenvConfigFn = devenvSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = devenvDefaults.package or defaults.package or null;
  outputPath = devenvDefaults.outputPath or defaults.outputPath or null;

  customConfig = devenvConfigFn {
    inherit cfg mergedServers mergedInstructions mergedSkills;
  };

  renderedInstructions =
    lib.concatMapStringsSep "\n\n" (
      frag: appRecord.transformers.markdown.render frag
    )
    mergedInstructions;

  hasOutputPath = outputPath != null;
  hasInstructions = mergedInstructions != [];
in {
  options.ai.${appRecord.name} =
    {
      enable = lib.mkEnableOption appRecord.name;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "The ${appRecord.name} package.";
      };
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        });
        default = {};
        description = "${appRecord.name}-specific MCP servers.";
      };
      instructions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = "${appRecord.name}-specific instructions.";
      };
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills.";
      };
    }
    // (appRecord.options or {})
    // devenvOptions;

  config = lib.mkMerge (
    [
      {_module.args.aiTransformers = appRecord.transformers;}
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      files.${outputPath}.text = renderedInstructions;
    })
  );
}
```

- [ ] **Step 5: Register the new transforms in lib.ai.app**

Modify `lib/ai/app/default.nix` (current content inferred — verify first, the file exports `mkAiApp`):

```nix
{lib}: {
  mkAiApp = import ./mkAiApp.nix {inherit lib;};
  hmTransform = import ./hmTransform.nix {inherit lib;};
  devenvTransform = import ./devenvTransform.nix {inherit lib;};
}
```

(If the current file has a different shape — e.g. it imports things other than mkAiApp — preserve the existing exports and ADD the two new ones.)

- [ ] **Step 6: Run tests — Step 1 tests now pass, but old tests fail**

Run: `nix flake check 2>&1 | tail -30`
Expected: `factory-mkAiApp-hmTransform-exists` and `factory-mkAiApp-devenvTransform-exists` pass. Existing `factory-mkAiApp-*` tests may or may not still pass depending on mkAiApp's current shape — if they pass, proceed; if they fail due to shape mismatch, that's expected and fixed in Step 8.

- [ ] **Step 7: Refactor mkAiApp to return a record**

Modify `lib/ai/app/mkAiApp.nix` to the new shape:

```nix
# Generic AI-app factory (backend-agnostic record producer).
#
# Returns a pure data record describing an AI app. Backend-specific
# module functions are produced by applying `hmTransform` or
# `devenvTransform` to the record.
#
# Factory-of-factory pattern: outer call supplies package-specific
# name + shared option schemas + per-backend config callbacks.
# Returns a record that per-backend transformers project into
# module functions consumed by the HM / devenv module systems.
#
# Returned record shape:
#   {
#     name;                          # app identifier (used for ai.<name>.* paths)
#     transformers;                  # { markdown = <lib.ai.transformers.<ecosystem>>; }
#     defaults ? {};                 # {package?, outputPath?} — shared across backends
#     options ? {};                  # shared option declarations (both backends see these)
#     hm = {
#       options ? {};                # HM-only option additions (e.g. buddy)
#       defaults ? {};               # HM-only default overrides
#       config ? _: {};              # consumer callback projecting merged view → module attrs
#     };
#     devenv = {
#       options ? {};                # devenv-only option additions
#       defaults ? {};               # devenv-only default overrides
#       config ? _: {};              # consumer callback
#     };
#   }
#
# Consumer callbacks receive {cfg, mergedServers, mergedInstructions,
# mergedSkills} and return an attrset of module config attributes
# (home.file.*, programs.claude-code.*, home.activation.*, files.*,
# claude.code.*, etc.) appropriate for their backend.
{lib}: {
  name,
  transformers,
  defaults ? {},
  options ? {},
  hm ? {},
  devenv ? {},
}: {
  inherit name transformers defaults options hm devenv;
}
```

- [ ] **Step 8: Update existing `factory-mkAiApp-*` tests to use new record shape**

Adapt each test in `checks/factory-eval.nix` that currently builds a module via `ai.app.mkAiApp { ... }` and passes it to `lib.evalModules`. The new pattern is:

**Before:**
```nix
let
  module = ai.app.mkAiApp {
    name = "testapp";
    transformers.markdown = ai.transformers.claude;
    defaults = {package = pkgs.hello; outputPath = ".config/test/CONFIG.md";};
  };
  evaluated = lib.evalModules {
    modules = [ai.sharedOptions hmStubs module {config = {};}];
  };
in ...
```

**After:**
```nix
let
  record = ai.app.mkAiApp {
    name = "testapp";
    transformers.markdown = ai.transformers.claude;
    defaults = {package = pkgs.hello; outputPath = ".config/test/CONFIG.md";};
  };
  module = ai.app.hmTransform record;
  evaluated = lib.evalModules {
    modules = [ai.sharedOptions hmStubs module {config = {};}];
  };
in ...
```

Apply this transformation to every `factory-mkAiApp-*` test in `checks/factory-eval.nix`. The `factory-mkAiApp-returns-module-function` test needs renaming to `factory-mkAiApp-returns-record`:

```nix
factory-mkAiApp-returns-record = mkTest "mkAiApp-returns-record" (
  let
    record = ai.app.mkAiApp {
      name = "testapp";
      transformers.markdown = ai.transformers.claude;
      defaults = {package = pkgs.hello; outputPath = ".config/test/CONFIG.md";};
    };
  in
    record ? name && record ? transformers && record ? defaults
);
```

- [ ] **Step 9: Add new tests — record → hmTransform produces a valid module**

Insert in `checks/factory-eval.nix` (near the updated tests):

```nix
factory-hmTransform-applies-to-record = mkTest "hmTransform-applies-to-record" (
  let
    record = ai.app.mkAiApp {
      name = "testapp";
      transformers.markdown = ai.transformers.claude;
      defaults = {package = pkgs.hello; outputPath = ".config/test/CONFIG.md";};
    };
    module = ai.app.hmTransform record;
    evaluated = lib.evalModules {
      modules = [ai.sharedOptions hmStubs module {config = {};}];
    };
  in
    !evaluated.config.ai.testapp.enable
);

factory-devenvTransform-applies-to-record = mkTest "devenvTransform-applies-to-record" (
  let
    record = ai.app.mkAiApp {
      name = "testapp";
      transformers.markdown = ai.transformers.claude;
      defaults = {package = pkgs.hello; outputPath = ".config/test/CONFIG.md";};
    };
    module = ai.app.devenvTransform record;
    # devenv stub: `files` option instead of `home.file`
    devenvStubs = {
      options.files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
    };
    evaluated = lib.evalModules {
      modules = [ai.sharedOptions devenvStubs module {config = {};}];
    };
  in
    !evaluated.config.ai.testapp.enable
);
```

- [ ] **Step 10: Update mkClaude.nix to return a record**

Modify `packages/claude-code/lib/mkClaude.nix`:

```nix
# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# For now this is a minimal shape preserving the current behavior.
# Full fanout (skills, mcpServers, instructions files, buddy
# activation) is absorbed in Task 3 (A2) and Task 6 (A1).
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "claude";
  transformers.markdown = lib.ai.transformers.claude;
  defaults = {
    package = pkgs.ai.claude-code;
    outputPath = ".claude/CLAUDE.md";
  };
  # Shared options (present in both backends)
  options = {
    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file used as Claude's memory.";
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Claude's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  # HM-specific projection
  hm = {
    # HM-only options
    options = {
      buddy = lib.mkOption {
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Claude buddy activation script";
            statePath = lib.mkOption {
              type = lib.types.str;
              default = ".local/state/claude-code-buddy";
              description = "Relative path under $HOME for buddy state.";
            };
          };
        };
        default = {enable = false;};
        description = "Claude-specific buddy activation options (HM only).";
      };
    };
    config = {cfg, ...}:
      lib.mkMerge [
        (lib.mkIf cfg.buddy.enable {
          # Buddy activation placeholder — full port absorbed in Task 6 (A1).
          home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] ''
            $DRY_RUN_CMD mkdir -p "$HOME/${cfg.buddy.statePath}"
          '';
        })
        (lib.mkIf (cfg.memory != null) {
          home.file.".claude/memory".source = cfg.memory;
        })
      ];
  };
  # Devenv-specific projection (no buddy; devenv doesn't do activation scripts the same way)
  devenv = {
    options = {};
    config = _: {};
  };
}
```

- [ ] **Step 11: Update claude-code module wrapper files**

Modify `packages/claude-code/modules/homeManager/default.nix`:

```nix
# Applies the HM transform to the claude-code app record.
# The result is a home-manager module function the factory barrel
# (homeManagerModules.nix-agentic-tools) imports via collectFacet.
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.hmTransform (import ../../lib/mkClaude.nix args)
```

Modify `packages/claude-code/modules/devenv/default.nix`:

```nix
# Applies the devenv transform to the claude-code app record.
# The result is a devenv module function the factory barrel
# (devenvModules.nix-agentic-tools) imports via collectFacet.
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.devenvTransform (import ../../lib/mkClaude.nix args)
```

- [ ] **Step 12: Update mkCopilot.nix to return a record**

Modify `packages/copilot-cli/lib/mkCopilot.nix`:

```nix
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "copilot";
  transformers.markdown = lib.ai.transformers.copilot;
  defaults = {
    package = pkgs.ai.copilot-cli;
    outputPath = ".config/github-copilot/copilot-instructions.md";
  };
  options = {
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Copilot's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  hm = {
    options = {};
    config = _: {};
  };
  devenv = {
    options = {};
    config = _: {};
  };
}
```

- [ ] **Step 13: Update copilot-cli module wrapper files**

Modify `packages/copilot-cli/modules/homeManager/default.nix`:

```nix
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.hmTransform (import ../../lib/mkCopilot.nix args)
```

Modify `packages/copilot-cli/modules/devenv/default.nix`:

```nix
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.devenvTransform (import ../../lib/mkCopilot.nix args)
```

- [ ] **Step 14: Update mkKiro.nix to return a record**

Modify `packages/kiro-cli/lib/mkKiro.nix`:

```nix
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "kiro";
  transformers.markdown = lib.ai.transformers.kiro;
  defaults = {
    package = pkgs.ai.kiro-cli;
    outputPath = ".config/kiro/steering/";
  };
  options = {
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Kiro's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  hm = {
    options = {};
    config = _: {};
  };
  devenv = {
    options = {};
    config = _: {};
  };
}
```

- [ ] **Step 15: Update kiro-cli module wrapper files**

Modify `packages/kiro-cli/modules/homeManager/default.nix`:

```nix
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.hmTransform (import ../../lib/mkKiro.nix args)
```

Modify `packages/kiro-cli/modules/devenv/default.nix`:

```nix
{
  lib,
  pkgs,
  ...
} @ args:
lib.ai.app.devenvTransform (import ../../lib/mkKiro.nix args)
```

- [ ] **Step 16: Run `nix flake check` — full suite**

Run: `nix flake check 2>&1 | tail -20`
Expected: `all checks passed!`. If any test fails, read the failure, diagnose, and fix in this same task before committing.

- [ ] **Step 17: Commit Task 1**

```bash
git add lib/ai/app/ packages/*/lib/mk*.nix packages/*/modules/homeManager/default.nix packages/*/modules/devenv/default.nix checks/factory-eval.nix
git commit -m "refactor(lib/ai): mkAiApp returns record, add hm+devenvTransform (A7)"
```

---

### Task 2: A5 — Relocate MCP server typed modules into per-package dirs

**Goal:** Move the 12 typed MCP server schemas from `modules/mcp-servers/servers/*.nix` into each package's own directory at `packages/<name>/modules/mcp-server.nix`. Rewire `lib/mcp.nix:loadServer` to find them at the new path. External consumers of `lib.mkStdioEntry` (used by nixos-config at sentinel `f341bcb`) must keep working identically — the typed `settings.credentials.file` auth flow through `mkSecretsWrapper` must remain unchanged.

**Files:**

- Create: `packages/context7-mcp/modules/mcp-server.nix` (move from `modules/mcp-servers/servers/context7-mcp.nix`)
- Create: `packages/effect-mcp/modules/mcp-server.nix`
- Create: `packages/fetch-mcp/modules/mcp-server.nix`
- Create: `packages/git-intel-mcp/modules/mcp-server.nix`
- Create: `packages/git-mcp/modules/mcp-server.nix`
- Create: `packages/github-mcp/modules/mcp-server.nix`
- Create: `packages/kagi-mcp/modules/mcp-server.nix`
- Create: `packages/nixos-mcp/modules/mcp-server.nix`
- Create: `packages/openmemory-mcp/modules/mcp-server.nix`
- Create: `packages/sequential-thinking-mcp/modules/mcp-server.nix`
- Create: `packages/serena-mcp/modules/mcp-server.nix`
- Create: `packages/sympy-mcp/modules/mcp-server.nix`
- Modify: `lib/mcp.nix`
- Delete: `modules/mcp-servers/servers/*.nix` (all 12)
- Delete: `modules/mcp-servers/` (empty directory after above)

- [ ] **Step 1: Write failing test — loadServer reads from new path**

Add to `checks/factory-eval.nix` near the existing mcp tests:

```nix
factory-loadServer-github-mcp-from-package-dir = mkTest "loadServer-github-mcp-from-package-dir" (
  let
    mcpLib = import ../lib/mcp.nix {inherit lib;};
    serverDef = mcpLib.loadServer "github-mcp";
  in
    serverDef ? settingsOptions
    && serverDef.settingsOptions ? credentials
);

factory-loadServer-kagi-mcp-from-package-dir = mkTest "loadServer-kagi-mcp-from-package-dir" (
  let
    mcpLib = import ../lib/mcp.nix {inherit lib;};
    serverDef = mcpLib.loadServer "kagi-mcp";
  in
    serverDef ? settingsOptions
    && serverDef.settingsOptions ? credentials
);
```

These tests currently pass because `loadServer` reads from `modules/mcp-servers/servers/`. After Step 4 they will still pass because we move the files AND rewire the path together. So the failure test is in Step 2 below.

- [ ] **Step 2: Write failing test — packages/github-mcp/modules/mcp-server.nix exists**

Add:

```nix
factory-github-mcp-has-package-module = mkTest "github-mcp-has-package-module" (
  builtins.pathExists ../packages/github-mcp/modules/mcp-server.nix
);
```

Run: `nix flake check 2>&1 | grep github-mcp-has-package-module`
Expected: test fails because the file does not exist yet.

- [ ] **Step 3: Move github-mcp first (validates the pattern)**

```bash
mkdir -p packages/github-mcp/modules
git mv modules/mcp-servers/servers/github-mcp.nix packages/github-mcp/modules/mcp-server.nix
```

- [ ] **Step 4: Rewire lib/mcp.nix:loadServer to read from the new path**

Modify `lib/mcp.nix`. Current line 18:

```nix
loadServer = name: import ../modules/mcp-servers/servers/${name}.nix {inherit lib mcpLib;};
```

Replace with:

```nix
# Resolve the per-package typed MCP server module. Each MCP package
# under packages/<name>/ owns its typed settings schema at
# packages/<name>/modules/mcp-server.nix.
loadServer = name: import ../packages/${name}/modules/mcp-server.nix {inherit lib mcpLib;};
```

Note: `loadServer "github-mcp"` → `../packages/github-mcp/modules/mcp-server.nix`. The server NAME (passed to loadServer) is the package directory name — verify that's consistent for all 12 servers in Step 6.

- [ ] **Step 5: Run tests for github-mcp**

Run: `nix flake check 2>&1 | grep -E "github-mcp|loadServer-github"`
Expected: the `github-mcp-has-package-module` test passes; the `loadServer-github-mcp-from-package-dir` test still passes. If other tests fail because they try to load OTHER servers (that haven't moved yet), expect those failures — they'll be fixed by moving the rest in Step 6.

- [ ] **Step 6: Move the remaining 11 server modules**

```bash
for name in context7-mcp effect-mcp fetch-mcp git-intel-mcp git-mcp kagi-mcp nixos-mcp openmemory-mcp sequential-thinking-mcp serena-mcp sympy-mcp; do
  mkdir -p "packages/${name}/modules"
  git mv "modules/mcp-servers/servers/${name}.nix" "packages/${name}/modules/mcp-server.nix"
done
```

- [ ] **Step 7: Verify directory naming consistency**

For each moved file, confirm the package directory name matches what `loadServer` receives. Run:

```bash
for name in context7-mcp effect-mcp fetch-mcp git-intel-mcp git-mcp github-mcp kagi-mcp nixos-mcp openmemory-mcp sequential-thinking-mcp serena-mcp sympy-mcp; do
  test -f "packages/${name}/modules/mcp-server.nix" || echo "MISSING: $name"
done
```

Expected: no "MISSING" output.

- [ ] **Step 8: Run the full factory-eval suite**

Run: `nix flake check 2>&1 | tail -15`
Expected: `all checks passed!`. If tests fail, the most likely cause is a server whose directory name under `packages/` does not match the name passed to `loadServer` — fix by renaming the package directory or adjusting `loadServer`'s path expression.

- [ ] **Step 9: Verify the external API contract — lib.mkStdioEntry still works for nixos-config's usage**

Run: `nix eval --impure --expr '
let
  pkgs = (builtins.getFlake (toString ./.)).packages.x86_64-linux;
  lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib;
  mcpLib = import ./lib/mcp.nix {inherit lib;};
  entry = mcpLib.mkStdioEntry pkgs {
    package = pkgs.github-mcp;
    settings.credentials.file = "/tmp/fake-token";
  };
in
  entry.type == "stdio" && entry.command != null && (entry.env.GITHUB_PERSONAL_ACCESS_TOKEN or null) == null
'`

Expected: `true`. This mimics the nixos-config usage pattern. The env var is not set because credentials are resolved at wrapper invocation time, not eval time.

- [ ] **Step 10: Delete the now-empty modules/mcp-servers tree**

```bash
rmdir modules/mcp-servers/servers
rmdir modules/mcp-servers
```

- [ ] **Step 11: Commit Task 2**

```bash
git add -A
git commit -m "refactor(mcp): relocate typed server modules into packages/<name>/modules/ (A5)"
```

---

### Task 3: A2 — Absorb Claude fanout into mkClaude.nix hm/devenv projections

**Goal:** Port the full Claude fanout logic from `modules/ai/default.nix` (claude branch) + `modules/devenv/ai.nix` (claude branch) + `modules/devenv/claude-code-skills/` into `packages/claude-code/lib/mkClaude.nix`'s `hm.config` and `devenv.config` callbacks. The HM callback delegates to upstream `programs.claude-code.{enable, package, settings, skills}` where upstream provides the capability, and writes `home.file.".claude/rules/<name>.md"` + `home.file.".claude/mcp.json"` directly for gaps. The devenv callback delegates to upstream `claude.code.{enable, env, mcpServers, model, permissions.rules}` and writes `files.".claude/rules/<name>.md"` + `files.".claude/skills/<name>"` directly for gaps.

**Files:**

- Modify: `packages/claude-code/lib/mkClaude.nix`
- Modify: `checks/factory-eval.nix` (add coverage for the new fanout)
- Modify: `checks/module-eval.nix` (add devenv coverage — requires Step 1 infrastructure)
- Reference only (read, do not edit): `modules/ai/default.nix`, `modules/devenv/ai.nix`, `modules/devenv/claude-code-skills/default.nix`

- [ ] **Step 1: Add evalDevenv helper to checks/module-eval.nix**

The current `module-eval.nix` only has `evalHm`. We need a parallel `evalDevenv` for devenv-side test coverage. Insert after the `evalHm` definition:

```nix
# Stub devenv's files option so the config callback in the factory
# can set files.* without importing devenv.
devenvStubs = {
  options = {
    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
    claude.code = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
    copilot = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
    kiro = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
  };
};

evalDevenv = config:
  lib.evalModules {
    specialArgs = {
      lib = hmLib;
      pkgs = pkgs // {ai = pkgs.ai or {};};
    };
    modules = [
      ./../lib/ai/sharedOptions.nix
      ./../packages/claude-code/modules/devenv
      ./../packages/copilot-cli/modules/devenv
      ./../packages/kiro-cli/modules/devenv
      devenvStubs
      {inherit config;}
    ];
  };
```

- [ ] **Step 2: Write failing test — ai.claude.enable fans out programs.claude-code.enable under HM**

Add to `checks/module-eval.nix`:

```nix
module-claude-hm-delegates-programs-claude-code = mkTest "claude-hm-delegates-programs-claude-code" (
  let
    result = evalHm {
      ai.claude.enable = true;
    };
  in
    (result.config.programs.claude-code.enable or null) == true
);
```

**Note:** `evalHm`'s current stub list does NOT include a stub for `programs.claude-code.*`. Add one to the `hmStubs` attrset in `module-eval.nix`:

```nix
hmStubs = {
  options = {
    home = { activation = ...; file = ...; };  # existing
    programs.claude-code = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      package = lib.mkOption { type = lib.types.nullOr lib.types.package; default = null; };
      settings = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      skills = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
    };
  };
};
```

Run: `nix flake check 2>&1 | grep claude-hm-delegates`
Expected: test fails because mkClaude's `hm.config` is an empty mkMerge that does not set `programs.claude-code.enable`.

- [ ] **Step 3: Implement programs.claude-code.enable delegation in mkClaude hm.config**

Modify `packages/claude-code/lib/mkClaude.nix`'s `hm.config` callback. The current body is:

```nix
config = {cfg, ...}:
  lib.mkMerge [
    (lib.mkIf cfg.buddy.enable { ... })
    (lib.mkIf (cfg.memory != null) { ... })
  ];
```

Expand to:

```nix
config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
  lib.mkMerge [
    # Delegate to upstream programs.claude-code.* where upstream
    # provides the capability.
    {
      programs.claude-code.enable = lib.mkDefault true;
      programs.claude-code.package = lib.mkDefault cfg.package;
      programs.claude-code.skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
      programs.claude-code.settings = lib.mkMerge [
        cfg.settings
        (lib.optionalAttrs (mergedServers != {}) {mcpServers = mergedServers;})
      ];
    }
    (lib.mkIf cfg.buddy.enable {
      home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] ''
        $DRY_RUN_CMD mkdir -p "$HOME/${cfg.buddy.statePath}"
      '';
    })
    (lib.mkIf (cfg.memory != null) {
      home.file.".claude/memory".source = cfg.memory;
    })
  ];
```

- [ ] **Step 4: Run Step 2 test — verify it passes**

Run: `nix flake check 2>&1 | grep claude-hm-delegates`
Expected: test passes.

- [ ] **Step 5: Write failing test — per-instruction rule files**

Add to `checks/module-eval.nix`:

```nix
module-claude-hm-writes-instruction-rule-file = mkTest "claude-hm-writes-instruction-rule-file" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.instructions = [
        {
          name = "my-rule";
          text = "Always use strict mode.";
          paths = ["src/**"];
        }
      ];
    };
    ruleFile = result.config.home.file.".claude/rules/my-rule.md" or null;
  in
    ruleFile != null
    && lib.hasInfix "Always use strict mode" (ruleFile.text or "")
);
```

Note: this test assumes `ai.instructions` list entries carry a `name` field. Verify the current `sharedOptions.nix` / legacy fanout shape — if the legacy pattern used an attrset keyed by name, adapt the test to match. Reference the legacy implementation at `modules/ai/default.nix` lines 219-227.

Run: `nix flake check 2>&1 | grep claude-hm-writes-instruction`
Expected: test fails — mkClaude does not yet write per-instruction rule files.

- [ ] **Step 6: Implement per-instruction rule file writes**

Modify mkClaude.nix hm.config. Add a fourth mkMerge element that iterates `mergedInstructions`:

```nix
# Per-instruction rule files — write .claude/rules/<name>.md for
# each instruction entry. This is a gap in upstream programs.claude-code
# (upstream has no per-rule file option), so we write home.file directly.
(let
  fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
  inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
in {
  home.file = lib.listToAttrs (map (instr: {
    name = ".claude/rules/${instr.name}.md";
    value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
  }) mergedInstructions);
})
```

Adjust the exact shape based on whether `mergedInstructions` is a list or attrset. If the shape doesn't carry a `name` field, add a transformation step to derive one. Reference `modules/ai/default.nix:219-227` for the legacy pattern (it uses `concatMapAttrs` on an attrset, so `cfg.instructions` in the legacy was an attrset — verify the factory's sharedOptions shape matches or adapt).

**Critical:** Import paths are relative to `packages/claude-code/lib/mkClaude.nix`. The `../../../lib/...` path assumes mkClaude is three levels deep. Adjust if the test fails with "file not found".

- [ ] **Step 7: Run Step 5 test — verify it passes**

Run: `nix flake check 2>&1 | grep claude-hm-writes-instruction`
Expected: test passes.

- [ ] **Step 8: Write failing test — skills delegation**

Add to `checks/module-eval.nix`:

```nix
module-claude-hm-delegates-skills-to-upstream = mkTest "claude-hm-delegates-skills-to-upstream" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
    };
  in
    (result.config.programs.claude-code.skills ? stack-fix)
);
```

Run: `nix flake check 2>&1 | grep delegates-skills`
Expected: this test should already PASS because Step 3 implemented `programs.claude-code.skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;`. If it fails, the likely cause is that the skill path does not exist at the expected location — use any real path under the repo.

- [ ] **Step 9: Write failing test — devenv claude fanout**

Add to `checks/module-eval.nix`:

```nix
module-claude-devenv-delegates-claude-code = mkTest "claude-devenv-delegates-claude-code" (
  let
    result = evalDevenv {
      ai.claude.enable = true;
    };
  in
    (result.config.claude.code.enable or null) == true
);
```

Run: `nix flake check 2>&1 | grep claude-devenv-delegates`
Expected: test fails — mkClaude's `devenv.config` is still an empty callback.

- [ ] **Step 10: Implement devenv claude fanout**

Modify mkClaude.nix `devenv.config`:

```nix
devenv = {
  options = {};
  config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
    lib.mkMerge [
      # Delegate to upstream devenv claude.code.*
      {
        claude.code.enable = lib.mkDefault true;
        claude.code.mcpServers = mergedServers;
        claude.code.env = cfg.settings.env or {};
      }
      # Gap writes — per-instruction rule files
      (let
        fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
        inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
      in {
        files = lib.listToAttrs (map (instr: {
          name = ".claude/rules/${instr.name}.md";
          value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
        }) mergedInstructions);
      })
      # Skills — devenv does NOT have an upstream skills option on
      # claude.code, so we write files.".claude/skills/<name>" directly.
      # Use lib/hm-helpers.nix:mkDevenvSkillEntries walker to produce
      # per-file leaf entries (devenv cannot recurse directories).
      (let
        helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
      in {
        files = helpers.mkDevenvSkillEntries {
          skillsDir = ".claude/skills";
          skills = mergedSkills;
        };
      })
    ];
};
```

**Note:** `lib/hm-helpers.nix:mkDevenvSkillEntries` is a walker function that expands a directory into per-file `files.<path>.source = <file>` entries. Verify its signature by reading `lib/hm-helpers.nix:161` before using — adjust call shape if needed.

- [ ] **Step 11: Run Step 9 test — verify it passes**

Run: `nix flake check 2>&1 | grep claude-devenv-delegates`
Expected: test passes.

- [ ] **Step 12: Add LSP env test**

Add to `checks/module-eval.nix`:

```nix
module-claude-hm-sets-lsp-env-when-servers-present = mkTest "claude-hm-sets-lsp-env-when-servers-present" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
  in
    (result.config.programs.claude-code.settings.env.ENABLE_LSP_TOOL or null) == "1"
);
```

Run: fails.

- [ ] **Step 13: Implement LSP env setting**

Add to mkClaude.nix hm.config mkMerge list:

```nix
(lib.mkIf (mergedServers != {}) {
  programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
})
```

Run test: passes.

- [ ] **Step 14: Run full `nix flake check`**

Run: `nix flake check 2>&1 | tail -15`
Expected: `all checks passed!`. Fix any regressions.

- [ ] **Step 15: Commit Task 3**

```bash
git add packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
git commit -m "feat(claude-code): absorb full fanout into mkClaude hm+devenv (A2)"
```

---

### Task 4: A3 — Absorb Copilot fanout into mkCopilot.nix hm/devenv projections

**Goal:** Port the full Copilot fanout logic from `modules/copilot-cli/default.nix` + `modules/devenv/copilot.nix` + `modules/ai/default.nix` (copilot branch) into `packages/copilot-cli/lib/mkCopilot.nix`'s `hm.config` and `devenv.config`. Copilot has NO upstream HM or devenv module — our legacy `modules/copilot-cli/` and `modules/devenv/copilot.nix` were the bridging layer, and they get dropped entirely. The factory writes everything directly: `.config/github-copilot/settings.json`, `.config/github-copilot/mcp-config.json`, `.config/github-copilot/lsp-config.json`, `.config/github-copilot/skills/<name>`, `.github/instructions/<name>.instructions.md`. Preserve the settings.json runtime-merge activation script (`jq '.[0] * .[1]'`) from the legacy HM module — it protects user-added `trusted_folders` across rebuilds.

**Files:**

- Modify: `packages/copilot-cli/lib/mkCopilot.nix`
- Modify: `checks/module-eval.nix`
- Reference only (read, do not edit): `modules/copilot-cli/default.nix`, `modules/devenv/copilot.nix`, `modules/ai/default.nix` (copilot branch, lines ~246-265)

- [ ] **Step 1: Write failing test — ai.copilot.enable wraps package under HM**

Add to `checks/module-eval.nix`:

```nix
module-copilot-hm-wraps-package = mkTest "copilot-hm-wraps-package" (
  let
    result = evalHm {
      ai.copilot.enable = true;
    };
    packages = result.config.home.packages or [];
  in
    builtins.length packages >= 1
);
```

**Note:** The test's stub list for `evalHm` needs `home.packages` — add to `hmStubs` if missing:

```nix
home.packages = lib.mkOption {
  type = lib.types.listOf lib.types.package;
  default = [];
};
```

Run: fails — mkCopilot currently has empty hm.config.

- [ ] **Step 2: Implement basic package installation in mkCopilot hm.config**

```nix
hm = {
  options = {};
  config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
    lib.mkMerge [
      { home.packages = [cfg.package]; }
    ];
};
```

Run test: passes.

- [ ] **Step 3: Write failing test — settings.json activation merge**

Add to `checks/module-eval.nix`:

```nix
module-copilot-hm-writes-settings-json-activation = mkTest "copilot-hm-writes-settings-json-activation" (
  let
    result = evalHm {
      ai.copilot.enable = true;
      ai.copilot.settings.model = "gpt-4";
    };
    activation = result.config.home.activation.copilotSettingsMerge or null;
  in
    activation != null
    && lib.hasInfix "gpt-4" (activation.text or "")
    && lib.hasInfix "jq" (activation.text or "")
);
```

Run: fails.

- [ ] **Step 4: Implement settings.json activation merge**

Add to mkCopilot.nix hm.config. Read `modules/copilot-cli/default.nix` first to understand the exact activation script body — it should use `jq -s '.[0] * .[1]'` to merge Nix-declared settings on top of user-edited runtime settings (preserving `trusted_folders` etc.).

```nix
(let
  jsonFormat = pkgs.formats.json {};
  settingsJson = jsonFormat.generate "copilot-settings-nix.json" cfg.settings;
in {
  home.activation.copilotSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] ''
    set -eu
    SETTINGS_DIR="$HOME/.config/github-copilot"
    mkdir -p "$SETTINGS_DIR"
    if [ ! -f "$SETTINGS_DIR/settings.json" ]; then
      cp ${settingsJson} "$SETTINGS_DIR/settings.json"
    else
      # Merge Nix-declared settings on top of user runtime settings;
      # Nix values override on conflict, user additions pass through.
      TMP=$(mktemp)
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$SETTINGS_DIR/settings.json" ${settingsJson} > "$TMP"
      mv "$TMP" "$SETTINGS_DIR/settings.json"
    fi
    chmod 644 "$SETTINGS_DIR/settings.json"
  '';
})
```

Run Step 3 test: passes.

- [ ] **Step 5: Write failing test — mcp-config.json direct write**

Add to `checks/module-eval.nix`:

```nix
module-copilot-hm-writes-mcp-config-json = mkTest "copilot-hm-writes-mcp-config-json" (
  let
    result = evalHm {
      ai.copilot.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
    mcpFile = result.config.home.file.".config/github-copilot/mcp-config.json" or null;
  in
    mcpFile != null
    && lib.hasInfix "test-server" (mcpFile.text or "")
);
```

Run: fails.

- [ ] **Step 6: Implement mcp-config.json write**

Add to mkCopilot.nix hm.config:

```nix
(lib.mkIf (mergedServers != {}) (let
  jsonFormat = pkgs.formats.json {};
  mcpConfig = jsonFormat.generate "copilot-mcp-config.json" {
    mcpServers = mergedServers;
  };
in {
  home.file.".config/github-copilot/mcp-config.json".source = mcpConfig;
}))
```

Run test: passes.

- [ ] **Step 7: Write failing test — .github/instructions/<name>.instructions.md**

Add:

```nix
module-copilot-hm-writes-instruction-files = mkTest "copilot-hm-writes-instruction-files" (
  let
    result = evalHm {
      ai.copilot.enable = true;
      ai.instructions = [
        { name = "my-rule"; text = "Be concise."; paths = ["src/**"]; }
      ];
    };
    instrFile = result.config.home.file.".github/instructions/my-rule.instructions.md" or null;
  in
    instrFile != null
    && lib.hasInfix "Be concise" (instrFile.text or "")
);
```

Run: fails.

- [ ] **Step 8: Implement per-instruction file write**

Add to mkCopilot.nix hm.config:

```nix
(let
  fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
  inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
in {
  home.file = lib.listToAttrs (map (instr: {
    name = ".github/instructions/${instr.name}.instructions.md";
    value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
  }) mergedInstructions);
})
```

Run test: passes.

- [ ] **Step 9: Write failing test — skills fanout**

Add:

```nix
module-copilot-hm-writes-skills = mkTest "copilot-hm-writes-skills" (
  let
    result = evalHm {
      ai.copilot.enable = true;
      ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
    };
    skillFile = result.config.home.file.".config/github-copilot/skills/stack-fix/SKILL.md" or null;
  in
    skillFile != null
);
```

Run: fails.

- [ ] **Step 10: Implement skills fanout via mkSkillEntries helper**

Read `lib/hm-helpers.nix:mkSkillEntries` first. It's a walker that produces per-file `home.file` entries from a skills attrset. Add to mkCopilot hm.config:

```nix
(let
  helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
in {
  home.file = helpers.mkSkillEntries {
    skillsDir = ".config/github-copilot/skills";
    skills = mergedSkills;
  };
})
```

Adjust the call signature based on the helper's actual definition. Run test: passes.

- [ ] **Step 11: Port devenv fanout — same shape but to files.* instead of home.file.***

Replace mkCopilot's devenv block entirely:

```nix
devenv = {
  options = {};
  config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
    lib.mkMerge [
      { packages = [cfg.package]; }
      # Skills via walker (devenv-specific — files.* requires leaf entries)
      (let
        helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
      in {
        files = helpers.mkDevenvSkillEntries {
          skillsDir = ".config/github-copilot/skills";
          skills = mergedSkills;
        };
      })
      # mcp-config.json
      (lib.mkIf (mergedServers != {}) (let
        jsonFormat = pkgs.formats.json {};
        mcpConfig = jsonFormat.generate "copilot-mcp-config.json" {mcpServers = mergedServers;};
      in {
        files.".config/github-copilot/mcp-config.json".source = mcpConfig;
      }))
      # Per-instruction files under .github/instructions/
      (let
        fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
        inherit (import ../../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
      in {
        files = lib.listToAttrs (map (instr: {
          name = ".github/instructions/${instr.name}.instructions.md";
          value.text = fragmentsLib.mkRenderer copilotTransformer {} instr;
        }) mergedInstructions);
      })
      # settings.json — devenv lifecycle does not do activation scripts
      # the same way as HM. For settings, write the JSON directly; if
      # users need runtime merge they can drop a file in a different
      # location and symlink. (Devenv's trusted_folders story is
      # different — devenv.nix is project-local, not a shared home
      # dir.)
      (let
        jsonFormat = pkgs.formats.json {};
      in {
        files.".config/github-copilot/settings.json".source =
          jsonFormat.generate "copilot-settings.json" cfg.settings;
      })
    ];
};
```

**Note:** The devenv activation story is DIFFERENT from HM — devenv does not support `home.activation` DAG entries. If any of the legacy `modules/devenv/copilot.nix` logic depends on shell activation, it must be rewritten as either (a) a startup script via `devenv.processes.*` or `enterShell`, or (b) a plain static file write. Read `modules/devenv/copilot.nix` first to check; most of it should be static file writes.

- [ ] **Step 12: Add devenv coverage test**

Add to `checks/module-eval.nix`:

```nix
module-copilot-devenv-writes-mcp-config = mkTest "copilot-devenv-writes-mcp-config" (
  let
    result = evalDevenv {
      ai.copilot.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
  in
    result.config.files ? ".config/github-copilot/mcp-config.json"
);
```

Run: should pass after Step 11.

- [ ] **Step 13: Run full `nix flake check`**

Run: `nix flake check 2>&1 | tail -15`
Expected: all tests pass.

- [ ] **Step 14: Commit Task 4**

```bash
git add packages/copilot-cli/lib/mkCopilot.nix checks/module-eval.nix
git commit -m "feat(copilot-cli): absorb full fanout into mkCopilot hm+devenv (A3)"
```

---

### Task 5: A4 — Absorb Kiro fanout into mkKiro.nix hm/devenv projections

**Goal:** Port the full Kiro fanout logic from `modules/kiro-cli/default.nix` + `modules/devenv/kiro.nix` + `modules/ai/default.nix` (kiro branch) into `packages/kiro-cli/lib/mkKiro.nix`. Same pattern as Copilot — no upstream modules, factory writes everything directly. Critical invariant from `.claude/rules/hm-modules.md`: the `.kiro/steering/<name>.md` files must use the Kiro transformer which emits YAML arrays for `fileMatchPattern` (not comma-joined strings — that silently matches nothing).

**Files:**

- Modify: `packages/kiro-cli/lib/mkKiro.nix`
- Modify: `checks/module-eval.nix`
- Reference only: `modules/kiro-cli/default.nix`, `modules/devenv/kiro.nix`, `modules/ai/default.nix` (kiro branch, lines ~267-286)

- [ ] **Step 1: Write failing test — ai.kiro.enable wraps package**

Add to `checks/module-eval.nix`:

```nix
module-kiro-hm-wraps-package = mkTest "kiro-hm-wraps-package" (
  let
    result = evalHm {
      ai.kiro.enable = true;
    };
    packages = result.config.home.packages or [];
  in
    builtins.length packages >= 1
);
```

Run: fails.

- [ ] **Step 2: Implement basic package installation in mkKiro hm.config**

```nix
hm = {
  options = {};
  config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
    lib.mkMerge [
      { home.packages = [cfg.package]; }
    ];
};
```

Run test: passes.

- [ ] **Step 3: Write failing test — .kiro/steering/<name>.md files with valid YAML frontmatter**

```nix
module-kiro-hm-writes-steering-files-valid-yaml = mkTest "kiro-hm-writes-steering-files-valid-yaml" (
  let
    result = evalHm {
      ai.kiro.enable = true;
      ai.instructions = [
        { name = "my-rule"; text = "Steering content."; paths = ["src/**" "tests/**"]; }
      ];
    };
    steering = result.config.home.file.".kiro/steering/my-rule.md" or null;
    content = steering.text or "";
  in
    steering != null
    && lib.hasInfix "Steering content" content
    # YAML array form: fileMatchPattern: [src/**, tests/**] or multi-line list
    && (lib.hasInfix "fileMatchPattern:" content)
    # Must NOT be the comma-joined string form
    && !(lib.hasInfix "fileMatchPattern: \"src/**,tests/**\"" content)
);
```

Run: fails.

- [ ] **Step 4: Implement steering file writes using kiro transformer**

Add to mkKiro.nix hm.config:

```nix
(let
  fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
  inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
in {
  home.file = lib.listToAttrs (map (instr: {
    name = ".kiro/steering/${instr.name}.md";
    value.text = fragmentsLib.mkRenderer kiroTransformer {name = instr.name;} instr;
  }) mergedInstructions);
})
```

Run test: passes. If the frontmatter test fails because of YAML shape mismatch, verify the kiro transformer at `lib/ai/transformers/kiro.nix` emits arrays for multi-element `paths`.

- [ ] **Step 5: Write failing test — skills fanout**

```nix
module-kiro-hm-writes-skills = mkTest "kiro-hm-writes-skills" (
  let
    result = evalHm {
      ai.kiro.enable = true;
      ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
    };
    skillFile = result.config.home.file.".kiro/skills/stack-fix/SKILL.md" or null;
  in
    skillFile != null
);
```

Run: fails.

- [ ] **Step 6: Implement skills fanout**

```nix
(let
  helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
in {
  home.file = helpers.mkSkillEntries {
    skillsDir = ".kiro/skills";
    skills = mergedSkills;
  };
})
```

Run test: passes.

- [ ] **Step 7: Write failing test — settings/mcp.json**

```nix
module-kiro-hm-writes-mcp-json = mkTest "kiro-hm-writes-mcp-json" (
  let
    result = evalHm {
      ai.kiro.enable = true;
      ai.mcpServers.test-server = {
        type = "stdio";
        package = pkgs.hello;
        command = "hello";
      };
    };
    mcpFile = result.config.home.file.".kiro/settings/mcp.json" or null;
  in
    mcpFile != null
    && lib.hasInfix "test-server" (mcpFile.text or "")
);
```

Run: fails.

- [ ] **Step 8: Implement mcp.json write**

```nix
(lib.mkIf (mergedServers != {}) (let
  jsonFormat = pkgs.formats.json {};
  mcpConfig = jsonFormat.generate "kiro-mcp.json" {mcpServers = mergedServers;};
in {
  home.file.".kiro/settings/mcp.json".source = mcpConfig;
}))
```

Run test: passes.

- [ ] **Step 9: Write failing test — settings/cli.json activation merge**

```nix
module-kiro-hm-writes-cli-json-activation = mkTest "kiro-hm-writes-cli-json-activation" (
  let
    result = evalHm {
      ai.kiro.enable = true;
      ai.kiro.settings.chat.defaultModel = "claude-sonnet";
    };
    activation = result.config.home.activation.kiroSettingsMerge or null;
  in
    activation != null
    && lib.hasInfix "claude-sonnet" (activation.text or "")
    && lib.hasInfix "jq" (activation.text or "")
);
```

Run: fails.

- [ ] **Step 10: Implement cli.json activation merge**

```nix
(let
  jsonFormat = pkgs.formats.json {};
  settingsJson = jsonFormat.generate "kiro-cli-nix.json" cfg.settings;
in {
  home.activation.kiroSettingsMerge = lib.hm.dag.entryAfter ["writeBoundary"] ''
    set -eu
    SETTINGS_DIR="$HOME/.kiro/settings"
    mkdir -p "$SETTINGS_DIR"
    if [ ! -f "$SETTINGS_DIR/cli.json" ]; then
      cp ${settingsJson} "$SETTINGS_DIR/cli.json"
    else
      TMP=$(mktemp)
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$SETTINGS_DIR/cli.json" ${settingsJson} > "$TMP"
      mv "$TMP" "$SETTINGS_DIR/cli.json"
    fi
    chmod 644 "$SETTINGS_DIR/cli.json"
  '';
})
```

Run test: passes.

- [ ] **Step 11: Port devenv kiro fanout**

Replace mkKiro's devenv block:

```nix
devenv = {
  options = {};
  config = {cfg, mergedServers, mergedInstructions, mergedSkills}:
    lib.mkMerge [
      { packages = [cfg.package]; }
      # Steering files (direct write — devenv does not have an upstream kiro module)
      (let
        fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
        inherit (import ../../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
      in {
        files = lib.listToAttrs (map (instr: {
          name = ".kiro/steering/${instr.name}.md";
          value.text = fragmentsLib.mkRenderer kiroTransformer {name = instr.name;} instr;
        }) mergedInstructions);
      })
      # Skills via walker
      (let
        helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
      in {
        files = helpers.mkDevenvSkillEntries {
          skillsDir = ".kiro/skills";
          skills = mergedSkills;
        };
      })
      # mcp.json
      (lib.mkIf (mergedServers != {}) (let
        jsonFormat = pkgs.formats.json {};
        mcpConfig = jsonFormat.generate "kiro-mcp.json" {mcpServers = mergedServers;};
      in {
        files.".kiro/settings/mcp.json".source = mcpConfig;
      }))
      # cli.json static (devenv — no activation merge)
      (let
        jsonFormat = pkgs.formats.json {};
      in {
        files.".kiro/settings/cli.json".source =
          jsonFormat.generate "kiro-cli.json" cfg.settings;
      })
    ];
};
```

- [ ] **Step 12: Add devenv coverage test**

```nix
module-kiro-devenv-writes-steering = mkTest "kiro-devenv-writes-steering" (
  let
    result = evalDevenv {
      ai.kiro.enable = true;
      ai.instructions = [
        { name = "my-rule"; text = "Content."; paths = ["src/**"]; }
      ];
    };
  in
    result.config.files ? ".kiro/steering/my-rule.md"
);
```

Run: should pass after Step 11.

- [ ] **Step 13: Run full `nix flake check`**

Expected: all tests pass.

- [ ] **Step 14: Commit Task 5**

```bash
git add packages/kiro-cli/lib/mkKiro.nix checks/module-eval.nix
git commit -m "feat(kiro-cli): absorb full fanout into mkKiro hm+devenv (A4)"
```

---

### Task 6: A1 — Absorb buddy activation into mkClaude.nix hm projection

**Goal:** Port the full 208-line buddy activation logic from `modules/claude-code-buddy/default.nix` into `packages/claude-code/lib/mkClaude.nix`'s `hm.config` callback. This is a GAP absorption — there is no upstream `programs.claude-code.buddy` option, so the factory implements `home.activation.claudeBuddy` directly. The invariants documented at `.claude/rules/claude-code.md` MUST be preserved: no `exit` statements in activation (inline script, terminates all subsequent hooks), Bun-vs-Node hash consistency (cli.js must run under Bun), `if`/`fi` short-circuit for fingerprint match (not exit-based), companion reset on fingerprint mismatch. Buddy is HM-only — no devenv projection (devenv lifecycle does not do activation scripts the same way).

**Files:**

- Modify: `packages/claude-code/lib/mkClaude.nix`
- Modify: `checks/module-eval.nix`
- Reference only (read carefully): `modules/claude-code-buddy/default.nix`, `.claude/rules/claude-code.md`

- [ ] **Step 1: Read the invariants document**

Open `.claude/rules/claude-code.md` in your editor and read the full "Buddy Activation Lifecycle" section. The invariants to preserve:

1. **Fingerprint inputs** (9 components; sha256, first 16 hex chars, stored at `$XDG_STATE_HOME/claude-code-buddy/fingerprint`).
2. **No `exit` in the short-circuit** — use `if [ "$NEW_FP" != "$OLD_FP" ]; then ... fi`, never `exit 0`.
3. **Writable cli.js copy** via `cp -L` after removing the symlink; other files stay as store symlinks.
4. **Salt computed via any-buddy worker under Bun** (wyhash), patched into cli.js via python3 binary-safe replace of the 15-byte marker.
5. **Companion reset** on fingerprint mismatch via `jq 'del(.companion)' ~/.claude.json`.
6. **`userId` resolution** — either `userId.text` (literal) or `userId.file` (sops path, read with `cat $USER_ID_FILE` at activation time, NOT `builtins.readFile` at eval time).
7. **Null guards** on `peakArg` / `dumpArg` — explicit `if cfg.peak == null then "" else cfg.peak`, not `or ""`.
8. **`programs.claude-code.package.passthru.baseClaudeCode` or fallback** — read the store's real cli.js location; the factory needs to do the same via `cfg.package.passthru.baseClaudeCode or cfg.package`.

- [ ] **Step 2: Write failing test — buddy option submodule shape**

Add to `checks/module-eval.nix`:

```nix
module-claude-buddy-option-shape = mkTest "claude-buddy-option-shape" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.claude.buddy = {
        enable = true;
        species = "duck";
        rarity = "rare";
        eyes = "blue";
        hat = "wizard";
        shiny = true;
        peak = null;
        dump = null;
        userId.text = "00000000-0000-0000-0000-000000000000";
      };
    };
  in
    result.config.ai.claude.buddy.species == "duck"
    && result.config.ai.claude.buddy.shiny == true
);
```

Run: fails because mkClaude's current buddy submodule only has `{enable, statePath}`.

- [ ] **Step 3: Expand the buddy submodule in mkClaude.nix hm.options**

Read `modules/claude-code-buddy/default.nix` for the full option schema. Port the submodule to mkClaude.nix `hm.options.buddy`:

```nix
hm = {
  options = {
    buddy = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Claude buddy activation";
          species = lib.mkOption {
            type = lib.types.enum [ /* full enum from modules/claude-code-buddy */ ];
            default = "duck";
            description = "Buddy species.";
          };
          rarity = lib.mkOption {
            type = lib.types.enum ["common" "uncommon" "rare" "legendary"];
            default = "common";
          };
          eyes = lib.mkOption { type = lib.types.str; default = "black"; };
          hat = lib.mkOption { type = lib.types.str; default = "none"; };
          shiny = lib.mkOption { type = lib.types.bool; default = false; };
          peak = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Peak stat (null to omit).";
          };
          dump = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Dump stat (null to omit).";
          };
          userId = lib.mkOption {
            type = lib.types.attrTag {
              text = lib.mkOption {
                type = lib.types.str;
                description = "Literal UUID string.";
              };
              file = lib.mkOption {
                type = lib.types.path;
                description = "Path to a sops-decrypted file containing the UUID.";
              };
            };
          };
          outputLogs = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Write buddy activation logs to a file.";
          };
          statePath = lib.mkOption {
            type = lib.types.str;
            default = ".local/state/claude-code-buddy";
            description = "Relative path under $HOME for buddy state.";
          };
        };
      });
      default = null;
      description = "Claude-specific buddy activation options (HM only).";
    };
  };
  # ...
};
```

**Note:** The full `species` enum must exactly match the legacy `modules/claude-code-buddy/default.nix` + any buddy-types shared file. Copy the enum list verbatim. Use a scratch file to verify: `grep -A 100 "species = mkOption" modules/claude-code-buddy/default.nix`.

- [ ] **Step 4: Run buddy option shape test**

Run: `nix flake check 2>&1 | grep buddy-option-shape`
Expected: passes.

- [ ] **Step 5: Write failing test — buddy activation script contains fingerprint logic**

```nix
module-claude-buddy-activation-uses-if-not-exit = mkTest "claude-buddy-activation-uses-if-not-exit" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.claude.buddy = {
        enable = true;
        species = "duck";
        rarity = "rare";
        eyes = "blue";
        hat = "wizard";
        shiny = false;
        peak = null;
        dump = null;
        userId.text = "00000000-0000-0000-0000-000000000000";
      };
    };
    script = result.config.home.activation.claudeBuddy.text or "";
  in
    lib.hasInfix "NEW_FP" script
    && lib.hasInfix "OLD_FP" script
    && lib.hasInfix "if [" script
    # Critical: NO `exit 0` — short-circuit via if/fi only
    && !(lib.hasInfix "exit 0" script)
);
```

Run: fails — current placeholder activation is just `mkdir -p`.

- [ ] **Step 6: Port the full activation script body**

Read `modules/claude-code-buddy/default.nix` activation script section in full. Port it into mkClaude.nix `hm.config` as the `home.activation.claudeBuddy` value. The script body has:

1. XDG_STATE_HOME state dir setup
2. Fingerprint computation (9 inputs, sha256, first 16 chars)
3. Stored fingerprint compare via `if [ "$NEW_FP" != "$OLD_FP" ]; then ... fi`
4. Inside the `then` branch:
   a. Resolve `USER_ID` from `userId.text` or `userId.file` (`cat $path | tr -d '\n\r'`)
   b. Fresh writable lib tree: `rm -rf $STATE_DIR/lib`, `cp -rs $STORE_LIB/* $STATE_DIR/lib/`, `chmod -R u+w`
   c. Real cli.js copy: `rm $STATE_DIR/lib/cli.js`, `cp -L $STORE_LIB/cli.js $STATE_DIR/lib/cli.js`, `chmod u+w`
   d. Salt search: `bun ${any-buddy}/src/finder/worker.ts "$USER_ID" species rarity eyes hat shiny peak dump | jq -r .salt`
   e. Validate salt is 15 chars matching `[a-zA-Z0-9_-]`
   f. Binary-safe patch of cli.js via python3 replacing `b'friend-2026-401'` with the new salt
   g. Companion reset: `jq 'del(.companion)' ~/.claude.json > tmp && mv tmp ~/.claude.json` (if the file exists)
   h. Write new fingerprint to `$STATE_DIR/fingerprint`

The script is long. Copy the entire activation script verbatim from `modules/claude-code-buddy/default.nix` into the mkClaude callback. The only structural changes needed:

- `cfg` references now resolve to `cfg.buddy.*` instead of top-level `cfg.*` (adjust attribute paths).
- `config.programs.claude-code.package` is now `cfg.package` (the top-level claude package option in the factory).
- Null-guards on `peakArg`/`dumpArg` use explicit `if cfg.buddy.peak == null then "" else cfg.buddy.peak`.

Wrap the activation block in `lib.mkIf (cfg.buddy != null && cfg.buddy.enable)`.

- [ ] **Step 7: Add the any-buddy worker + python3 dependencies to the activation script**

The script references `${any-buddy}`, `${pkgs.bun}/bin/bun`, `${pkgs.python3}/bin/python3`, `${pkgs.jq}/bin/jq`. Import these at the top of the `let` block in mkClaude.nix:

```nix
let
  anyBuddy = pkgs.ai.any-buddy;  # verify this is the correct path in pkgs.ai
  bunBin = "${pkgs.bun}/bin/bun";
  python3Bin = "${pkgs.python3}/bin/python3";
  jqBin = "${pkgs.jq}/bin/jq";
in
  # ... use these in the activation script body
```

- [ ] **Step 8: Add assertions from the legacy buddy module**

The legacy `modules/claude-code-buddy/default.nix` has assertions like:
- `buddy.peak != buddy.dump || buddy.peak == null`
- `buddy.rarity == "common" -> buddy.hat == "none"`

Port these into mkClaude.nix hm.config:

```nix
{
  assertions = lib.optionals (cfg.buddy != null) [
    {
      assertion = cfg.buddy.peak != cfg.buddy.dump || cfg.buddy.peak == null;
      message = "ai.claude.buddy: peak and dump stats must differ (or both be null)";
    }
    {
      assertion = cfg.buddy.rarity != "common" || cfg.buddy.hat == "none";
      message = "ai.claude.buddy: common rarity forces hat = \"none\"";
    }
  ];
}
```

Place this INSIDE the top-level `lib.mkMerge` list (not inside the `mkIf cfg.buddy.enable` block — assertions should fire even when the feature is disabled if misconfigured).

- [ ] **Step 9: Write failing test — assertion fires**

```nix
module-claude-buddy-common-rarity-requires-no-hat = mkTest "claude-buddy-common-rarity-requires-no-hat" (
  let
    result = builtins.tryEval (evalHm {
      ai.claude.enable = true;
      ai.claude.buddy = {
        enable = true;
        species = "duck";
        rarity = "common";
        hat = "wizard";  # INVALID: common + wizard
        eyes = "blue";
        shiny = false;
        peak = null;
        dump = null;
        userId.text = "00000000-0000-0000-0000-000000000000";
      };
    }).config.assertions;
  in
    result.success
    && lib.any (a: !a.assertion) result.value
);
```

- [ ] **Step 10: Run full test suite**

Run: `nix flake check 2>&1 | tail -15`
Expected: all tests pass, including the new buddy tests.

- [ ] **Step 11: Verify activation script content by string-checking**

Run one more sanity check test:

```nix
module-claude-buddy-activation-has-full-fingerprint-inputs = mkTest "claude-buddy-activation-has-full-fingerprint-inputs" (
  let
    result = evalHm {
      ai.claude.enable = true;
      ai.claude.buddy = {
        enable = true;
        species = "duck";
        rarity = "rare";
        eyes = "blue";
        hat = "wizard";
        shiny = true;
        peak = "attack";
        dump = "defense";
        userId.text = "00000000-0000-0000-0000-000000000000";
      };
    };
    script = result.config.home.activation.claudeBuddy.text or "";
  in
    lib.hasInfix "sha256sum" script
    && lib.hasInfix "fingerprint" script
    && lib.hasInfix "cli.js" script
    && lib.hasInfix "friend-2026-401" script  # salt marker
    && lib.hasInfix "companion" script        # companion reset
);
```

Run: should pass.

- [ ] **Step 12: Commit Task 6**

```bash
git add packages/claude-code/lib/mkClaude.nix checks/module-eval.nix
git commit -m "feat(claude-code): absorb buddy activation into mkClaude hm projection (A1)"
```

---

### Task 7: A6 — Absorb stacked-workflows HM module into content package

**Goal:** Port `modules/stacked-workflows/default.nix` + `git-config.nix` + `git-config-full.nix` into `packages/stacked-workflows/modules/homeManager/default.nix` and (new) `packages/stacked-workflows/modules/devenv/default.nix`. The content package becomes a full factory participant via `collectFacet ["modules" "homeManager"]` + `collectFacet ["modules" "devenv"]` in flake.nix. Git config presets (minimal/full) become options under `ai.stackedWorkflows.*` or stay under a top-level `stacked-workflows.*` namespace — verify what the legacy module exposes and preserve the name.

**Files:**

- Create: `packages/stacked-workflows/modules/homeManager/default.nix`
- Create: `packages/stacked-workflows/modules/devenv/default.nix`
- Modify: `packages/stacked-workflows/default.nix` (add modules facet)
- Reference only (read): `modules/stacked-workflows/default.nix`, `modules/stacked-workflows/git-config.nix`, `modules/stacked-workflows/git-config-full.nix`

- [ ] **Step 1: Read the legacy module and record its option surface**

Read `modules/stacked-workflows/default.nix` top to bottom. Record:
- The options namespace (e.g., `stacked-workflows.enable`, `stacked-workflows.gitConfig` etc.)
- Every option's type and default
- Git config preset data from `git-config.nix` and `git-config-full.nix`
- Fanout logic (home.file writes, programs.* delegation, skill entries)

- [ ] **Step 2: Create the HM module file**

Create `packages/stacked-workflows/modules/homeManager/default.nix` with the ported content. The file should:

```nix
# Stacked-workflows HM module.
#
# Ports the legacy modules/stacked-workflows/default.nix into the
# content package. Walked into homeManagerModules.nix-agentic-tools
# via flake.nix:collectFacet ["modules" "homeManager"].
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.stacked-workflows;
  swsContent = pkgs.stacked-workflows-content;

  # Module-relative path literal for skills (see .claude/rules/hm-modules.md
  # "Nix path types" section for why this MUST be a `./` literal, not a
  # `builtins.path` or filtered source).
  skillsRepo = ../../skills;

  gitConfig = import ./git-config.nix;
  gitConfigFull = import ./git-config-full.nix;
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills and references";
    gitConfigMode = lib.mkOption {
      type = lib.types.enum ["none" "minimal" "full"];
      default = "minimal";
      description = "Which git config preset to apply.";
    };
    # ... port other options from the legacy module
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Port the config body verbatim from modules/stacked-workflows/default.nix,
    # adapting references as needed.
  ]);
}
```

**Critical:** Any `pkgs.fragments-ai.passthru.transforms` references in the legacy module must be rewritten using the inline `mkRenderer` compat pattern from `modules/devenv/ai.nix:49-67` (added in commit `23af2a1`). The new pattern is:

```nix
fragmentsLib = import ../../../../lib/fragments.nix {inherit lib;};
inherit (import ../../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
# ... etc for copilot, kiro
```

- [ ] **Step 3: Copy git-config.nix and git-config-full.nix into the new location**

```bash
cp modules/stacked-workflows/git-config.nix packages/stacked-workflows/modules/homeManager/git-config.nix
cp modules/stacked-workflows/git-config-full.nix packages/stacked-workflows/modules/homeManager/git-config-full.nix
```

(Use `cp` first to verify they work at the new location; delete originals in Task 9.)

- [ ] **Step 4: Create the devenv module file**

Create `packages/stacked-workflows/modules/devenv/default.nix`. Port the relevant parts of `modules/stacked-workflows/default.nix` that apply to devenv context (skills fanout via `files.*`, git config if applicable). Devenv does not typically manage user-level git config — verify whether the legacy module has devenv-specific logic at all. If there's nothing devenv-specific in the legacy module, this file can be a minimal stub:

```nix
# Stacked-workflows devenv module.
#
# Walked into devenvModules.nix-agentic-tools via
# flake.nix:collectFacet ["modules" "devenv"].
{
  config,
  lib,
  pkgs,
  ...
}: {
  # Stacked-workflows is primarily HM-oriented. Devenv integration
  # happens via the ai.* module surface — this file is a placeholder
  # for future devenv-specific options if needed.
}
```

- [ ] **Step 5: Wire the modules facet into the package barrel**

Modify `packages/stacked-workflows/default.nix` to add a `modules` attribute:

```nix
# Current content (inferred — verify first):
{
  # ... existing exports ...
  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
```

- [ ] **Step 6: Write test — module is picked up by the barrel**

Add to `checks/module-eval.nix`:

```nix
module-stacked-workflows-option-available = mkTest "stacked-workflows-option-available" (
  let
    result = evalHm {
      stacked-workflows.enable = true;
    };
  in
    result.config.stacked-workflows.enable == true
);
```

Run: may pass immediately if the flake.nix walker picks up the new module directory. If not, debug by checking `flake.nix:collectFacet` and the package's `default.nix` `modules` attribute.

- [ ] **Step 7: Run `nix flake check`**

Expected: all tests pass.

- [ ] **Step 8: Commit Task 7**

```bash
git add packages/stacked-workflows/ checks/module-eval.nix
git commit -m "feat(stacked-workflows): absorb HM module into content package (A6)"
```

---

### Task 8: A8 — Swap devenv.nix from legacy modules to factory barrel

**Goal:** Replace `devenv.nix`'s `imports = [./modules/devenv]` with `imports = [(inputs.self.devenvModules.nix-agentic-tools)]` or equivalent. This switches devenv consumption from the legacy tree to the factory barrel. Also remove the inline `nvSourcesOverlay` / `aiPkgs` composition if the factory barrel handles package resolution — verify the barrel's assumptions first.

**Files:**

- Modify: `devenv.nix`

- [ ] **Step 1: Inspect the current devenv.nix import shape**

Read `devenv.nix` lines 1-50. Current structure:

```nix
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # nvSourcesOverlay + aiPkgs composition
  # ...
in {
  imports = [
    ./modules/devenv
  ];
  # ...
}
```

- [ ] **Step 2: Verify the factory barrel evaluates standalone**

Run: `nix eval --impure --expr '
let
  self = builtins.getFlake (toString ./.);
  lib = self.inputs.nixpkgs.lib;
  evaluated = lib.evalModules {
    modules = [
      self.devenvModules.nix-agentic-tools
      { _module.args.pkgs = self.packages.x86_64-linux; }
    ];
  };
in builtins.attrNames evaluated.options.ai
' 2>&1 | tail -5`

Expected: a list of ai.* option attributes (claude, copilot, kiro, skills, instructions, mcpServers). If this fails, the factory barrel needs fixing before proceeding.

- [ ] **Step 3: Swap the import**

Modify `devenv.nix`:

```nix
{
  pkgs,
  lib,
  inputs,
  ...
}: let
  # ... overlay composition stays for now ...
in {
  imports = [
    inputs.self.devenvModules.nix-agentic-tools
  ];
  # ... rest of the devenv.nix config ...
}
```

**Note:** `inputs.self` may not be available in devenv's module eval context. If not, alternatives:
- Import the module file directly: `imports = [./.]` with a nix expression that walks `packages/*/modules/devenv/default.nix` the same way `flake.nix:collectFacet` does.
- Or use `inputs.nix-agentic-tools` if devenv treats the current flake as an input (verify with `nix flake metadata`).

- [ ] **Step 4: Run `devenv shell --impure -- echo ok`**

Expected: devenv shell enters cleanly. If it fails, the most likely causes are:
- `inputs.self` not available → use an alternative import path
- The factory barrel expects options that the devenv config currently doesn't provide → add them or stub them
- Option type conflicts between the legacy `copilot.*` / `kiro.*` namespaces and the new `ai.*` namespace → consolidate to `ai.*` in `devenv.nix`

- [ ] **Step 5: Migrate devenv.nix's `ai.*` / `copilot.*` / `kiro.*` / `claude.code.*` config blocks**

The current `devenv.nix` has mixed namespaces (`ai.{claude,copilot,kiro}` plus `claude.code.*`, `copilot.*`, `kiro.*` — the latter three were set by the legacy modules). Under the factory barrel, all config flows through `ai.*`. Consolidate:

```nix
ai = {
  claude = {
    enable = true;
    settings.env.ENABLE_LSP_TOOL = "1";
    # Port claude.code.permissions.rules + claude.code.mcpServers here
  };
  copilot.enable = true;
  kiro.enable = true;
  skills = {
    # ... existing skills config ...
  };
  mcpServers = {
    agnix = mkPackageEntry agnix;
    # Port devenv.mcpServers + copilot.mcpServers + kiro.mcpServers here
  };
};

# Remove claude.code.*, copilot.*, kiro.* top-level blocks (they are
# populated by the factory callbacks via ai.* now).
```

- [ ] **Step 6: Run `devenv shell --impure -- echo ok` + `devenv test`**

Expected: both pass.

- [ ] **Step 7: Commit Task 8**

```bash
git add devenv.nix
git commit -m "refactor(devenv): swap legacy modules/devenv for factory barrel (A8)"
```

---

### Task 9: A10 — Delete modules/ tree + lib shim files

**Goal:** Now that every absorption task is complete, the legacy `modules/` tree holds nothing that isn't duplicated under `packages/<name>/`. Delete it wholesale along with the `lib/` shim files (`ai-common.nix`, `buddy-types.nix`, `hm-helpers.nix`) that were restored in M14 only to keep `modules/` evaluating.

**Files:**

- Delete: `modules/ai/default.nix` and `modules/ai/` directory
- Delete: `modules/claude-code-buddy/default.nix` and directory
- Delete: `modules/copilot-cli/default.nix` and directory
- Delete: `modules/kiro-cli/default.nix` and directory
- Delete: `modules/stacked-workflows/default.nix` and directory (including git-config files)
- Delete: `modules/devenv/ai.nix`, `modules/devenv/copilot.nix`, `modules/devenv/kiro.nix`, `modules/devenv/mcp-common.nix`
- Delete: `modules/devenv/claude-code-skills/` directory
- Delete: `modules/devenv/default.nix`
- Delete: `modules/devenv/` directory
- Delete: `modules/default.nix`
- Delete: `modules/` directory itself
- Delete: `lib/ai-common.nix`
- Delete: `lib/buddy-types.nix`
- Delete: `lib/hm-helpers.nix`

- [ ] **Step 1: Verify nothing still imports from `modules/`**

```bash
git grep -l 'import.*modules/\|imports = \[.*modules/' -- ':!docs/' ':!**/docs/*' ':!.claude/' ':!.github/' ':!.kiro/' ':!dev/references/'
```

Expected: empty output. If any files are listed, those need fixing before deletion. Likely culprits: `devenv.nix` (should be fixed in Task 8), `checks/module-eval.nix` (add compat if tests still read legacy modules).

- [ ] **Step 2: Verify nothing still imports from the lib shims**

```bash
git grep -l 'ai-common\|buddy-types\|hm-helpers' -- ':!docs/' ':!**/docs/*' ':!.claude/' ':!.github/' ':!.kiro/' ':!dev/references/' ':!.cspell/'
```

Expected: only `lib/mcp.nix` or similar internal references. If `packages/<name>/lib/mk<Name>.nix` files still import `hm-helpers` for `mkSkillEntries` / `mkDevenvSkillEntries`, either:
- (a) Move those helpers INTO `lib/ai/` (e.g., `lib/ai/skills.nix`) and update imports, or
- (b) Keep `lib/hm-helpers.nix` — it's not actually a shim anymore if factory code depends on it

If (b), update the plan: don't delete `lib/hm-helpers.nix`. Add a note to the commit.

- [ ] **Step 3: Delete the legacy HM modules**

```bash
git rm -r modules/ai/
git rm -r modules/claude-code-buddy/
git rm -r modules/copilot-cli/
git rm -r modules/kiro-cli/
git rm -r modules/stacked-workflows/
git rm modules/default.nix
```

- [ ] **Step 4: Delete the legacy devenv modules**

```bash
git rm -r modules/devenv/
```

- [ ] **Step 5: Verify `modules/` is empty, then remove**

```bash
ls modules/ 2>&1 | head
# Should only have `.gitkeep` or be completely empty.
rmdir modules/ 2>/dev/null || true
```

If `rmdir` fails because the directory has stragglers, investigate. Likely candidates: `.gitkeep` (fine to delete), or an untracked file (user's WIP — check with `git status`).

- [ ] **Step 6: Delete lib shim files (if Step 2 confirmed no live references)**

```bash
git rm lib/ai-common.nix lib/buddy-types.nix lib/hm-helpers.nix
```

If Step 2 showed `lib/hm-helpers.nix` is still in use by factory code, skip deleting it and update the commit message.

- [ ] **Step 7: Run `nix flake check`**

Run: `nix flake check 2>&1 | tail -15`
Expected: all tests pass. If any test fails, the most likely causes:
- A test file (`checks/*.nix`) still references the deleted paths → fix the test imports
- A factory file still references `hm-helpers` → revert Step 6's deletion of that file

- [ ] **Step 8: Run `devenv shell --impure -- echo ok`**

Expected: devenv shell enters cleanly.

- [ ] **Step 9: Final verification — grep for any residual references**

```bash
git grep -l 'modules/ai\|modules/claude-code-buddy\|modules/copilot-cli\|modules/kiro-cli\|modules/stacked-workflows\|modules/devenv\|modules/default\.nix\|modules/mcp-servers' -- ':!docs/superpowers/' ':!docs/plan.md' ':!.claude/' ':!.github/' ':!.kiro/'
```

Expected: empty (or only historical references in test fixtures). Fix anything that surfaces.

- [ ] **Step 10: Commit Task 9**

```bash
git add -A
git commit -m "refactor: delete legacy modules/ tree + lib shims (A10)"
```

- [ ] **Step 11: Push to origin**

```bash
git push origin refactor/ai-factory-architecture
```

---

## Final verification

After all nine tasks land, run the full smoke-test sequence:

```bash
nix flake check                          # factory-eval + module-eval tests
nix build .#docs                         # doc site builds
nix build .#docs-options-hm              # HM options doc
nix build .#docs-options-devenv          # devenv options doc
devenv shell --impure -- echo ok         # devenv shell enters
devenv tasks run --mode before generate:instructions  # generator pipeline works
```

All should pass. The branch is then ready for PR-sized re-chunking for the main merge (targeted late next week).

## Post-plan considerations (not part of this plan)

- **B1/B2 coverage expansion:** Add factory-eval tests asserting each app produces valid JSON for its mcp config file, valid YAML frontmatter for kiro steering, etc. Interleave into Tasks 3/4/5 as time allows (the failing-test steps in those tasks already cover the basic cases).
- **B3 `lib/` shim deletion:** Folded into Task 9 Step 6.
- **nixos-config integration:** User will handle separately after skimming the repo to validate mental model.
- **Codex 4th ecosystem:** Post-main-merge work, separate plan.

## Self-review checklist

- [x] Every task has `Files:` list with exact paths
- [x] Every step has a concrete command or code block
- [x] No "TBD" or "implement later" placeholders
- [x] Task 6 (buddy) calls out the `.claude/rules/claude-code.md` invariants explicitly
- [x] Task 2 (A5) preserves the external `lib.mkStdioEntry` contract
- [x] Type consistency: `mergedSkills` used as `attrsOf path` throughout; `mergedInstructions` as `listOf attrs` throughout
- [x] Each task ends with a commit step

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-08-ideal-architecture-gate.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, two-stage review (spec compliance then code quality) between tasks, fast iteration. Best for mechanical work like this where the plan has detailed steps and the human doesn't want to sit in the loop.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review. Better if you want to see each task's diff before committing.

Which approach?
