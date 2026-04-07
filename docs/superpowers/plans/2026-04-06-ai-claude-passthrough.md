# ai.claude.\* Full Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose every `programs.claude-code.*` option through `ai.claude.*` so consumers no longer need to drop down to the upstream HM module for common config (memory, skills, mcpServers, settings, plugins, marketplaces).

**Architecture:** Direct passthrough options on the `ai.claude` submodule mirroring upstream types 1:1. Fanout assigns `programs.claude-code.<opt> = cfg.claude.<opt>` inside the existing `mkIf cfg.claude.enable` block. Uses `mkMerge` for attrset options so consumer-set `programs.claude-code.*` stays composable with `ai.claude.*`. `settings` reuses `pkgs.formats.json {}` type from upstream to guarantee shape parity. A separate fix routes the existing `ai.skills` cross-ecosystem fanout through `programs.claude-code.skills` (instead of raw `home.file`) so per-Claude `ai.claude.skills` can merge with cross-ecosystem `ai.skills` cleanly.

**Tech Stack:** Nix module system, home-manager, `evalModules` checks, `pkgs.formats.json`, the existing `modules/ai/default.nix` fanout pattern.

**References:**

- Backlog item: `docs/plan.md:516-533` ("ai.claude.\* full passthrough") — high-level sketch, this plan operationalizes it
- Existing ai module: `modules/ai/default.nix` (fanout block at L218-249)
- Upstream HM claude-code: `modules/programs/claude-code.nix` in nix-community/home-manager (types source of truth; see L58-491 at lockfile-pinned rev)
- Existing buddy passthrough (reference pattern): `modules/claude-code-buddy/default.nix` + `modules/ai/default.nix:246-248`
- Consumer driving this: `nixos-config/home/caubut/features/cli/code/ai/default.nix:83-185` (memory/skills/mcpServers/settings currently all on `programs.claude-code.*` direct)

**Scope exclusions (deferred):**

- Plugin install activation script (`installClaudePlugins` in the consumer) — stays bespoke; passthrough just exposes `ai.claude.plugins`, not the marketplace-download wrapper
- Unified `ai.mcpServers` cross-ecosystem bridge — covered by a separate backlog item
- `programs.claude-code.hooks/commands/agents/rules/outputStyles` — not currently used by the consumer; add in a follow-up plan when demand arrives
- Copilot/Kiro analogous passthroughs — separate plans per ecosystem

---

## A. Preparation

### Task 1: Catalog upstream option shapes in a reference file

Record the exact upstream types so later tasks can copy them verbatim without re-checking the store.

**Files:**

- Create: `dev/references/claude-code-hm-options.md`

- [ ] **Step 1: Read upstream module**

Run:

```bash
HM_CC=$(nix eval --raw --impure --expr \
  'let hm = builtins.getFlake "github:nix-community/home-manager"; in "${hm}/modules/programs/claude-code.nix"')
grep -n "= mkOption\|= lib.mkOption" "$HM_CC"
```

Note the exact line numbers for: `settings` (L84), `plugins` (L140), `marketplaces` (L163), `memory.text` (L270), `memory.source` (L288), `skills` (L381), `skillsDir` (L416), `lspServers` (L425), `mcpServers` (L452), `enableMcpIntegration` (L70).

- [ ] **Step 2: Write reference file**

Create `dev/references/claude-code-hm-options.md`:

````markdown
# Upstream programs.claude-code option shapes

Reference for `ai.claude.*` passthrough. Types copied verbatim from
`home-manager/modules/programs/claude-code.nix` so fanout assignments
type-check without conversion.

## Settings (freeform JSON)

```nix
settings = mkOption {
  inherit (jsonFormat) type;  # pkgs.formats.json {}.type
  default = { };
  description = "JSON configuration for Claude Code settings.json";
};
```

Covers all consumer-set keys: `effortLevel`, `enableAllProjectMcpServers`,
`enabledPlugins`, `permissions.{allow,ask,deny,additionalDirectories,defaultMode,disableBypassPermissionsMode}`,
`model`, `hooks`, `statusLine`, `includeCoAuthoredBy`, `theme`.

## Memory

```nix
memory = {
  text = mkOption {
    type = lib.types.nullOr lib.types.lines;
    default = null;
  };
  source = mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
  };
};
```

Mutually exclusive (asserted upstream).

## mcpServers

```nix
mcpServers = mkOption {
  type = lib.types.attrsOf jsonFormat.type;
  default = { };
};
```

## enableMcpIntegration

```nix
enableMcpIntegration = mkOption {
  type = lib.types.bool;
  default = false;
};
```

Bridges `programs.mcp.servers` (separate HM module) into
`programs.claude-code.mcpServers`, with claude-code entries taking
precedence on key conflict.

## Skills (content option — str | path | directory)

```nix
skills = mkOption {
  type = attrsOf (either lines path);  # content option pattern
  default = { };
};
skillsDir = mkOption {
  type = nullOr path;
  default = null;
};
```

## Plugins

```nix
plugins = mkOption {
  type = with lib.types; listOf (either package path);
  default = [ ];
};
marketplaces = mkOption {
  type = with lib.types; attrsOf (either package path);
  default = { };
};
```
````

- [ ] **Step 3: Commit**

```bash
treefmt dev/references/claude-code-hm-options.md
git add dev/references/claude-code-hm-options.md
git commit -m "docs(references): catalog upstream programs.claude-code option shapes

Reference for the ai.claude.* passthrough work so later tasks can
copy upstream types verbatim without re-reading the store."
```

---

## B. `ai.skills` collision fix (prerequisite for per-Claude skills)

### Task 2: Route `ai.skills` fanout through `programs.claude-code.skills`

Today `ai.skills` writes `home.file.".claude/skills/<name>".source` directly (`modules/ai/default.nix:229-235`), bypassing `programs.claude-code.skills`. This creates a dead-end: `ai.claude.skills` would collide on the same `home.file` path, and consumers can't compose both. Routing the Claude fanout through `programs.claude-code.skills` consolidates to one source of truth.

**Files:**

- Modify: `modules/ai/default.nix:218-236`
- Modify: `checks/module-eval.nix` (add skill-fanout eval test)

- [ ] **Step 1: Write the failing eval check**

In `checks/module-eval.nix`, add before the closing `in {`:

```nix
  # Test: ai.skills fans out via programs.claude-code.skills (not home.file directly)
  aiSkillsFanout = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          claude.enable = true;
          skills.stack-fix = /tmp/test-skill;
        };
      };
    }
  ];
```

And in the output attrset:

```nix
  ai-skills-fanout-eval = pkgs.runCommand "ai-skills-fanout-eval" {} ''
    echo "ai.skills routed via programs.claude-code.skills: ${
      if aiSkillsFanout.config.programs.claude-code.skills ? stack-fix
      then "yes"
      else "no (still on home.file)"
    }" > $out
    if [ "${
      if aiSkillsFanout.config.programs.claude-code.skills ? stack-fix
      then "yes"
      else "no"
    }" != "yes" ]; then
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-skills-fanout-eval 2>&1 | tee /tmp/fanout-fail.log
```

Expected: build fails with "no (still on home.file)" — the new check detects today's behavior and rejects it.

- [ ] **Step 3: Rewrite the Claude skills fanout**

In `modules/ai/default.nix`, replace L218-236 (the current `(mkIf cfg.claude.enable (mkMerge [{ ... home.file = ... }]))` block) with:

```nix
    (mkIf cfg.claude.enable (mkMerge [
      {
        programs.claude-code = {
          enable = mkDefault true;
          # Cross-ecosystem skills → programs.claude-code.skills at mkDefault
          # so per-Claude ai.claude.skills (set later) can override per key.
          skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        };
        home.file =
          # Instructions as Claude rules with frontmatter
          concatMapAttrs (name: instr: {
            ".claude/rules/${name}.md" = {
              text = mkDefault (aiTransforms.claude {package = name;} instr);
            };
          })
          cfg.instructions;
      }
      # Auto-set ENABLE_LSP_TOOL=1 when LSP servers are configured
      (mkIf (cfg.lspServers != {} && hasModule ["programs" "claude-code" "settings"]) {
        programs.claude-code.settings.env.ENABLE_LSP_TOOL = mkDefault "1";
      })
      # Normalized model setting (only if upstream module is available)
      (mkIf (cfg.settings.model != null && hasModule ["programs" "claude-code" "settings"]) {
        programs.claude-code.settings.model = mkDefault cfg.settings.model;
      })
      # Buddy fanout — sets the canonical programs.claude-code.buddy
      (mkIf (cfg.claude.buddy != null) {
        programs.claude-code.buddy = cfg.claude.buddy;
      })
    ]))
```

Key change: the `.claude/skills/${name}` home.file block is gone. `programs.claude-code.skills` handles it (upstream writes to `.claude/skills/<name>/SKILL.md` or a directory tree, depending on whether the value is a string or path — compatible with the existing `ai.skills` `attrsOf path` type).

- [ ] **Step 4: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-skills-fanout-eval
```

Expected: succeeds. Output file contains `yes`.

- [ ] **Step 5: Run full flake check**

```bash
nix flake check
```

Expected: all checks pass. No regressions in `ai-eval`, `ai-with-clis-eval`, `ai-buddy-eval`, `ai-with-settings-eval`.

- [ ] **Step 6: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "refactor(ai): route ai.skills through programs.claude-code.skills

ai.skills was writing home.file.\".claude/skills/<name>\" directly,
bypassing programs.claude-code.skills and making per-Claude
ai.claude.skills impossible without a home.file collision. Route
the Claude fanout through the upstream option so there's one
source of truth for .claude/skills/*."
```

---

## C. ai.claude.\* passthrough options

### Task 3: Add `ai.claude.memory` passthrough

**Files:**

- Modify: `modules/ai/default.nix` (options block L57-114, fanout block L218-249)
- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Write the failing eval check**

In `checks/module-eval.nix`, add:

```nix
  # Test: ai.claude.memory fans out to programs.claude-code.memory
  aiClaudeMemory = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai.claude = {
          enable = true;
          memory.text = "# Test memory\nInline text.";
        };
      };
    }
  ];
```

```nix
  ai-claude-memory-eval = pkgs.runCommand "ai-claude-memory-eval" {} ''
    result="${aiClaudeMemory.config.programs.claude-code.memory.text or "null"}"
    if [ "$result" = "# Test memory
Inline text." ]; then
      echo "ai.claude.memory.text fanout: ok" > $out
    else
      echo "ai.claude.memory.text fanout: FAIL (got: $result)"
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-claude-memory-eval 2>&1 | tee /tmp/memory-fail.log
```

Expected: fails with "option `ai.claude.memory` does not exist".

- [ ] **Step 3: Add the option**

In `modules/ai/default.nix`, inside the `ai.claude` submodule options (L60-79), add after `buddy`:

```nix
          memory = mkOption {
            type = types.submodule {
              options = {
                text = mkOption {
                  type = types.nullOr types.lines;
                  default = null;
                  description = ''
                    Inline memory content for CLAUDE.md. Mutually exclusive
                    with memory.source. Mirrors programs.claude-code.memory.text.
                  '';
                };
                source = mkOption {
                  type = types.nullOr types.path;
                  default = null;
                  description = ''
                    Path to a file containing CLAUDE.md content. Mutually
                    exclusive with memory.text. Mirrors
                    programs.claude-code.memory.source.
                  '';
                };
              };
            };
            default = {};
            description = "Claude Code memory (CLAUDE.md) — fans out to programs.claude-code.memory.";
          };
```

- [ ] **Step 4: Add the fanout**

In `modules/ai/default.nix`, inside the Claude `mkMerge` block (after the buddy fanout at the end of the block added in Task 2), add:

```nix
      # Memory passthrough — fan out to programs.claude-code.memory.
      # Upstream already asserts text/source mutual exclusion.
      (mkIf (cfg.claude.memory.text != null) {
        programs.claude-code.memory.text = mkDefault cfg.claude.memory.text;
      })
      (mkIf (cfg.claude.memory.source != null) {
        programs.claude-code.memory.source = mkDefault cfg.claude.memory.source;
      })
```

- [ ] **Step 5: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-claude-memory-eval
nix flake check
```

Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "feat(ai): add ai.claude.memory passthrough

Mirrors programs.claude-code.memory.{text,source}. Fans out with
mkDefault so consumer-set programs.claude-code.memory wins. No
mutual-exclusion assertion needed — upstream handles it."
```

---

### Task 4: Add `ai.claude.settings` passthrough (freeform JSON)

**Files:**

- Modify: `modules/ai/default.nix`
- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Write the failing eval check**

In `checks/module-eval.nix`:

```nix
  # Test: ai.claude.settings merges into programs.claude-code.settings
  aiClaudeSettings = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai.claude = {
          enable = true;
          settings = {
            effortLevel = "high";
            enableAllProjectMcpServers = true;
            permissions.allow = ["Bash(git status *)"];
          };
        };
      };
    }
  ];
```

```nix
  ai-claude-settings-eval = pkgs.runCommand "ai-claude-settings-eval" {} ''
    effort="${aiClaudeSettings.config.programs.claude-code.settings.effortLevel or "missing"}"
    mcp="${
      if aiClaudeSettings.config.programs.claude-code.settings.enableAllProjectMcpServers or false
      then "true"
      else "false"
    }"
    if [ "$effort" = "high" ] && [ "$mcp" = "true" ]; then
      echo "ai.claude.settings fanout: ok" > $out
    else
      echo "ai.claude.settings fanout: FAIL (effort=$effort mcp=$mcp)"
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-claude-settings-eval 2>&1 | tee /tmp/settings-fail.log
```

Expected: fails with "option `ai.claude.settings` does not exist" (note: `ai.settings` at the top level exists but is a different thing — the normalized `model`/`telemetry` submodule at L156-173).

- [ ] **Step 3: Rename the existing top-level `ai.settings` to avoid option-name collision**

The existing `ai.settings` (L156-173, with `model` and `telemetry` submodule) is a _cross-ecosystem normalized_ surface; `ai.claude.settings` is a Claude-specific freeform passthrough. They're not the same concept — adding `ai.claude.settings` as a sibling inside the existing `ai.claude` submodule doesn't collide with top-level `ai.settings`. No rename needed; these live in different scopes (`ai.settings` vs `ai.claude.settings`).

Verify by reading the existing module (this step is a read-only confirmation; if the module has changed, adjust Step 4 accordingly):

```bash
grep -n "settings = mkOption" modules/ai/default.nix
# Expect exactly one match at the top-level ai.settings (~L156).
```

- [ ] **Step 4: Add the option**

At the top of `modules/ai/default.nix`, add the jsonFormat binding to the `let` block (after the `aiTransforms` line ~L47):

```nix
  jsonFormat = pkgs.formats.json {};
```

Then inside the `ai.claude` submodule options (after `memory` from Task 3), add:

```nix
          settings = mkOption {
            inherit (jsonFormat) type;
            default = {};
            description = ''
              Freeform settings.json passthrough. Fans out to
              programs.claude-code.settings via mkMerge so consumer-set
              programs.claude-code.settings stays composable. Mirrors
              upstream programs.claude-code.settings shape 1:1.
            '';
            example = lib.literalExpression ''
              {
                effortLevel = "high";
                enableAllProjectMcpServers = true;
                permissions.allow = ["Bash(git *)"];
              }
            '';
          };
```

- [ ] **Step 5: Add the fanout**

Inside the Claude `mkMerge` block, add after the memory fanout:

```nix
      # Settings passthrough — freeform JSON, merged via mkMerge so
      # consumer-set programs.claude-code.settings stays composable.
      (mkIf (cfg.claude.settings != {}) {
        programs.claude-code.settings = cfg.claude.settings;
      })
```

Note: no `mkDefault` wrapper on the assignment itself — `mkMerge` of attrsets combines by default, letting consumer-set keys on `programs.claude-code.settings` coexist. If you need to give consumer keys priority over ai.claude keys, wrap individual values in `mkDefault` at the call site.

- [ ] **Step 6: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-claude-settings-eval
nix flake check
```

Expected: both pass. The `ai-with-settings-eval` check (which uses top-level `ai.settings.model`) should also still pass — different scope.

- [ ] **Step 7: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "feat(ai): add ai.claude.settings freeform passthrough

Exposes upstream programs.claude-code.settings as ai.claude.settings
using the same pkgs.formats.json type. Covers effortLevel,
permissions, enabledPlugins, enableAllProjectMcpServers, theme,
hooks, statusLine, and any other settings.json key. Fanout uses
mkMerge so consumer-set programs.claude-code.settings stays
composable."
```

---

### Task 5: Add `ai.claude.mcpServers` + `ai.claude.enableMcpIntegration` passthrough

**Files:**

- Modify: `modules/ai/default.nix`
- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Write the failing eval check**

```nix
  # Test: ai.claude.mcpServers + enableMcpIntegration fan out
  aiClaudeMcp = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai.claude = {
          enable = true;
          enableMcpIntegration = true;
          mcpServers.test-server = {
            type = "stdio";
            command = "true";
            args = [];
          };
        };
      };
    }
  ];
```

```nix
  ai-claude-mcp-eval = pkgs.runCommand "ai-claude-mcp-eval" {} ''
    integration="${
      if aiClaudeMcp.config.programs.claude-code.enableMcpIntegration or false
      then "true"
      else "false"
    }"
    srv="${aiClaudeMcp.config.programs.claude-code.mcpServers.test-server.command or "missing"}"
    if [ "$integration" = "true" ] && [ "$srv" = "true" ]; then
      echo "ai.claude.mcpServers fanout: ok" > $out
    else
      echo "ai.claude.mcpServers fanout: FAIL (integration=$integration srv=$srv)"
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-claude-mcp-eval 2>&1 | tee /tmp/mcp-fail.log
```

Expected: fails with "option `ai.claude.mcpServers` does not exist".

- [ ] **Step 3: Add the options**

In the `ai.claude` submodule options, after `settings`:

```nix
          enableMcpIntegration = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Bridge programs.mcp.servers (separate upstream HM module) into
              programs.claude-code.mcpServers. Mirrors
              programs.claude-code.enableMcpIntegration. claude-code entries
              take precedence on key conflict.
            '';
          };

          mcpServers = mkOption {
            type = types.attrsOf jsonFormat.type;
            default = {};
            description = ''
              Claude-specific MCP server entries. Fans out to
              programs.claude-code.mcpServers via mkMerge. Use with
              lib.mkStdioEntry / lib.mkHttpEntry / lib.externalServers from
              this flake, or services.mcp-servers.mcpConfig.mcpServers.
            '';
            example = lib.literalExpression ''
              {
                git-mcp = {
                  type = "stdio";
                  command = "git-mcp";
                  args = [];
                };
              }
            '';
          };
```

- [ ] **Step 4: Add the fanout**

Inside the Claude `mkMerge` block, after the settings fanout:

```nix
      # MCP passthrough — fan out mcpServers attrs and enableMcpIntegration.
      (mkIf (cfg.claude.mcpServers != {}) {
        programs.claude-code.mcpServers = cfg.claude.mcpServers;
      })
      (mkIf cfg.claude.enableMcpIntegration {
        programs.claude-code.enableMcpIntegration = mkDefault true;
      })
```

- [ ] **Step 5: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-claude-mcp-eval
nix flake check
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "feat(ai): add ai.claude.mcpServers + enableMcpIntegration

Exposes programs.claude-code.mcpServers as ai.claude.mcpServers
(attrsOf jsonFormat) and programs.claude-code.enableMcpIntegration
as ai.claude.enableMcpIntegration. Consumers can now use
lib.mkStdioEntry / lib.externalServers and
services.mcp-servers.mcpConfig.mcpServers via ai.claude without
dropping to programs.claude-code."
```

---

### Task 6: Add `ai.claude.skills` (per-Claude skills layer)

Adds Claude-specific skills that merge with cross-ecosystem `ai.skills`. Depends on Task 2 (which routed `ai.skills` fanout through `programs.claude-code.skills`).

**Files:**

- Modify: `modules/ai/default.nix`
- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Write the failing eval check**

```nix
  # Test: ai.claude.skills merges with ai.skills in programs.claude-code.skills
  aiClaudeSkillsMerge = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          claude = {
            enable = true;
            skills.gh-repo-settings = /tmp/claude-only-skill;
          };
          skills.stack-fix = /tmp/shared-skill;
        };
      };
    }
  ];
```

```nix
  ai-claude-skills-merge-eval = pkgs.runCommand "ai-claude-skills-merge-eval" {} ''
    shared="${
      if aiClaudeSkillsMerge.config.programs.claude-code.skills ? stack-fix
      then "yes"
      else "no"
    }"
    claudeOnly="${
      if aiClaudeSkillsMerge.config.programs.claude-code.skills ? gh-repo-settings
      then "yes"
      else "no"
    }"
    if [ "$shared" = "yes" ] && [ "$claudeOnly" = "yes" ]; then
      echo "ai.claude.skills + ai.skills merge: ok" > $out
    else
      echo "merge FAIL (shared=$shared claudeOnly=$claudeOnly)"
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-claude-skills-merge-eval 2>&1 | tee /tmp/skills-merge-fail.log
```

Expected: fails with "option `ai.claude.skills` does not exist".

- [ ] **Step 3: Add the option**

In the `ai.claude` submodule options, after `mcpServers`:

```nix
          skills = mkOption {
            type = types.attrsOf types.path;
            default = {};
            description = ''
              Claude-specific skills. Merged with cross-ecosystem ai.skills
              when both are set for the same key (Claude-specific wins
              because it's more specific). Fans out to
              programs.claude-code.skills.
            '';
          };
```

- [ ] **Step 4: Add the fanout**

Inside the Claude `mkMerge` block, alongside the existing `ai.skills` assignment (from Task 2), change the Claude `programs.claude-code.skills` fanout to merge both:

```nix
        programs.claude-code = {
          enable = mkDefault true;
          # Merge cross-ecosystem (ai.skills) with Claude-specific
          # (ai.claude.skills). Claude-specific wins on key conflict
          # because it's assigned without mkDefault.
          skills =
            (lib.mapAttrs (_: mkDefault) cfg.skills)
            // cfg.claude.skills;
        };
```

- [ ] **Step 5: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-claude-skills-merge-eval
nix build .#checks.x86_64-linux.ai-skills-fanout-eval  # from Task 2
nix flake check
```

Expected: all pass. The Task 2 check continues to pass because `ai.skills` still populates `programs.claude-code.skills`.

- [ ] **Step 6: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "feat(ai): add ai.claude.skills per-Claude skills layer

Complements cross-ecosystem ai.skills. Merges into
programs.claude-code.skills with Claude-specific entries winning
on key conflict. Lets consumers scope skills to Claude only
without touching other ecosystems."
```

---

### Task 7: Add `ai.claude.plugins` + `ai.claude.marketplaces` passthrough

Exposes upstream's plugin path list. Does NOT solve the marketplace-download activation script (that stays bespoke in consumer code). This just lets consumers pass static plugin paths / packages through ai.claude.

**Files:**

- Modify: `modules/ai/default.nix`
- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Write the failing eval check**

```nix
  # Test: ai.claude.plugins + marketplaces fan out
  aiClaudePlugins = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai.claude = {
          enable = true;
          plugins = [/tmp/test-plugin];
          marketplaces.test = /tmp/test-marketplace;
        };
      };
    }
  ];
```

```nix
  ai-claude-plugins-eval = pkgs.runCommand "ai-claude-plugins-eval" {} ''
    pluginCount="${toString (builtins.length aiClaudePlugins.config.programs.claude-code.plugins)}"
    hasMarketplace="${
      if aiClaudePlugins.config.programs.claude-code.marketplaces ? test
      then "yes"
      else "no"
    }"
    if [ "$pluginCount" = "1" ] && [ "$hasMarketplace" = "yes" ]; then
      echo "ai.claude.plugins + marketplaces fanout: ok" > $out
    else
      echo "FAIL (plugins=$pluginCount marketplace=$hasMarketplace)"
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check and verify failure**

```bash
nix build .#checks.x86_64-linux.ai-claude-plugins-eval 2>&1 | tee /tmp/plugins-fail.log
```

Expected: fails with "option `ai.claude.plugins` does not exist".

- [ ] **Step 3: Add the options**

In the `ai.claude` submodule options, after `skills`:

```nix
          plugins = mkOption {
            type = with types; listOf (either package path);
            default = [];
            description = ''
              Plugin packages or directory paths passed to Claude Code via
              --plugin-dir. Fans out to programs.claude-code.plugins.
              Mirrors upstream type exactly.
            '';
          };

          marketplaces = mkOption {
            type = with types; attrsOf (either package path);
            default = {};
            description = ''
              Custom plugin marketplaces. Key becomes the marketplace
              name; value is a package or directory path. Fans out to
              programs.claude-code.marketplaces.
            '';
          };
```

- [ ] **Step 4: Add the fanout**

Inside the Claude `mkMerge` block, after the skills block:

```nix
      (mkIf (cfg.claude.plugins != []) {
        programs.claude-code.plugins = cfg.claude.plugins;
      })
      (mkIf (cfg.claude.marketplaces != {}) {
        programs.claude-code.marketplaces = cfg.claude.marketplaces;
      })
```

- [ ] **Step 5: Run the check and verify pass**

```bash
nix build .#checks.x86_64-linux.ai-claude-plugins-eval
nix flake check
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "feat(ai): add ai.claude.plugins + marketplaces passthrough

Mirrors programs.claude-code.plugins (list of package|path) and
marketplaces (attrsOf package|path). Does not cover the bespoke
marketplace-download activation script — consumers keep that on
home.activation directly for now."
```

---

## D. Integration verification

### Task 8: Add integration eval that mirrors the nixos-config consumer shape

Proves all the new passthroughs work together with a realistic config matching `nixos-config/home/caubut/features/cli/code/ai/default.nix`.

**Files:**

- Modify: `checks/module-eval.nix`

- [ ] **Step 1: Add the composite eval**

In `checks/module-eval.nix`, add:

```nix
  # Integration: realistic consumer shape using all ai.claude.* passthroughs.
  # Mirrors nixos-config/home/caubut/features/cli/code/ai/default.nix.
  aiClaudeFullConsumer = evalModule [
    self.homeManagerModules.default
    {
      config = {
        ai = {
          skills.stack-fix = /tmp/stack-fix;
          claude = {
            enable = true;
            buddy = {
              userId.text = "test-00000000-0000-0000-0000-000000000000";
              species = "robot";
              rarity = "legendary";
              hat = "wizard";
              eyes = "eye";
              peak = "SNARK";
              dump = "PATIENCE";
              shiny = true;
            };
            memory.text = "# Global instructions\nTest.";
            skills.gh-repo-settings = /tmp/gh-repo;
            mcpServers.test-stdio = {
              type = "stdio";
              command = "true";
              args = [];
            };
            enableMcpIntegration = true;
            settings = {
              effortLevel = "high";
              enableAllProjectMcpServers = true;
              permissions.allow = ["Bash(git *)"];
            };
          };
        };
      };
    }
  ];
```

```nix
  ai-claude-full-consumer-eval = pkgs.runCommand "ai-claude-full-consumer-eval" {} ''
    cc=aiClaudeFullConsumer.config.programs.claude-code
    ok=1
    check() {
      if [ "$1" != "$2" ]; then
        echo "  MISMATCH $3: expected=$2 got=$1"
        ok=0
      fi
    }
    check "${
      if aiClaudeFullConsumer.config.programs.claude-code.enable
      then "true"
      else "false"
    }" "true" "enable"
    check "${aiClaudeFullConsumer.config.programs.claude-code.memory.text or "null"}" "# Global instructions
Test." "memory.text"
    check "${aiClaudeFullConsumer.config.programs.claude-code.settings.effortLevel or "null"}" "high" "settings.effortLevel"
    check "${
      if aiClaudeFullConsumer.config.programs.claude-code.skills ? stack-fix
      then "yes"
      else "no"
    }" "yes" "skills.stack-fix (from ai.skills)"
    check "${
      if aiClaudeFullConsumer.config.programs.claude-code.skills ? gh-repo-settings
      then "yes"
      else "no"
    }" "yes" "skills.gh-repo-settings (from ai.claude.skills)"
    check "${
      if aiClaudeFullConsumer.config.programs.claude-code.mcpServers ? test-stdio
      then "yes"
      else "no"
    }" "yes" "mcpServers.test-stdio"
    check "${
      if aiClaudeFullConsumer.config.programs.claude-code.enableMcpIntegration or false
      then "true"
      else "false"
    }" "true" "enableMcpIntegration"
    if [ "$ok" = "1" ]; then
      echo "full consumer fanout: all ok" > $out
    else
      exit 1
    fi
  '';
```

- [ ] **Step 2: Run the check**

```bash
nix build .#checks.x86_64-linux.ai-claude-full-consumer-eval
nix flake check
```

Expected: passes. Flake check should still succeed across all existing `ai-*-eval` checks.

- [ ] **Step 3: Commit**

```bash
treefmt checks/module-eval.nix
git add checks/module-eval.nix
git commit -m "test(ai): add realistic full-consumer eval for ai.claude.*

Mirrors the nixos-config consumer config shape and verifies all
six passthroughs (memory, skills, ai.skills merge, mcpServers,
enableMcpIntegration, settings) compose together."
```

---

## E. Documentation updates

### Task 9: Update backlog and generated docs

**Files:**

- Modify: `docs/plan.md:516-533` (mark the backlog item resolved)
- Regenerate: `dev/fragments/` / `docs/src/` via `devenv tasks run generate:all`

- [ ] **Step 1: Update the backlog entry**

In `docs/plan.md`, edit the `ai.claude.* full passthrough` bullet (L516) to:

```markdown
- [x] **ai.claude.\* full passthrough** — RESOLVED 2026-04-06 (see
      `docs/superpowers/plans/2026-04-06-ai-claude-passthrough.md`).
      Added `ai.claude.{memory,skills,mcpServers,enableMcpIntegration,settings,plugins,marketplaces}`
      as direct passthroughs mirroring upstream
      `programs.claude-code.*` types 1:1. The bespoke
      marketplace-download activation script (`installClaudePlugins`
      in consumer code) is intentionally not covered — static plugin
      paths / packages via `ai.claude.plugins` are, but marketplace
      fetching stays in consumer `home.activation.*`.
```

- [ ] **Step 2: Regenerate docs if they reference ai.claude options**

```bash
devenv tasks run generate:all
git status  # review any regenerated files under docs/src/, dev/fragments/
```

- [ ] **Step 3: Commit**

```bash
treefmt docs/plan.md
git add docs/plan.md
# plus any regenerated doc files if present
git commit -m "docs(plan): mark ai.claude.* passthrough resolved

Points at the implementation plan for detail. The upstream option
set is now fully mirrored on ai.claude.* for memory, settings,
skills, mcpServers, enableMcpIntegration, plugins, marketplaces.
Activation-script plugin fetching remains consumer-side."
```

---

## F. Downstream handoff

### Task 10: Notify nixos-config migration prompt of new capabilities

Once this plan lands, the `nixos-config` migration prompt (the one covering `nix-mcp-servers → nix-agentic-tools`) can be extended with a follow-up step migrating the `programs.claude-code.*` direct config to `ai.claude.*`. That migration is NOT part of this plan — it's consumer-side. But leave a breadcrumb.

**Files:**

- Modify: `docs/plan.md` — add a new checkbox under the relevant backlog section referencing the follow-up consumer work.

- [ ] **Step 1: Add breadcrumb**

In `docs/plan.md`, find the section about consumer migrations (search for "nixos-config" or "consumer"). Add:

```markdown
- [ ] **Downstream: move nixos-config ai/default.nix off programs.claude-code.\***
      The consumer currently uses programs.claude-code.{memory,mcpServers,settings,skills}
      directly because ai.claude._ didn't expose them. Plan
      `2026-04-06-ai-claude-passthrough.md` filled the gap; consumer
      should now be migrated to ai.claude._ in nixos-config. Touch
      points in nixos-config: `home/caubut/features/cli/code/ai/default.nix`
      L83-185. Skip the activation.installClaudePlugins hook — that
      stays bespoke.
```

- [ ] **Step 2: Commit**

```bash
treefmt docs/plan.md
git add docs/plan.md
git commit -m "docs(plan): backlog downstream ai.claude.* consumer migration

With ai.claude.* now fully mirroring programs.claude-code.*,
nixos-config consumer can be migrated. Tracked as follow-up."
```

---

## Self-Review Checklist

After implementing, verify:

1. **Spec coverage** — every option listed in `docs/plan.md:516-533` has a task:
   - `ai.claude.memory.text` ✓ Task 3
   - `ai.claude.skills` ✓ Tasks 2 + 6
   - `ai.claude.mcpServers` ✓ Task 5
   - `ai.claude.settings.*` ✓ Task 4
   - `ai.claude.plugins` ✓ Task 7 (static paths only; activation script deliberately out of scope, noted in Task 9 commit)
2. **Upstream type parity** — every new `ai.claude.*` option type matches `dev/references/claude-code-hm-options.md` exactly. Re-check before committing each task.
3. **Fanout priority** — `mkDefault` is used for cross-ecosystem overrides (`ai.skills` → `programs.claude-code.skills`) but NOT for direct passthroughs where the user's intent is a direct assignment (`ai.claude.memory.text`, `ai.claude.mcpServers.<name>`). This matches the buddy pattern at `modules/ai/default.nix:246-248`.
4. **MCP bridge semantics** — `enableMcpIntegration` uses `mkDefault true` so consumer can still set `programs.claude-code.enableMcpIntegration = false` to opt out. `mcpServers` does direct assignment because it's consumer-supplied data.
5. **No upstream assumptions** — the plan does NOT assume the upstream HM `programs.claude-code` module has options like `buddy`, `finalPackage` tweaks, or `rulesDir` / `agentsDir`. Those are out of scope for this plan.
6. **Consumer config proven** — Task 8 integration eval uses the exact shape the real consumer uses. If the real consumer grows new options, add them to the eval.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-06-ai-claude-passthrough.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task (1-10), review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
