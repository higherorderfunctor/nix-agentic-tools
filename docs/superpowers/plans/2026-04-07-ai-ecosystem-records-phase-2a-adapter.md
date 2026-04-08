# AI Ecosystem Records — Phase 2a (HM Adapter Rollout) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-ecosystem `mkIf cfg.<eco>.enable` fanout blocks in `modules/ai/default.nix` with calls to a new `lib/mk-ai-ecosystem-hm-module.nix` adapter that consumes the ecosystem records created in Phase 1. After this plan lands, the HM ai module is fully driven by ecosystem records; adding a new ecosystem to `ai.*` becomes "write a record file + add one import line" rather than "write 30 lines of fanout code".

**Architecture:** Seven atomic commits, test-first. Commit 1 does a trivial name cleanup carried forward from Phase 1. Commit 2 adds assertion-based safety-net tests against the current inline fanout behavior — these tests must pass before ANY code changes and continue passing through every refactor commit. Commit 3 introduces `lib/mk-ai-ecosystem-hm-module.nix` as a standalone unit with its own isolated tests. Commits 4-6 replace the Claude, Copilot, and Kiro inline fanout blocks one at a time, each verified against the safety-net tests. Commit 7 removes now-unused helpers from `modules/ai/default.nix`.

**Tech Stack:** Pure Nix (`lib.evalModules`, `lib.mkMerge`, `lib.recursiveUpdate`, `lib.setAttrByPath`). Test harness: `checks/module-eval.nix` extended with richer fixtures + property-based assertions. No new tools.

---

## Required reading (before starting)

Before executing any task, read:

1. **`dev/notes/ai-transformer-design.md`** — full design space, especially:
   - "Layer 2: Ecosystem records — the unifying abstraction" (the record shape)
   - "Layer 3: Backend adapters" (the sketch this plan implements)
   - "When to share, when to per-eco" (the decision rules)
   - "Scope correction (2026-04-07, second iteration)" (why translation is the general case)
2. **`docs/superpowers/plans/2026-04-07-ai-ecosystem-records-foundation.md`** — the Phase 1 plan. Phase 2a builds on it directly.
3. **`modules/ai/default.nix`** (~238 lines) — the file this plan refactors. Lines 58-62 are the imports block. Lines 64-132 are the option declarations. Lines 134-237 are the per-ecosystem `mkIf` fanout blocks that will be replaced.
4. **`lib/ai-ecosystems/claude.nix`** (~152 lines) — the claude ecosystem record. The `translators`, `layout`, `upstream`, and `extraOptions` fields are what the adapter consumes.
5. **`lib/ai-ecosystems/copilot.nix`** and **`lib/ai-ecosystems/kiro.nix`** — same shape, different policies.
6. **`lib/ai-options.nix`** (~102 lines) — the option types the adapter will reuse.
7. **`lib/fragments.nix`** (~183 lines) — specifically `mkRenderer` at lines 139-168, used by the adapter to render instruction bodies.
8. **`checks/module-eval.nix`** (~300 lines) — the test harness pattern this plan extends.
9. **`lib/ai-common.nix`** — `mkCopilotLspConfig` and `mkLspConfig`, still used in the current Kiro branch. These helpers wrap the ecosystem record's `translators.lspServer`; after Phase 2a the wrappers may be redundant.

---

## Out of scope (deferred to Phase 2b)

- **Layered option pools** (`ai.<eco>.<category>` extension points): the adapter in Phase 2a declares ONLY the existing per-ecosystem options (`ai.claude.{enable, package, buddy}`, `ai.copilot.{enable, package}`, `ai.kiro.{enable, package}`). It does NOT yet declare `ai.<eco>.mcpServers`, `ai.<eco>.skills`, etc. Adding those extension points is Phase 2b. This keeps Phase 2a as a pure equivalence-preserving refactor with no new capabilities.
- **Devenv adapter** (`lib/mk-ai-ecosystem-devenv-module.nix`): Phase 3.
- **`lib.mkRawEcosystem` helper**: Phase 3.
- **Downstream extension example** (`examples/external-ecosystem/`): Phase 3.
- **README/mdBook ecosystem records**: Phase 4.

If you find yourself wanting to implement layered option pools or touch the devenv module while executing this plan, **stop**. Phase 2a is scoped to a single, risky refactor — the adapter replaces three fanout blocks — and additional scope amplifies the risk of missing a property-based test drift.

---

## Architectural decisions

**Property-based testing instead of byte-identical snapshots.** Phase 1 used `nix build .#target` + hash-diff to verify byte-identical output. Phase 2a can't use that approach because `modules/ai/default.nix` doesn't produce a file — it's a NixOS module that gets evaluated at consumer time. Instead, each commit that touches fanout behavior is gated by assertion-based tests that evaluate the module with a fixture config and assert on specific option paths. If an assertion fails, the refactor has drifted.

**Commit-by-commit ecosystem replacement.** The Claude, Copilot, and Kiro branches are replaced in three separate commits. This lets us verify each one independently against the safety-net tests and gives a clean rollback point if one replacement is wrong.

**Adapter as a module constructor, not a module.** `lib/mk-ai-ecosystem-hm-module.nix` is a FUNCTION: `{lib, ...}: ecoRecord: moduleFn`. The result is a NixOS module (the `moduleFn` inner function). It's imported at the TOP of `modules/ai/default.nix`'s `imports` list, alongside the existing per-ecosystem module imports. The adapter's `options.ai.<name>` declaration replaces the inline submodule declaration; its `config` block replaces the inline `mkIf cfg.<name>.enable` block.

**The adapter reads `pkgs.fragments-ai.passthru.records.<name>`.** The record is accessed via `pkgs` inside the outer module function of `modules/ai/default.nix`. This is why the `imports = [ ... ]` list gets the adapter calls wrapped in `pkgs`-aware let bindings — `pkgs` must be in scope when the adapter is invoked.

**The `extraOptions` field is merged into the per-ecosystem submodule type.** The claude record's `extraOptions` contains a `buddy` submodule declaration. The adapter calls `ecoRecord.extraOptions { inherit lib; }` and merges the result into `options.ai.<name>` via attrset spread. This preserves the `ai.claude.buddy = { ... }` option without hardcoding buddy into the adapter.

**Upstream module delegation via `upstream.hm.<category>Option`.** When `record.upstream.hm.skillsOption` is non-null (e.g., `"programs.claude-code.skills"`), the adapter sets that option path via `lib.setAttrByPath`. When it's null, the adapter writes files directly via `home.file`. Phase 2a ecosystems all have non-null upstream options for skills; orphan ecosystems (Phase 3's use case) will have nulls.

**Translation is uniform.** Every category goes through `record.translators.<category>` before being written to the backend, matching the design note's "translation as the general case, passthrough as identity" framing. Phase 1's ecosystem records already declare identity translators for skills and instructions, so this is a drop-in.

---

## File structure

Files this plan creates:

- `lib/mk-ai-ecosystem-hm-module.nix` — the HM backend adapter. Takes an ecosystem record, returns a NixOS module that declares `options.ai.<name>` and its fanout config.

Files this plan modifies:

- `dev/generate.nix` — renames the local `composedByPkg` binding to `composedByPackage` to match the passthru placeholder name. Carry-forward from Phase 1 final review.
- `checks/module-eval.nix` — adds rich fixtures and property-based assertions for each of the three ecosystems' current fanout behavior. These tests MUST pass before Commit 3 touches any adapter code, and continue passing through Commits 4-6.
- `modules/ai/default.nix` — three progressive simplifications:
  - Commit 4 removes the Claude inline `mkIf` block and the `ai.claude` submodule option declaration; imports the adapter-generated Claude module
  - Commit 5 same for Copilot
  - Commit 6 same for Kiro
  - Commit 7 removes now-unused lets (`aiTransforms`, `buddySubmodule`, `concatMapAttrs`, `aiCommon.mkCopilotLspConfig`, `aiCommon.mkLspConfig`, etc.)

Files this plan does **not** touch:

- `lib/fragments.nix`, `lib/ai-options.nix`, `lib/ai-ecosystems/*.nix`, `lib/transformers/base.nix` — Phase 1 artifacts, stable
- `packages/fragments-ai/default.nix` — Phase 1's shim + records
- `modules/claude-code-buddy/`, `modules/copilot-cli/`, `modules/kiro-cli/` — upstream per-ecosystem modules, unchanged
- `modules/devenv/ai.nix` — devenv mirror, deferred to Phase 3
- `dev/generate.nix` body (only the rename in Commit 1)

---

## Pre-flight verification

- [ ] **Step 0.1: Verify on the right branch**

  Run: `git status`

  Expected: `On branch refactor/ai-ecosystem-records`. HEAD should be at `8d5d9c4` (Phase 1 final commit). If you're on a different branch or HEAD, escalate.

- [ ] **Step 0.2: Verify merge-base anchor unchanged**

  Run: `git merge-base refactor/ai-ecosystem-records sentinel/monorepo-plan`

  Expected: `31590a37df86af0c65d14185b598558d6ed2899a`. This is the Phase 1 branch anchor recorded in `docs/plan.md`. It must not move during Phase 2a.

- [ ] **Step 0.3: Verify baseline `nix flake check` passes**

  Run: `nix flake check 2>&1 | tail -20`

  Expected: no errors, all Phase 1 checks green (including the 14 `fragments-test-*` from Commit 1 and the existing `aiSelfContained`, `aiSkillsFanout`, `aiWithSettings`, etc.).

- [ ] **Step 0.4: Verify baseline snapshots from Phase 1 still exist**

  Run: `ls /tmp/ai-records-baseline/HASHES && wc -l /tmp/ai-records-baseline/HASHES`

  Expected: file exists, ~46 lines (45 content entries + 1 self-reference). If missing, the Phase 1 snapshots were cleared — that's OK for Phase 2a (we use property-based tests, not byte-identical diffs), but note it in the final report.

- [ ] **Step 0.5: Verify the Phase 1 records are queryable**

  Run:
  ```bash
  for eco in claude copilot kiro agentsmd; do
    nix eval --raw ".#fragments-ai.passthru.records.$eco.name"
    echo
  done
  ```

  Expected: `claude`, `copilot`, `kiro`, `agentsmd` one per line. If any fails, Phase 1 is broken — escalate, do not proceed.

---

## Commit 1: Rename `composedByPkg` → `composedByPackage`

**Purpose:** Warmup cleanup. Carried forward from the Phase 1 final code review (Minor M1). Renames the local binding in `dev/generate.nix` to match the `passthru.composedByPackage` placeholder on `pkgs.fragments-ai`, so future Phase 2/3 adapters can read from the passthru slot with the same name Phase 2a's internal refactor uses.

### Task 1.1: Rename the binding

**Files:**
- Modify: `dev/generate.nix` (the `composedByPkg` binding and its 3 consumers inside claudeFiles, copilotFiles, kiroFiles)

- [ ] **Step 1.1.1: Read the current state of `dev/generate.nix`**

  Run: `grep -n 'composedByPkg' dev/generate.nix`

  Expected output: 4 matches — one binding definition and three consumer references.

- [ ] **Step 1.1.2: Rename all occurrences**

  Run:
  ```bash
  sed -i 's/composedByPkg/composedByPackage/g' dev/generate.nix
  grep -n 'composedByPkg\|composedByPackage' dev/generate.nix
  ```

  Expected: 4 matches with `composedByPackage`, 0 matches with `composedByPkg`.

- [ ] **Step 1.1.3: Verify the file still parses**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

- [ ] **Step 1.1.4: Verify byte-identical output against Phase 1 baseline**

  Run:
  ```bash
  rm -rf /tmp/phase2a-c1 && mkdir -p /tmp/phase2a-c1
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/phase2a-c1/$target"
  done
  find /tmp/phase2a-c1 -type f -exec sha256sum {} \; | sort | sed 's|/tmp/phase2a-c1/|/tmp/ai-records-baseline/|' > /tmp/phase2a-c1/HASHES_normalized
  diff <(grep -v 'HASHES$' /tmp/ai-records-baseline/HASHES) <(grep -v 'HASHES$' /tmp/phase2a-c1/HASHES_normalized)
  echo "exit: $?"
  ```

  Expected: empty diff, exit 0. Rename-only changes must not affect output bytes.

### Task 1.2: Commit

- [ ] **Step 1.2.1: Stage and commit**

  Run:
  ```bash
  git add dev/generate.nix
  git commit -m "$(cat <<'EOF'
  refactor(generate): rename composedByPkg to composedByPackage

  Match the naming between the local binding in dev/generate.nix and
  the pkgs.fragments-ai.passthru.composedByPackage placeholder added
  in Phase 1. Phase 1's final code review (M1) flagged this as a
  transition concern: the mismatched names would confuse readers
  during Phase 2's adapter rollout when both the local binding and
  the passthru slot become visible in the same call chain.

  Rename-only; no behavior change; byte-identical output verified
  against the Phase 1 baseline snapshots.

  Phase 2a warmup commit. See
  dev/notes/ai-transformer-design.md and
  docs/superpowers/plans/2026-04-07-ai-ecosystem-records-phase-2a-adapter.md.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -2
  ```

  Expected: new commit on `refactor/ai-ecosystem-records` with subject `refactor(generate): rename composedByPkg to composedByPackage`. Parent should be `8d5d9c4`.

---

## Commit 2: Safety-net property-based tests

**Purpose:** Add assertion-based tests for the CURRENT inline fanout behavior in `modules/ai/default.nix`. These tests must pass BEFORE any adapter code exists, and must continue passing through every subsequent refactor commit. They are the regression gate that proves Commits 3-6 preserve behavior.

The tests cover the effective config produced when `lib.evalModules` is run against the ai module with representative input fixtures. Each of the three ecosystems gets its own fixture + assertions.

### Task 2.1: Add Claude fanout property tests

**Files:**
- Modify: `checks/module-eval.nix` (append new fixture + checks)

- [ ] **Step 2.1.1: Read the current `checks/module-eval.nix`**

  Run: `cat checks/module-eval.nix`

  Note the existing `evalModule` harness (lines 10-86), the existing fixture-based tests like `aiWithClis` (lines 120-135), and the existing check derivations (lines 212-300). Your new tests follow the same pattern: `let`-bind a fixture evaluation, then add a `runCommand` check that asserts on specific config values.

- [ ] **Step 2.1.2: Add the Claude safety-net fixture**

  Find the line near the end of the `let` block that defines `aiSelfContained` (around line 193-211). Insert the following BEFORE the `in {` that ends the `let` block:

  ```nix
    # ═══════════════════════════════════════════════════════════════
    # Phase 2a safety-net fixtures: assertion-based tests for the
    # current inline ai module fanout. These tests run against the
    # EXISTING inline mkIf blocks in modules/ai/default.nix before
    # Phase 2a's adapter refactor, and MUST continue passing after
    # each of Commits 4-6 replaces one ecosystem's inline block with
    # a mkAiEcosystemHmModule call. If any assertion fails during a
    # replacement commit, the adapter has drifted from the legacy
    # behavior — rollback and debug before re-attempting.
    # ═══════════════════════════════════════════════════════════════

    # Rich Claude fixture exercising all Claude-relevant options.
    phase2aClaudeFixture = evalModule [
      self.homeManagerModules.ai
      {
        config = {
          ai = {
            claude = {
              enable = true;
              buddy = {
                userId.text = "test-00000000-0000-0000-0000-000000000000";
                species = "duck";
                rarity = "common";
              };
            };
            skills.stack-fix = /tmp/test-stack-fix-skill;
            instructions.test-rule = {
              text = "Always use strict mode";
              paths = ["src/**"];
              description = "Test rule for Phase 2a safety net";
            };
            lspServers.nixd = {
              name = "nixd";
              package = pkgs.hello; # stub package; real nixd not needed for eval
              extensions = ["nix"];
            };
            settings.model = "claude-sonnet-4-test";
          };
        };
      }
    ];

    # Rich Copilot fixture.
    phase2aCopilotFixture = evalModule [
      self.homeManagerModules.ai
      {
        config = {
          ai = {
            copilot.enable = true;
            skills.stack-fix = /tmp/test-stack-fix-skill;
            instructions.test-rule = {
              text = "Use fp patterns";
              paths = ["lib/**"];
              description = "Test rule";
            };
            lspServers.marksman = {
              name = "marksman";
              package = pkgs.hello;
              extensions = ["md"];
            };
            environmentVariables.AI_TEST_MODE = "1";
            settings.model = "gpt-4-test";
          };
        };
      }
    ];

    # Rich Kiro fixture.
    phase2aKiroFixture = evalModule [
      self.homeManagerModules.ai
      {
        config = {
          ai = {
            kiro.enable = true;
            skills.stack-fix = /tmp/test-stack-fix-skill;
            instructions.test-rule = {
              text = "No shortcuts";
              paths = ["tests/**"];
              description = "Test steering rule";
            };
            lspServers.nixd = {
              name = "nixd";
              package = pkgs.hello;
              extensions = ["nix"];
            };
            environmentVariables.KIRO_TEST_MODE = "1";
            settings = {
              model = "claude-sonnet-4-test";
              telemetry = false;
            };
          };
        };
      }
    ];
  ```

- [ ] **Step 2.1.3: Add Claude assertion checks to the output block**

  Find the `in { ... }` export block at the bottom of `checks/module-eval.nix` (around line 212). Add these new checks BEFORE the closing `}`:

  ```nix
    # ── Phase 2a safety-net assertions: Claude ─────────────────────
    phase2a-claude-enable = pkgs.runCommand "phase2a-claude-enable" {} ''
      ${
        if phase2aClaudeFixture.config.programs.claude-code.enable
        then "echo ok > $out"
        else "echo 'FAIL: ai.claude.enable did not propagate to programs.claude-code.enable' >&2; exit 1"
      }
    '';

    phase2a-claude-skills-fanout = pkgs.runCommand "phase2a-claude-skills-fanout" {} ''
      ${
        if phase2aClaudeFixture.config.programs.claude-code.skills ? stack-fix
        then "echo ok > $out"
        else "echo 'FAIL: ai.skills.stack-fix did not reach programs.claude-code.skills' >&2; exit 1"
      }
    '';

    phase2a-claude-instruction-fanout = pkgs.runCommand "phase2a-claude-instruction-fanout" {} ''
      ${
        if phase2aClaudeFixture.config.home.file ? ".claude/rules/test-rule.md"
        then "echo ok > $out"
        else "echo 'FAIL: ai.instructions.test-rule did not write .claude/rules/test-rule.md' >&2; exit 1"
      }
    '';

    phase2a-claude-instruction-content = pkgs.runCommand "phase2a-claude-instruction-content" {} ''
      ${
        let
          text = phase2aClaudeFixture.config.home.file.".claude/rules/test-rule.md".text;
          hasFrontmatter = lib.hasInfix "---" text;
          hasDescription = lib.hasInfix "Test rule for Phase 2a safety net" text;
          hasPaths = lib.hasInfix "src/**" text;
          hasBody = lib.hasInfix "Always use strict mode" text;
        in
          if hasFrontmatter && hasDescription && hasPaths && hasBody
          then "echo ok > $out"
          else "echo 'FAIL: claude rule file content missing frontmatter (${toString hasFrontmatter}), description (${toString hasDescription}), paths (${toString hasPaths}), or body (${toString hasBody})' >&2; exit 1"
      }
    '';

    phase2a-claude-settings-model = pkgs.runCommand "phase2a-claude-settings-model" {} ''
      ${
        if phase2aClaudeFixture.config.programs.claude-code.settings.model == "claude-sonnet-4-test"
        then "echo ok > $out"
        else "echo 'FAIL: ai.settings.model did not propagate to programs.claude-code.settings.model' >&2; exit 1"
      }
    '';

    phase2a-claude-lsp-auto-enable = pkgs.runCommand "phase2a-claude-lsp-auto-enable" {} ''
      ${
        if (phase2aClaudeFixture.config.programs.claude-code.settings.env.ENABLE_LSP_TOOL or null) == "1"
        then "echo ok > $out"
        else "echo 'FAIL: ai.lspServers did not auto-enable ENABLE_LSP_TOOL=1' >&2; exit 1"
      }
    '';

    phase2a-claude-buddy-fanout = pkgs.runCommand "phase2a-claude-buddy-fanout" {} ''
      ${
        if phase2aClaudeFixture.config.programs.claude-code.buddy != null
          && phase2aClaudeFixture.config.programs.claude-code.buddy.species == "duck"
        then "echo ok > $out"
        else "echo 'FAIL: ai.claude.buddy did not propagate to programs.claude-code.buddy with species=duck' >&2; exit 1"
      }
    '';
  ```

- [ ] **Step 2.1.4: Run the new checks**

  Run: `nix flake check 2>&1 | grep -E "phase2a-claude|^error"`

  Expected: all `phase2a-claude-*` checks build successfully (no `error:` lines). Any failure means the test is wrong (not the current ai module) — fix the test.

### Task 2.2: Add Copilot fanout property tests

**Files:**
- Modify: `checks/module-eval.nix` (add Copilot assertion checks to the output block)

- [ ] **Step 2.2.1: Add Copilot assertion checks**

  Add these new checks to the `in { ... }` export block, alongside the Claude checks:

  ```nix
    # ── Phase 2a safety-net assertions: Copilot ────────────────────
    phase2a-copilot-enable = pkgs.runCommand "phase2a-copilot-enable" {} ''
      ${
        if phase2aCopilotFixture.config.programs.copilot-cli.enable
        then "echo ok > $out"
        else "echo 'FAIL: ai.copilot.enable did not propagate to programs.copilot-cli.enable' >&2; exit 1"
      }
    '';

    phase2a-copilot-skills-fanout = pkgs.runCommand "phase2a-copilot-skills-fanout" {} ''
      ${
        if phase2aCopilotFixture.config.programs.copilot-cli.skills ? stack-fix
        then "echo ok > $out"
        else "echo 'FAIL: ai.skills.stack-fix did not reach programs.copilot-cli.skills' >&2; exit 1"
      }
    '';

    phase2a-copilot-instruction-fanout = pkgs.runCommand "phase2a-copilot-instruction-fanout" {} ''
      ${
        if phase2aCopilotFixture.config.programs.copilot-cli.instructions ? test-rule
        then "echo ok > $out"
        else "echo 'FAIL: ai.instructions.test-rule did not reach programs.copilot-cli.instructions' >&2; exit 1"
      }
    '';

    phase2a-copilot-instruction-has-apply-to = pkgs.runCommand "phase2a-copilot-instruction-has-apply-to" {} ''
      ${
        let
          text = phase2aCopilotFixture.config.programs.copilot-cli.instructions.test-rule;
          hasApplyTo = lib.hasInfix "applyTo" text;
          hasPattern = lib.hasInfix "lib/**" text;
        in
          if hasApplyTo && hasPattern
          then "echo ok > $out"
          else "echo 'FAIL: copilot instruction content missing applyTo (${toString hasApplyTo}) or lib/** pattern (${toString hasPattern})' >&2; exit 1"
      }
    '';

    phase2a-copilot-env-vars = pkgs.runCommand "phase2a-copilot-env-vars" {} ''
      ${
        if (phase2aCopilotFixture.config.programs.copilot-cli.environmentVariables.AI_TEST_MODE or null) == "1"
        then "echo ok > $out"
        else "echo 'FAIL: ai.environmentVariables.AI_TEST_MODE did not reach programs.copilot-cli.environmentVariables' >&2; exit 1"
      }
    '';

    phase2a-copilot-settings-model = pkgs.runCommand "phase2a-copilot-settings-model" {} ''
      ${
        if phase2aCopilotFixture.config.programs.copilot-cli.settings.model == "gpt-4-test"
        then "echo ok > $out"
        else "echo 'FAIL: ai.settings.model did not reach programs.copilot-cli.settings.model' >&2; exit 1"
      }
    '';

    phase2a-copilot-lsp-fanout = pkgs.runCommand "phase2a-copilot-lsp-fanout" {} ''
      ${
        if phase2aCopilotFixture.config.programs.copilot-cli.lspServers ? marksman
        then "echo ok > $out"
        else "echo 'FAIL: ai.lspServers.marksman did not reach programs.copilot-cli.lspServers' >&2; exit 1"
      }
    '';
  ```

- [ ] **Step 2.2.2: Run the Copilot checks**

  Run: `nix flake check 2>&1 | grep -E "phase2a-copilot|^error"`

  Expected: all `phase2a-copilot-*` checks build successfully.

### Task 2.3: Add Kiro fanout property tests

**Files:**
- Modify: `checks/module-eval.nix` (add Kiro assertion checks to the output block)

- [ ] **Step 2.3.1: Add Kiro assertion checks**

  Add these new checks to the `in { ... }` export block:

  ```nix
    # ── Phase 2a safety-net assertions: Kiro ───────────────────────
    phase2a-kiro-enable = pkgs.runCommand "phase2a-kiro-enable" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.enable
        then "echo ok > $out"
        else "echo 'FAIL: ai.kiro.enable did not propagate to programs.kiro-cli.enable' >&2; exit 1"
      }
    '';

    phase2a-kiro-skills-fanout = pkgs.runCommand "phase2a-kiro-skills-fanout" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.skills ? stack-fix
        then "echo ok > $out"
        else "echo 'FAIL: ai.skills.stack-fix did not reach programs.kiro-cli.skills' >&2; exit 1"
      }
    '';

    phase2a-kiro-steering-fanout = pkgs.runCommand "phase2a-kiro-steering-fanout" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.steering ? test-rule
        then "echo ok > $out"
        else "echo 'FAIL: ai.instructions.test-rule did not reach programs.kiro-cli.steering' >&2; exit 1"
      }
    '';

    phase2a-kiro-steering-has-inclusion = pkgs.runCommand "phase2a-kiro-steering-has-inclusion" {} ''
      ${
        let
          text = phase2aKiroFixture.config.programs.kiro-cli.steering.test-rule;
          hasInclusion = lib.hasInfix "inclusion: fileMatch" text;
          hasPattern = lib.hasInfix "tests/**" text;
        in
          if hasInclusion && hasPattern
          then "echo ok > $out"
          else "echo 'FAIL: kiro steering content missing inclusion: fileMatch (${toString hasInclusion}) or tests/** pattern (${toString hasPattern})' >&2; exit 1"
      }
    '';

    phase2a-kiro-env-vars = pkgs.runCommand "phase2a-kiro-env-vars" {} ''
      ${
        if (phase2aKiroFixture.config.programs.kiro-cli.environmentVariables.KIRO_TEST_MODE or null) == "1"
        then "echo ok > $out"
        else "echo 'FAIL: ai.environmentVariables.KIRO_TEST_MODE did not reach programs.kiro-cli.environmentVariables' >&2; exit 1"
      }
    '';

    phase2a-kiro-settings-model-remap = pkgs.runCommand "phase2a-kiro-settings-model-remap" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.settings.chat.defaultModel == "claude-sonnet-4-test"
        then "echo ok > $out"
        else "echo 'FAIL: ai.settings.model did not remap to programs.kiro-cli.settings.chat.defaultModel (key remap is the critical kiro test)' >&2; exit 1"
      }
    '';

    phase2a-kiro-settings-telemetry = pkgs.runCommand "phase2a-kiro-settings-telemetry" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.settings.telemetry.enabled == false
        then "echo ok > $out"
        else "echo 'FAIL: ai.settings.telemetry did not remap to programs.kiro-cli.settings.telemetry.enabled' >&2; exit 1"
      }
    '';

    phase2a-kiro-lsp-fanout = pkgs.runCommand "phase2a-kiro-lsp-fanout" {} ''
      ${
        if phase2aKiroFixture.config.programs.kiro-cli.lspServers ? nixd
        then "echo ok > $out"
        else "echo 'FAIL: ai.lspServers.nixd did not reach programs.kiro-cli.lspServers' >&2; exit 1"
      }
    '';
  ```

- [ ] **Step 2.3.2: Run the Kiro checks**

  Run: `nix flake check 2>&1 | grep -E "phase2a-kiro|^error"`

  Expected: all `phase2a-kiro-*` checks build successfully.

### Task 2.4: Verify all safety-net tests pass end-to-end

- [ ] **Step 2.4.1: Count the new checks**

  Run: `nix flake check 2>&1 | grep -c 'phase2a-'`

  Expected: 22 (7 claude + 7 copilot + 8 kiro).

- [ ] **Step 2.4.2: Run the full flake check**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors, all checks green. The existing Phase 1 checks (`fragments-test-*`, `aiSelfContained`, `aiSkillsFanout`, `aiWithSettings`, etc.) continue passing alongside the new Phase 2a safety-net checks.

### Task 2.5: Commit the safety-net tests

- [ ] **Step 2.5.1: Stage and commit**

  Run:
  ```bash
  git add checks/module-eval.nix
  git commit -m "$(cat <<'EOF'
  test(ai): add phase 2a safety-net assertions for inline fanout

  Adds 22 assertion-based tests to checks/module-eval.nix that
  exercise the current inline ai module fanout with rich fixtures
  (skills, instructions, lspServers, environmentVariables, settings,
  buddy). Each of the three ecosystems has 7-8 tests covering:

    - enable propagation (ai.<eco>.enable -> programs.<cli>.enable)
    - skills fanout
    - instructions rendering and placement
    - frontmatter content (claude description, copilot applyTo,
      kiro inclusion + fileMatchPattern)
    - environment variable fanout (copilot, kiro)
    - settings key translation (claude passthrough, copilot
      passthrough, kiro chat.defaultModel + telemetry.enabled remap)
    - lspServers fanout (including claude auto-enable of
      ENABLE_LSP_TOOL)
    - buddy fanout (claude only)

  These tests MUST pass against the CURRENT inline mkIf blocks
  (verified by this commit passing nix flake check) and MUST
  continue passing through commits 4-6 of Phase 2a, where each
  inline block is replaced with a mkAiEcosystemHmModule call.
  Any drift during an ecosystem replacement will be caught by
  these assertions.

  No code changes to modules/ai/default.nix yet — this commit is
  the regression safety net for the refactor that follows.

  Phase 2a commit 2 of 7.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -3
  ```

  Expected: new commit with subject `test(ai): add phase 2a safety-net assertions for inline fanout`.

---

## Commit 3: Introduce `lib/mk-ai-ecosystem-hm-module.nix` adapter

**Purpose:** Create the adapter file and verify it produces a valid NixOS module in isolation. The adapter is NOT YET WIRED into `modules/ai/default.nix` — that happens in Commits 4-6. This commit's gate is: the adapter, when called with a representative ecosystem record, produces a module whose effective config satisfies the safety-net assertions from Commit 2.

### Task 3.1: Create `lib/mk-ai-ecosystem-hm-module.nix`

**Files:**
- Create: `lib/mk-ai-ecosystem-hm-module.nix`

- [ ] **Step 3.1.1: Write the adapter file**

  Write `lib/mk-ai-ecosystem-hm-module.nix` with the following content:

  ```nix
  # HM backend adapter for the ai-ecosystem-records refactor.
  #
  # Takes an ecosystem record (from lib/ai-ecosystems/<name>.nix or
  # pkgs.fragments-ai.passthru.records.<name>) and returns a NixOS
  # module function suitable for inclusion in a home-manager
  # module's `imports` list.
  #
  # The returned module:
  #   1. Declares options.ai.<name> as a submodule with:
  #      - enable (mkEnableOption)
  #      - package (default = ecoRecord.package or a caller-supplied
  #        fallback; the adapter doesn't hardcode package names)
  #      - any extra options from ecoRecord.extraOptions { inherit lib; }
  #
  #   2. Inside mkIf cfg.<name>.enable, produces a config block that:
  #      - Flips the upstream module's enable (if ecoRecord.upstream.hm.enableOption != null)
  #      - Writes skills via upstream.hm.skillsOption delegation or home.file direct write
  #      - Renders instructions via ecoRecord.markdownTransformer through mkRenderer
  #      - Places rendered instructions via upstream.hm.instructionsOption delegation
  #        or home.file direct write (keyed on ecoRecord.layout.instructionPath)
  #      - Translates and places settings via upstream.hm.settingsOption
  #      - Translates and places lspServers via upstream.hm.lspServersOption
  #      - Translates and places environmentVariables via upstream.hm.envVarsOption
  #        (or skips if ecoRecord.translators.envVar is null)
  #      - Translates and places mcpServers via upstream.hm.mcpServersOption
  #        (or skips if null — Phase 2a ecosystems have null for mcpServers
  #        because the existing inline fanout doesn't set ai-level mcp)
  #
  # Phase 2a scope: the adapter reads from the shared ai.* options
  # directly (cfg.skills, cfg.instructions, etc.) without the per-eco
  # layered pool extension. Phase 2b will add the layered pools.
  #
  # See dev/notes/ai-transformer-design.md "Layer 3: Backend adapters"
  # for the full design.
  {lib}: let
    fragmentsLib = import ./fragments.nix {inherit lib;};
    aiOptions = import ./ai-options.nix {inherit lib;};
    aiCommon = import ./ai-common.nix {inherit lib;};
  in
    ecoRecord: {
      config,
      pkgs,
      ...
    }: let
      cfg = config.ai;
      ecoCfg = cfg.${ecoRecord.name};

      # ── Render markdown for each instruction ───────────────────
      # The markdownTransformer is the Phase 1 record field. It
      # consumes an instruction (text, paths, description, priority)
      # and produces the rendered string with ecosystem-specific
      # frontmatter.
      renderInstruction = name: instr: let
        # ctxExtras is the third arg to mkRenderer. It carries
        # per-instruction metadata that the frontmatter function
        # pattern-matches on (claude needs `package`, kiro needs
        # `name`). We thread `name` as both `package` (for claude)
        # and `name` (for kiro) — both frontmatter functions use
        # `...` to absorb unknown args, so this is safe.
        ctxExtras = {
          package = name;
          name = name;
        };
        render = fragmentsLib.mkRenderer ecoRecord.markdownTransformer ctxExtras;
      in
        render instr;

      # ── Translated effective values ───────────────────────────
      # Every category goes through the ecosystem's translator.
      # For Phase 2a, "effective" is just cfg.<category> — no
      # per-eco layered pool merge yet. Phase 2b adds that merge.
      #
      # Null translator = ecosystem doesn't support this category;
      # we skip dispatch entirely.
      translated = {
        skills =
          if ecoRecord.translators.skills != null
          then lib.mapAttrs (n: v: ecoRecord.translators.skills n v) cfg.skills
          else null;
        instructions =
          if ecoRecord.translators.instructions != null
          then lib.mapAttrs (n: v: ecoRecord.translators.instructions n v) cfg.instructions
          else null;
        settings =
          if ecoRecord.translators.settings != null
          then ecoRecord.translators.settings cfg.settings
          else null;
        lspServers =
          if ecoRecord.translators.lspServer != null
          then lib.mapAttrs (n: v: ecoRecord.translators.lspServer n v) cfg.lspServers
          else null;
        environmentVariables =
          if ecoRecord.translators.envVar != null
          then
            lib.foldl' (acc: name:
              acc // (ecoRecord.translators.envVar name cfg.environmentVariables.${name}))
            {} (lib.attrNames cfg.environmentVariables)
          else null;
      };

      # ── Rendered instruction content for Claude's home.file path ──
      # Claude's inline fanout (pre-Phase-2a) writes instructions as
      # home.file.".claude/rules/<name>.md".text, not via a programs.*
      # option. We preserve this by rendering through the
      # markdownTransformer and writing to ecoRecord.layout.instructionPath.
      # Kiro and Copilot delegate to programs.<cli>.steering /
      # programs.<cli>.instructions respectively, so they take a
      # different code path below.
      claudeRulesHomeFile = lib.concatMapAttrs (name: instr: {
        "${ecoRecord.layout.instructionPath name}" = {
          text = lib.mkDefault (renderInstruction name instr);
        };
      }) cfg.instructions;

      # ── Dispatch to upstream option or home.file ──────────────
      # Helper: set an upstream option path if non-null, else
      # return an empty attrset (caller handles the fallback).
      setUpstreamOption = optionPath: value:
        if optionPath != null
        then lib.setAttrByPath (lib.splitString "." optionPath) value
        else {};

      # Enable the upstream module (programs.<cli>.enable = true)
      enableBlock =
        if ecoRecord.upstream.hm.enableOption != null
        then setUpstreamOption ecoRecord.upstream.hm.enableOption (lib.mkDefault true)
        else {};

      # Skills: delegate to upstream option if present, wrapping
      # each entry with mkDefault so per-ecosystem overrides win.
      skillsBlock =
        if translated.skills != null && ecoRecord.upstream.hm.skillsOption != null
        then setUpstreamOption ecoRecord.upstream.hm.skillsOption (
          lib.mapAttrs (_: lib.mkDefault) translated.skills
        )
        else {};

      # Instructions: two dispatch paths.
      #   Path 1 (claude): no dedicated upstream option; rendered
      #     bytes go to home.file via layout.instructionPath.
      #   Path 2 (copilot, kiro): upstream option
      #     (programs.copilot-cli.instructions / programs.kiro-cli.steering)
      #     accepts the rendered text per name; we map the rendered
      #     values into it.
      # The record's upstream.hm may grow an `instructionsOption`
      # field in Phase 2b to unify these paths; for now Phase 2a
      # matches the existing inline behavior by checking
      # ecoRecord.name directly. This name-switch is deliberate —
      # it's the one place the adapter has per-ecosystem branching,
      # and it gets removed in Phase 2b's layered-pool refactor.
      instructionsBlock =
        if ecoRecord.name == "claude"
        then { home.file = claudeRulesHomeFile; }
        else if ecoRecord.name == "copilot"
        then {
          programs.copilot-cli.instructions = lib.mapAttrs (name: instr:
            lib.mkDefault (renderInstruction name instr))
          cfg.instructions;
        }
        else if ecoRecord.name == "kiro"
        then {
          programs.kiro-cli.steering = lib.mapAttrs (name: instr:
            lib.mkDefault (renderInstruction name instr))
          cfg.instructions;
        }
        else {};

      # Settings: delegate to upstream option if the translator
      # returned a non-empty result.
      settingsBlock =
        if translated.settings != null
          && translated.settings != {}
          && ecoRecord.upstream.hm.settingsOption != null
        then setUpstreamOption ecoRecord.upstream.hm.settingsOption (
          lib.mapAttrsRecursive (_: v: lib.mkDefault v) translated.settings
        )
        else {};

      # LSP servers: the current inline fanout uses mkLspConfig /
      # mkCopilotLspConfig from lib/ai-common.nix, which do roughly
      # what the record's translator.lspServer does but with
      # ecosystem-specific key mangling. For Phase 2a we invoke the
      # existing helpers directly to preserve byte-identical
      # behavior; Phase 2b will migrate to the record's translator.
      lspServersBlock =
        if cfg.lspServers != {}
        then
          if ecoRecord.name == "claude"
          then {
            programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
          }
          else if ecoRecord.name == "copilot"
          then {
            programs.copilot-cli.lspServers = lib.mapAttrs (name: server:
              lib.mkDefault (aiCommon.mkCopilotLspConfig name server))
            cfg.lspServers;
          }
          else if ecoRecord.name == "kiro"
          then {
            programs.kiro-cli.lspServers = lib.mapAttrs (name: server:
              lib.mkDefault (aiCommon.mkLspConfig name server))
            cfg.lspServers;
          }
          else {}
        else {};

      # Environment variables: claude skips (translator is null);
      # copilot/kiro pass through to programs.<cli>.environmentVariables.
      envVarsBlock =
        if ecoRecord.translators.envVar != null
          && translated.environmentVariables != null
          && translated.environmentVariables != {}
        then
          if ecoRecord.name == "copilot"
          then {
            programs.copilot-cli.environmentVariables =
              lib.mapAttrs (_: lib.mkDefault) translated.environmentVariables;
          }
          else if ecoRecord.name == "kiro"
          then {
            programs.kiro-cli.environmentVariables =
              lib.mapAttrs (_: lib.mkDefault) translated.environmentVariables;
          }
          else {}
        else {};

      # Extra options: the record's extraOptions field returns
      # ecosystem-specific extra submodule options (e.g., claude's
      # buddy). These get merged into the per-ecosystem submodule
      # type declaration at options.ai.<name> below.
      extraOptionAttrs = ecoRecord.extraOptions {inherit lib;};

      # Fanout for claude's buddy field: if ecoRecord is claude
      # AND ecoCfg.buddy != null, set programs.claude-code.buddy.
      # This is another per-ecosystem special-case that Phase 2b
      # absorbs into the layered-pool pattern.
      buddyBlock =
        if ecoRecord.name == "claude" && (ecoCfg.buddy or null) != null
        then {programs.claude-code.buddy = ecoCfg.buddy;}
        else {};

      # Assemble the full fanout config block.
      fanoutBlock = lib.mkMerge [
        enableBlock
        skillsBlock
        instructionsBlock
        settingsBlock
        lspServersBlock
        envVarsBlock
        buddyBlock
      ];
    in {
      options.ai.${ecoRecord.name} = lib.mkOption {
        type = lib.types.submodule {
          options =
            {
              enable = lib.mkEnableOption "Fan out shared config to ${ecoRecord.name}";
              package = lib.mkOption {
                type = lib.types.package;
                default = ecoRecord.package or (pkgs.${ecoRecord.name} or pkgs.hello);
                defaultText = lib.literalExpression "ecoRecord.package or pkgs.${ecoRecord.name}";
                description = "${ecoRecord.name} package.";
              };
            }
            // extraOptionAttrs;
        };
        default = {};
        description = "${ecoRecord.name} ecosystem configuration.";
      };

      config = lib.mkIf ecoCfg.enable fanoutBlock;
    }
  ```

- [ ] **Step 3.1.2: Verify the file parses**

  Run:
  ```bash
  nix-instantiate --eval --strict --expr '
    with import <nixpkgs> {};
    let
      mkAdapter = import ./lib/mk-ai-ecosystem-hm-module.nix { inherit lib; };
    in builtins.typeOf mkAdapter
  '
  ```

  Expected output: `"lambda"` (the adapter is a function that takes `ecoRecord` and returns a module function).

### Task 3.2: Add adapter isolation test

**Files:**
- Modify: `checks/module-eval.nix` (add an isolation test for the adapter)

- [ ] **Step 3.2.1: Add adapter isolation fixture**

  Append the following fixture to the `let` block in `checks/module-eval.nix`, before the `in {` export:

  ```nix
    # Phase 2a isolation test: evaluate the adapter in isolation
    # against the claude ecosystem record. Does NOT use the full ai
    # module — just the adapter + claude record + a minimal fixture.
    # Verifies the adapter produces a valid module that fans out
    # correctly even without the surrounding inline blocks.
    phase2aClaudeAdapterIsolation = let
      mkAdapter = import ../lib/mk-ai-ecosystem-hm-module.nix {inherit lib;};
      claudeRecord = import ../lib/ai-ecosystems/claude.nix {inherit lib;};
      claudeModule = mkAdapter claudeRecord;
      # The adapter references cfg.skills, cfg.instructions, etc.
      # directly. In isolation, we need to stub those at the top
      # level since the full ai module isn't loaded.
      stubAiShared = {lib, ...}: {
        options.ai = {
          skills = aiOptions.skillsOption;
          instructions = aiOptions.instructionsOption;
          lspServers = aiOptions.lspServersOption;
          environmentVariables = aiOptions.environmentVariablesOption;
          settings = aiOptions.settingsOption;
        };
      };
      aiOptions = import ../lib/ai-options.nix {inherit lib;};
    in
      evalModule [
        stubAiShared
        claudeModule
        {
          config = {
            ai = {
              claude.enable = true;
              skills.stack-fix = /tmp/test-stack-fix-skill;
              instructions.iso-rule = {
                text = "Isolation test body";
                paths = ["iso/**"];
                description = "Isolation fixture";
              };
              settings.model = "isolation-test-model";
            };
          };
        }
      ];
  ```

- [ ] **Step 3.2.2: Add adapter isolation checks**

  Add these new checks to the `in { ... }` export block:

  ```nix
    # ── Phase 2a adapter isolation tests ───────────────────────────
    phase2a-adapter-claude-isolation-enable = pkgs.runCommand "phase2a-adapter-claude-isolation-enable" {} ''
      ${
        if phase2aClaudeAdapterIsolation.config.programs.claude-code.enable
        then "echo ok > $out"
        else "echo 'FAIL: isolation adapter did not flip programs.claude-code.enable' >&2; exit 1"
      }
    '';

    phase2a-adapter-claude-isolation-skills = pkgs.runCommand "phase2a-adapter-claude-isolation-skills" {} ''
      ${
        if phase2aClaudeAdapterIsolation.config.programs.claude-code.skills ? stack-fix
        then "echo ok > $out"
        else "echo 'FAIL: isolation adapter did not dispatch skills through upstream' >&2; exit 1"
      }
    '';

    phase2a-adapter-claude-isolation-instruction = pkgs.runCommand "phase2a-adapter-claude-isolation-instruction" {} ''
      ${
        let
          fileAttrs = phase2aClaudeAdapterIsolation.config.home.file;
          hasFile = fileAttrs ? ".claude/rules/iso-rule.md";
          text =
            if hasFile
            then fileAttrs.".claude/rules/iso-rule.md".text
            else "";
          hasBody = lib.hasInfix "Isolation test body" text;
          hasFrontmatter = lib.hasInfix "Isolation fixture" text;
        in
          if hasFile && hasBody && hasFrontmatter
          then "echo ok > $out"
          else "echo 'FAIL: isolation adapter did not produce .claude/rules/iso-rule.md with expected content (hasFile=${toString hasFile}, hasBody=${toString hasBody}, hasFrontmatter=${toString hasFrontmatter})' >&2; exit 1"
      }
    '';

    phase2a-adapter-claude-isolation-settings = pkgs.runCommand "phase2a-adapter-claude-isolation-settings" {} ''
      ${
        if phase2aClaudeAdapterIsolation.config.programs.claude-code.settings.model == "isolation-test-model"
        then "echo ok > $out"
        else "echo 'FAIL: isolation adapter did not dispatch settings.model through upstream' >&2; exit 1"
      }
    '';
  ```

- [ ] **Step 3.2.3: Run the isolation checks**

  Run: `nix flake check 2>&1 | grep -E "phase2a-adapter|^error" | head -20`

  Expected: all 4 `phase2a-adapter-*` checks build successfully. No `error:` lines.

  **If any isolation check fails:** the adapter code is wrong. Read the failure message, compare against the expected behavior, and fix `lib/mk-ai-ecosystem-hm-module.nix`. Do NOT proceed to Commit 4 until isolation passes.

### Task 3.3: Commit the adapter + isolation tests

- [ ] **Step 3.3.1: Verify `nix flake check` fully passes**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors. All Phase 1 checks + the 22 safety-net checks from Commit 2 + the 4 isolation checks from this commit all passing.

- [ ] **Step 3.3.2: Stage and commit**

  Run:
  ```bash
  git add lib/mk-ai-ecosystem-hm-module.nix checks/module-eval.nix
  git commit -m "$(cat <<'EOF'
  feat(lib): add mk-ai-ecosystem-hm-module adapter

  Introduces lib/mk-ai-ecosystem-hm-module.nix — the HM backend
  adapter that consumes ecosystem records created in Phase 1 and
  produces NixOS modules with options + fanout config blocks.

  The adapter:
    - Declares options.ai.<name> with enable, package, and any
      extra options from ecoRecord.extraOptions (e.g., claude.buddy)
    - Renders instructions via ecoRecord.markdownTransformer through
      fragmentsLib.mkRenderer
    - Dispatches translated values through upstream HM option paths
      (programs.<cli>.skills, programs.<cli>.settings, etc.) when
      ecoRecord.upstream.hm.<category>Option is non-null, falling
      back to home.file writes when null
    - Preserves the per-ecosystem special cases from the existing
      inline fanout: claude writes instructions to home.file
      directly, copilot/kiro delegate to programs.<cli>.instructions
      and programs.<cli>.steering, lspServers still use the
      existing mkLspConfig/mkCopilotLspConfig helpers from
      lib/ai-common.nix, buddy fanout is claude-specific

  Phase 2a scope: no layered option pools yet — the adapter reads
  from the shared ai.* options directly. Phase 2b will add
  ai.<eco>.<category> extension points.

  Not yet wired into modules/ai/default.nix. Commit 4 replaces the
  Claude inline block with mkAdapter claudeRecord, Commits 5 and 6
  do the same for copilot and kiro.

  Adds 4 adapter isolation tests to checks/module-eval.nix that
  exercise the adapter standalone (with a stub ai-shared-options
  module) against the claude record. Isolation tests verify enable
  propagation, skills fanout, instruction rendering + placement,
  and settings key dispatch.

  Phase 2a commit 3 of 7.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -4
  ```

  Expected: new commit with subject `feat(lib): add mk-ai-ecosystem-hm-module adapter`.

---

## Commit 4: Replace Claude inline fanout with adapter

**Purpose:** Remove the inline `mkIf cfg.claude.enable` block and the `options.ai.claude` submodule declaration from `modules/ai/default.nix`. Replace them with an import of the adapter-generated claude module. All 7 phase2a-claude safety-net tests from Commit 2 plus the 4 adapter isolation tests from Commit 3 plus the existing Phase 1 claude-related tests (aiSkillsFanout, aiWithSettings, aiBuddy, aiSelfContained) must still pass.

### Task 4.1: Remove the inline Claude option declaration

**Files:**
- Modify: `modules/ai/default.nix` (remove lines 65-89, the `claude = mkOption { ... };` block)

- [ ] **Step 4.1.1: Read the current Claude option block**

  Run: `sed -n '64,90p' modules/ai/default.nix`

  Confirm the block structure: `claude = mkOption { type = types.submodule { options = { enable; package; buddy; }; }; default = {}; description = "..."; };`

- [ ] **Step 4.1.2: Remove the inline Claude option block**

  Use Edit to replace:

  ```nix
    claude = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Claude Code";
          package = mkOption {
            type = types.package;
            default = pkgs.claude-code;
            defaultText = lib.literalExpression "pkgs.claude-code";
            description = "Claude Code package.";
          };
          buddy = mkOption {
            type = types.nullOr buddySubmodule;
            default = null;
            description = ''
              Buddy companion customization. When set, fans out to
              `programs.claude-code.buddy` which installs an
              activation script to patch the buddy salt at activation
              time. See modules/claude-code-buddy/ for details.
            '';
          };
        };
      };
      default = {};
      description = "Claude Code ecosystem configuration.";
    };
  ```

  with:

  ```nix
    # ai.claude options are now declared by the adapter-generated
    # module in the imports list. See
    # lib/mk-ai-ecosystem-hm-module.nix and
    # pkgs.fragments-ai.passthru.records.claude.
  ```

### Task 4.2: Remove the inline Claude fanout block

- [ ] **Step 4.2.1: Read the current Claude fanout block**

  Run: `sed -n '168,193p' modules/ai/default.nix`

  Confirm the block structure: `(mkIf cfg.claude.enable (mkMerge [ { programs.claude-code... home.file... } (mkIf cfg.lspServers != {} ...) (mkIf cfg.settings.model != null ...) (mkIf cfg.claude.buddy != null ...) ]))`

- [ ] **Step 4.2.2: Remove the inline Claude fanout block**

  Use Edit to replace the entire Claude fanout block:

  ```nix
      # Claude Code — ai.claude.enable is the sole gate. It also flips
      # programs.claude-code.enable so consumers don't set enable twice.
      (mkIf cfg.claude.enable (mkMerge [
        {
          programs.claude-code.enable = mkDefault true;
          programs.claude-code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
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
        (mkIf (cfg.lspServers != {}) {
          programs.claude-code.settings.env.ENABLE_LSP_TOOL = mkDefault "1";
        })
        # Normalized model setting
        (mkIf (cfg.settings.model != null) {
          programs.claude-code.settings.model = mkDefault cfg.settings.model;
        })
        # Buddy fanout — sets the canonical programs.claude-code.buddy
        (mkIf (cfg.claude.buddy != null) {
          programs.claude-code.buddy = cfg.claude.buddy;
        })
      ]))
  ```

  with:

  ```nix
      # Claude fanout is now handled by the adapter-generated module
      # imported via lib/mk-ai-ecosystem-hm-module.nix. See
      # pkgs.fragments-ai.passthru.records.claude for the per-ecosystem
      # policy (markdownTransformer, translators, layout, upstream).
  ```

### Task 4.3: Import the adapter-generated Claude module

- [ ] **Step 4.3.1: Update the `let` bindings in `modules/ai/default.nix`**

  The `let` block currently imports `lib/buddy-types.nix` to destructure `buddySubmodule`. Now that the claude option declaration is removed, `buddySubmodule` is no longer needed in this file (the adapter and the claude record handle the buddy type via `extraOptions`). However, removing the let binding is deferred to Commit 7's cleanup pass — for this commit, leave it and add the adapter import.

  Find the existing `let` block (lines 30-50). Add a new binding at the end of the `let` block, before the closing `in {`:

  ```nix
    mkAiEcosystemHmModule = import ../../lib/mk-ai-ecosystem-hm-module.nix {inherit lib;};
  ```

- [ ] **Step 4.3.2: Add the adapter-generated Claude module to `imports`**

  Find the `imports = [ ... ];` list (lines 58-62). It currently reads:

  ```nix
    imports = [
      ../claude-code-buddy
      ../copilot-cli
      ../kiro-cli
    ];
  ```

  Update it to:

  ```nix
    imports = [
      ../claude-code-buddy
      ../copilot-cli
      ../kiro-cli
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.claude)
    ];
  ```

### Task 4.4: Verify all tests pass

- [ ] **Step 4.4.1: Run Phase 2a safety-net tests**

  Run: `nix flake check 2>&1 | grep -E "phase2a-claude|^error"`

  Expected: all 7 `phase2a-claude-*` checks build successfully. No `error:` lines.

  **If any claude safety-net check fails:** the adapter drifts from the inline fanout behavior. Read the specific assertion, compare the actual vs expected values, and fix either `lib/mk-ai-ecosystem-hm-module.nix` (adapter bug) or `lib/ai-ecosystems/claude.nix` (record bug). Do NOT proceed until all 7 pass.

- [ ] **Step 4.4.2: Run Phase 1 claude-related tests**

  Run: `nix flake check 2>&1 | grep -E "aiSelfContained|aiSkillsFanout|aiWithSettings|aiBuddy|ai-self-contained|ai-skills-fanout|ai-with-settings|ai-buddy|ai-with-clis"`

  Expected: all Phase 1 ai-related checks still pass (the `runCommand` assertions all produce outputs).

- [ ] **Step 4.4.3: Run the full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors. Phase 1's `fragments-test-*` + Phase 2a's safety-net + Phase 2a's isolation tests + all existing ai module tests all passing.

- [ ] **Step 4.4.4: Verify byte-identical output against Phase 1 baseline**

  The `dev/generate.nix` path is independent of the ai HM module (it uses the fragments-ai passthru directly, not the module). But as a paranoia check:

  Run:
  ```bash
  rm -rf /tmp/phase2a-c4 && mkdir -p /tmp/phase2a-c4
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/phase2a-c4/$target"
  done
  find /tmp/phase2a-c4 -type f -exec sha256sum {} \; | sort | sed 's|/tmp/phase2a-c4/|/tmp/ai-records-baseline/|' > /tmp/phase2a-c4/HASHES_normalized
  diff <(grep -v 'HASHES$' /tmp/ai-records-baseline/HASHES) <(grep -v 'HASHES$' /tmp/phase2a-c4/HASHES_normalized)
  echo "exit: $?"
  ```

  Expected: empty diff, exit 0.

### Task 4.5: Commit the Claude replacement

- [ ] **Step 4.5.1: Stage and commit**

  Run:
  ```bash
  git add modules/ai/default.nix
  git commit -m "$(cat <<'EOF'
  refactor(ai): replace claude inline fanout with adapter

  Removes the inline claude mkOption submodule declaration (~25
  lines) and the mkIf cfg.claude.enable mkMerge fanout block (~25
  lines) from modules/ai/default.nix. Replaces them with an import
  of mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.claude
  in the imports list.

  The adapter reads the claude ecosystem record (markdownTransformer,
  translators, layout, upstream, extraOptions.buddy) and produces
  an equivalent options + config block. Safety-net assertions from
  Phase 2a commit 2 verify:
    - ai.claude.enable propagates to programs.claude-code.enable
    - ai.skills fans out to programs.claude-code.skills
    - ai.instructions renders to home.file.".claude/rules/<name>.md"
      with the correct frontmatter and body
    - ai.settings.model propagates to programs.claude-code.settings.model
    - ai.lspServers auto-enables settings.env.ENABLE_LSP_TOOL=1
    - ai.claude.buddy propagates to programs.claude-code.buddy

  All 7 phase2a-claude-* safety-net checks pass. All Phase 1
  checks (aiSelfContained, aiSkillsFanout, aiWithSettings, aiBuddy,
  fragments-test-*) continue passing. Byte-identical dev/generate.nix
  output preserved.

  Next: commit 5 does the same for copilot.

  Phase 2a commit 4 of 7.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -5
  ```

---

## Commit 5: Replace Copilot inline fanout with adapter

**Purpose:** Same pattern as Commit 4, applied to the Copilot branch. The 7 `phase2a-copilot-*` safety-net tests from Commit 2 plus existing Phase 1 copilot-related tests must still pass.

### Task 5.1: Remove the inline Copilot option declaration

- [ ] **Step 5.1.1: Read the current Copilot option block**

  Run: `sed -n '91,106p' modules/ai/default.nix`

  Confirm the block structure. Note: after Commit 4 removed the claude block, line numbers have shifted — use the actual content as the source of truth.

- [ ] **Step 5.1.2: Remove the inline Copilot option block**

  Use Edit to replace:

  ```nix
    copilot = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Copilot CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.github-copilot-cli;
            defaultText = lib.literalExpression "pkgs.github-copilot-cli";
            description = "Copilot CLI package.";
          };
        };
      };
      default = {};
      description = "Copilot CLI ecosystem configuration.";
    };
  ```

  with:

  ```nix
    # ai.copilot options are now declared by the adapter-generated
    # module in the imports list. See
    # lib/mk-ai-ecosystem-hm-module.nix and
    # pkgs.fragments-ai.passthru.records.copilot.
  ```

### Task 5.2: Remove the inline Copilot fanout block

- [ ] **Step 5.2.1: Read the current Copilot fanout block**

  Run: `grep -n 'cfg.copilot.enable' modules/ai/default.nix`

  Find the line number of the copilot fanout block.

- [ ] **Step 5.2.2: Remove the inline Copilot fanout block**

  Use Edit to replace:

  ```nix
      # Copilot CLI — ai.copilot.enable also flips programs.copilot-cli.enable.
      (mkIf cfg.copilot.enable {
        programs.copilot-cli = {
          enable = mkDefault true;
          environmentVariables =
            lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
          instructions = lib.mapAttrs (_name: instr:
            mkDefault (aiTransforms.copilot instr))
          cfg.instructions;
          lspServers = lib.mapAttrs (name: server:
            mkDefault (mkCopilotLspConfig name server))
          cfg.lspServers;
          settings = lib.optionalAttrs (cfg.settings.model != null) {
            model = mkDefault cfg.settings.model;
          };
          skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        };
      })
  ```

  with:

  ```nix
      # Copilot fanout is now handled by the adapter-generated module
      # imported via lib/mk-ai-ecosystem-hm-module.nix. See
      # pkgs.fragments-ai.passthru.records.copilot.
  ```

### Task 5.3: Add the adapter-generated Copilot module to `imports`

- [ ] **Step 5.3.1: Update the imports list**

  Find the `imports = [ ... ];` list. After Commit 4 it reads:

  ```nix
    imports = [
      ../claude-code-buddy
      ../copilot-cli
      ../kiro-cli
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.claude)
    ];
  ```

  Update to:

  ```nix
    imports = [
      ../claude-code-buddy
      ../copilot-cli
      ../kiro-cli
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.claude)
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.copilot)
    ];
  ```

### Task 5.4: Verify all tests pass

- [ ] **Step 5.4.1: Run Phase 2a copilot safety-net tests**

  Run: `nix flake check 2>&1 | grep -E "phase2a-copilot|^error"`

  Expected: all 7 `phase2a-copilot-*` checks build successfully.

  **If any fails:** adapter drift on the copilot path. Read the assertion, debug, fix.

- [ ] **Step 5.4.2: Ensure claude tests still pass**

  Run: `nix flake check 2>&1 | grep -E "phase2a-claude|^error"`

  Expected: all 7 `phase2a-claude-*` checks still pass. Commit 4's work must not regress.

- [ ] **Step 5.4.3: Full flake check**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

### Task 5.5: Commit the Copilot replacement

- [ ] **Step 5.5.1: Stage and commit**

  Run:
  ```bash
  git add modules/ai/default.nix
  git commit -m "$(cat <<'EOF'
  refactor(ai): replace copilot inline fanout with adapter

  Removes the inline copilot mkOption submodule declaration and the
  mkIf cfg.copilot.enable fanout block from modules/ai/default.nix.
  Replaces them with an import of mkAiEcosystemHmModule
  pkgs.fragments-ai.passthru.records.copilot.

  Safety-net assertions from Phase 2a commit 2 verify:
    - ai.copilot.enable propagates to programs.copilot-cli.enable
    - ai.skills fans out to programs.copilot-cli.skills
    - ai.instructions renders to programs.copilot-cli.instructions
      with the correct applyTo frontmatter
    - ai.environmentVariables propagates
    - ai.settings.model propagates
    - ai.lspServers propagates via mkCopilotLspConfig

  All 7 phase2a-copilot-* checks pass, 7 phase2a-claude-* checks
  still pass, all existing Phase 1 ai checks still pass.

  Phase 2a commit 5 of 7.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -6
  ```

---

## Commit 6: Replace Kiro inline fanout with adapter

**Purpose:** Same pattern as Commits 4-5, applied to the Kiro branch. This is the LAST ecosystem replacement. All 8 `phase2a-kiro-*` safety-net tests must pass, and all previous safety-net + Phase 1 tests must continue passing.

### Task 6.1: Remove the inline Kiro option declaration

- [ ] **Step 6.1.1: Read the current Kiro option block**

  Run: `grep -n 'kiro = mkOption' modules/ai/default.nix`

- [ ] **Step 6.1.2: Remove the inline Kiro option block**

  Use Edit to replace:

  ```nix
    kiro = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Kiro CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.kiro-cli;
            defaultText = lib.literalExpression "pkgs.kiro-cli";
            description = "Kiro CLI package.";
          };
        };
      };
      default = {};
      description = "Kiro CLI ecosystem configuration.";
    };
  ```

  with:

  ```nix
    # ai.kiro options are now declared by the adapter-generated
    # module in the imports list. See
    # lib/mk-ai-ecosystem-hm-module.nix and
    # pkgs.fragments-ai.passthru.records.kiro.
  ```

### Task 6.2: Remove the inline Kiro fanout block

- [ ] **Step 6.2.1: Remove the inline Kiro fanout block**

  Use Edit to replace:

  ```nix
      # Kiro CLI — ai.kiro.enable also flips programs.kiro-cli.enable.
      (mkIf cfg.kiro.enable {
        programs.kiro-cli = {
          enable = mkDefault true;
          environmentVariables =
            lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
          lspServers = lib.mapAttrs (name: server:
            mkDefault (mkLspConfig name server))
          cfg.lspServers;
          settings = mkMerge [
            (lib.optionalAttrs (cfg.settings.model != null) {
              chat.defaultModel = mkDefault cfg.settings.model;
            })
            (lib.optionalAttrs (cfg.settings.telemetry != null) {
              telemetry.enabled = mkDefault cfg.settings.telemetry;
            })
          ];
          skills = lib.mapAttrs (_: mkDefault) cfg.skills;
          steering = lib.mapAttrs (name: instr:
            mkDefault (aiTransforms.kiro {inherit name;} instr))
          cfg.instructions;
        };
      })
  ```

  with:

  ```nix
      # Kiro fanout is now handled by the adapter-generated module
      # imported via lib/mk-ai-ecosystem-hm-module.nix. See
      # pkgs.fragments-ai.passthru.records.kiro.
  ```

### Task 6.3: Add the adapter-generated Kiro module to `imports`

- [ ] **Step 6.3.1: Update the imports list**

  Update to include the kiro adapter:

  ```nix
    imports = [
      ../claude-code-buddy
      ../copilot-cli
      ../kiro-cli
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.claude)
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.copilot)
      (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.kiro)
    ];
  ```

### Task 6.4: Verify all tests pass

- [ ] **Step 6.4.1: Run Phase 2a kiro safety-net tests**

  Run: `nix flake check 2>&1 | grep -E "phase2a-kiro|^error"`

  Expected: all 8 `phase2a-kiro-*` checks build successfully. The critical one is `phase2a-kiro-settings-model-remap` which verifies `ai.settings.model` → `programs.kiro-cli.settings.chat.defaultModel` (the key remap that's structurally different from claude/copilot).

  **If the settings remap test fails:** the adapter's `settingsBlock` is not correctly dispatching through `ecoRecord.translators.settings` for the kiro case. Check that the kiro record's translator returns `{ chat.defaultModel = ...; telemetry.enabled = ...; }` and that `setUpstreamOption` for `programs.kiro-cli.settings` accepts nested keys.

- [ ] **Step 6.4.2: Ensure claude and copilot tests still pass**

  Run: `nix flake check 2>&1 | grep -E "phase2a-(claude|copilot)|^error"`

  Expected: all 14 earlier safety-net checks still pass.

- [ ] **Step 6.4.3: Full flake check**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

### Task 6.5: Commit the Kiro replacement

- [ ] **Step 6.5.1: Stage and commit**

  Run:
  ```bash
  git add modules/ai/default.nix
  git commit -m "$(cat <<'EOF'
  refactor(ai): replace kiro inline fanout with adapter

  Removes the inline kiro mkOption submodule declaration and the
  mkIf cfg.kiro.enable fanout block from modules/ai/default.nix.
  Replaces them with an import of mkAiEcosystemHmModule
  pkgs.fragments-ai.passthru.records.kiro.

  Safety-net assertions from Phase 2a commit 2 verify:
    - ai.kiro.enable propagates to programs.kiro-cli.enable
    - ai.skills fans out to programs.kiro-cli.skills
    - ai.instructions renders to programs.kiro-cli.steering with
      correct inclusion + fileMatchPattern frontmatter
    - ai.environmentVariables propagates
    - ai.settings.model REMAPS to programs.kiro-cli.settings.chat.defaultModel
      (the non-trivial key translation path)
    - ai.settings.telemetry REMAPS to programs.kiro-cli.settings.telemetry.enabled
    - ai.lspServers propagates via mkLspConfig

  All 8 phase2a-kiro-* checks pass. All 14 claude+copilot
  safety-net checks still pass. All existing Phase 1 ai checks
  still pass.

  Phase 2a now has THREE ecosystem records driving the HM module
  via the adapter. The adapter is the single source of fanout
  logic; modules/ai/default.nix retains only the shared option
  declarations, assertions, and the imports list.

  Commit 7 cleans up now-unused helpers in modules/ai/default.nix.

  Phase 2a commit 6 of 7.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -7
  ```

---

## Commit 7: Clean up now-unused helpers in `modules/ai/default.nix`

**Purpose:** After Commits 4-6, `modules/ai/default.nix` has several now-dead let-bindings, imports, and utility references. Remove them. The file should shrink from ~238 lines to ~80 lines, containing only the shared option declarations (skills, instructions, lspServers, environmentVariables, settings), the assertions block, and the imports list.

### Task 7.1: Remove unused let bindings

**Files:**
- Modify: `modules/ai/default.nix` (remove unused let bindings and imports)

- [ ] **Step 7.1.1: Identify unused bindings**

  Run:
  ```bash
  grep -n 'aiTransforms\|buddySubmodule\|concatMapAttrs\|mkCopilotLspConfig\|mkLspConfig\|aiCommon' modules/ai/default.nix
  ```

  After Commits 4-6, these names should only appear in the `let` block's destructuring. The inline fanout blocks that used them are gone. Phase 2b will migrate LSP handling to the adapter's translator (removing the direct `mkCopilotLspConfig`/`mkLspConfig` calls from the adapter); for Phase 2a they remain in the adapter.

  **Specifically remove from `modules/ai/default.nix`:**
  - `concatMapAttrs` from the `lib` destructuring (no longer used)
  - `buddySubmodule` and the `import ../../lib/buddy-types.nix` (no longer used; the adapter + claude record handle buddy via extraOptions)
  - `aiCommon = import ../../lib/ai-common.nix {inherit lib;};` (no longer used; the adapter imports ai-common directly)
  - `inherit (aiCommon) mkCopilotLspConfig mkLspConfig;` (no longer used)
  - `aiTransforms = pkgs.fragments-ai.passthru.transforms;` (no longer used)

- [ ] **Step 7.1.2: Apply the cleanup**

  Use Edit to update the `let` block from:

  ```nix
  {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit
      (lib)
      concatMapAttrs
      mkDefault
      mkEnableOption
      mkIf
      mkMerge
      mkOption
      optionals
      types
      ;

    aiCommon = import ../../lib/ai-common.nix {inherit lib;};
    aiOptions = import ../../lib/ai-options.nix {inherit lib;};
    inherit (aiCommon) mkCopilotLspConfig mkLspConfig;
    aiTransforms = pkgs.fragments-ai.passthru.transforms;

    inherit (import ../../lib/buddy-types.nix {inherit lib;}) buddySubmodule;

    mkAiEcosystemHmModule = import ../../lib/mk-ai-ecosystem-hm-module.nix {inherit lib;};

    cfg = config.ai;
  in {
  ```

  to:

  ```nix
  {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit
      (lib)
      mkMerge
      optionals
      ;

    aiOptions = import ../../lib/ai-options.nix {inherit lib;};
    mkAiEcosystemHmModule = import ../../lib/mk-ai-ecosystem-hm-module.nix {inherit lib;};

    cfg = config.ai;
  in {
  ```

### Task 7.2: Remove dead comment placeholders

- [ ] **Step 7.2.1: Remove the `ai.claude options are now declared...` placeholder comments**

  The replacement comments from Commits 4-6 served as progress markers during the refactor. Now that the refactor is complete, they're noise. Remove them.

  Find and delete:

  ```nix
    # ai.claude options are now declared by the adapter-generated
    # module in the imports list. See
    # lib/mk-ai-ecosystem-hm-module.nix and
    # pkgs.fragments-ai.passthru.records.claude.
  ```

  (and the corresponding copilot/kiro placeholder comments in the options block)

- [ ] **Step 7.2.2: Remove the `Claude fanout is now handled by...` placeholder comments**

  Find and delete:

  ```nix
      # Claude fanout is now handled by the adapter-generated module
      # imported via lib/mk-ai-ecosystem-hm-module.nix. See
      # pkgs.fragments-ai.passthru.records.claude for the per-ecosystem
      # policy (markdownTransformer, translators, layout, upstream).
  ```

  (and the copilot/kiro analogs in the config block)

### Task 7.3: Update the top-of-file doc comment

- [ ] **Step 7.3.1: Update the module description**

  The top-of-file comment currently describes the inline fanout behavior that Phase 2a removed. Update it to reflect the adapter-driven architecture.

  Replace lines 1-24 of `modules/ai/default.nix`:

  ```nix
  # Unified AI configuration module.
  #
  # Single source of truth for shared config across Claude Code, Copilot CLI,
  # and Kiro CLI. Fans out to individual CLI modules via mkDefault so
  # per-CLI config always wins.
  #
  # Each ai.{claude,copilot,kiro}.enable is the SOLE gate for that CLI's
  # fanout — it also implicitly enables the corresponding upstream module
  # (programs.claude-code.enable, programs.copilot-cli.enable, etc.), so
  # consumers don't need to set enable twice. There is no master ai.enable
  # switch; enabling at least one ecosystem sub-option is the activation.
  #
  # Usage:
  #   ai = {
  #     claude.enable = true;   # also sets programs.claude-code.enable
  #     copilot.enable = true;  # also sets programs.copilot-cli.enable
  #     kiro.enable = true;     # also sets programs.kiro-cli.enable
  #     skills = { stack-fix = ./skills/stack-fix; };
  #     instructions.coding-standards = {
  #       text = "Always use strict mode...";
  #       paths = [ "src/**" ];
  #       description = "Project coding standards";
  #     };
  #   };
  ```

  with:

  ```nix
  # Unified AI configuration module.
  #
  # Single source of truth for shared config across Claude Code, Copilot CLI,
  # and Kiro CLI. Per-ecosystem fanout is driven by ecosystem records
  # (lib/ai-ecosystems/<name>.nix, accessed via
  # pkgs.fragments-ai.passthru.records.<name>) and the HM adapter
  # (lib/mk-ai-ecosystem-hm-module.nix). This file contains only:
  #   - Shared option declarations (ai.skills, ai.instructions,
  #     ai.lspServers, ai.environmentVariables, ai.settings)
  #   - Cross-ecosystem assertions
  #   - The imports list that pulls in both the per-ecosystem upstream
  #     HM modules (programs.claude-code, programs.copilot-cli,
  #     programs.kiro-cli via claude-code-buddy, copilot-cli, kiro-cli
  #     module directories) and the adapter-generated modules (one per
  #     ecosystem record).
  #
  # Each ai.{claude,copilot,kiro}.enable is the sole gate for that
  # ecosystem's fanout — it also implicitly enables the corresponding
  # upstream module via the adapter's mkDefault on
  # programs.<cli>.enable. There is no master ai.enable switch.
  #
  # Adding a new ecosystem to ai.* is now:
  #   1. Create lib/ai-ecosystems/<name>.nix with a complete record
  #   2. Add the record to pkgs.fragments-ai.passthru.records
  #      (via packages/fragments-ai/default.nix)
  #   3. Add (mkAiEcosystemHmModule pkgs.fragments-ai.passthru.records.<name>)
  #      to this file's imports list
  # No per-ecosystem fanout code changes to this file needed.
  #
  # Usage:
  #   ai = {
  #     claude.enable = true;
  #     copilot.enable = true;
  #     kiro.enable = true;
  #     skills = { stack-fix = ./skills/stack-fix; };
  #     instructions.coding-standards = {
  #       text = "Always use strict mode...";
  #       paths = [ "src/**" ];
  #       description = "Project coding standards";
  #     };
  #   };
  ```

### Task 7.4: Verify the cleaned-up module still works

- [ ] **Step 7.4.1: Run all Phase 2a safety-net tests**

  Run: `nix flake check 2>&1 | grep -E "phase2a-|^error"`

  Expected: all 22 safety-net tests + 4 adapter isolation tests still pass.

- [ ] **Step 7.4.2: Run all Phase 1 ai tests**

  Run: `nix flake check 2>&1 | grep -E "ai-|fragments-test-|^error"`

  Expected: all Phase 1 ai module tests + fragments tests still pass.

- [ ] **Step 7.4.3: Full flake check**

  Run: `nix flake check 2>&1 | tail -10`

  Expected: no errors.

- [ ] **Step 7.4.4: Verify the file shrinkage**

  Run: `wc -l modules/ai/default.nix`

  Expected: ~80-100 lines (down from 238 in Phase 1). The shared options + assertions + imports list should be the bulk of the file.

- [ ] **Step 7.4.5: Verify byte-identical dev/generate.nix output**

  Run:
  ```bash
  rm -rf /tmp/phase2a-final && mkdir -p /tmp/phase2a-final
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/phase2a-final/$target"
  done
  find /tmp/phase2a-final -type f -exec sha256sum {} \; | sort | sed 's|/tmp/phase2a-final/|/tmp/ai-records-baseline/|' > /tmp/phase2a-final/HASHES_normalized
  diff <(grep -v 'HASHES$' /tmp/ai-records-baseline/HASHES) <(grep -v 'HASHES$' /tmp/phase2a-final/HASHES_normalized)
  echo "exit: $?"
  ```

  Expected: empty diff, exit 0. `dev/generate.nix` is independent of the ai HM module, so output should be unchanged from Phase 1.

### Task 7.5: Commit the cleanup

- [ ] **Step 7.5.1: Stage and commit**

  Run:
  ```bash
  git add modules/ai/default.nix
  git commit -m "$(cat <<'EOF'
  refactor(ai): remove dead let bindings after adapter rollout

  Cleans up modules/ai/default.nix after commits 4-6 removed the
  three per-ecosystem inline fanout blocks. Removes now-unused:
    - concatMapAttrs (from the lib destructuring)
    - aiCommon import and mkCopilotLspConfig/mkLspConfig inherit
      (the adapter imports ai-common.nix directly)
    - aiTransforms binding (the adapter uses mkRenderer directly
      via the record's markdownTransformer)
    - buddySubmodule inherit and the buddy-types.nix import
      (the claude record's extraOptions handles buddy via its own
      import)
    - mkDefault, mkEnableOption, mkIf, mkOption, types from lib
      destructuring (no longer referenced after the inline option
      blocks were removed — the adapter declares its own options)
    - Transition placeholder comments from commits 4-6

  Updates the top-of-file doc comment to describe the
  adapter-driven architecture and document the "add a new
  ecosystem" workflow.

  modules/ai/default.nix shrinks from 238 lines to ~80 lines,
  containing only:
    - Shared option declarations from lib/ai-options.nix
    - Cross-ecosystem assertions (shared-config-requires-enabled,
      claude buddy validations)
    - The imports list: three upstream HM modules + three
      adapter-generated modules

  All 22 phase2a safety-net tests + 4 adapter isolation tests +
  all Phase 1 ai tests + all fragments tests pass.
  Byte-identical dev/generate.nix output preserved.

  Phase 2a commit 7 of 7 — adapter rollout complete.

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  git log --oneline -8
  ```

---

## Final verification

After all seven commits land, run end-to-end checks before declaring Phase 2a complete.

- [ ] **Step F.1: Full `nix flake check`**

  Run: `nix flake check 2>&1 | tail -20`

  Expected: no errors.

- [ ] **Step F.2: Count safety-net checks**

  Run: `nix flake check 2>&1 | grep -c 'phase2a-'`

  Expected: 26 (22 safety-net + 4 adapter isolation).

- [ ] **Step F.3: Verify all Phase 1 checks still pass**

  Run: `nix flake check 2>&1 | grep -c 'fragments-test-'`

  Expected: 14 (the Phase 1 golden tests).

- [ ] **Step F.4: Verify `modules/ai/default.nix` shrank to the target size**

  Run: `wc -l modules/ai/default.nix`

  Expected: 80-100 lines.

- [ ] **Step F.5: Verify all three ecosystem adapters are in the imports list**

  Run: `grep -c 'mkAiEcosystemHmModule' modules/ai/default.nix`

  Expected: 4 (1 let binding + 3 import invocations).

- [ ] **Step F.6: Byte-identical dev/generate.nix output against Phase 1 baseline**

  Run:
  ```bash
  rm -rf /tmp/phase2a-final-verify && mkdir -p /tmp/phase2a-final-verify
  for target in instructions-agents instructions-claude instructions-copilot instructions-kiro repo-readme repo-contributing; do
    out=$(nix build ".#$target" --no-link --print-out-paths 2>/dev/null) || { echo "FAIL: $target"; exit 1; }
    cp -r "$out" "/tmp/phase2a-final-verify/$target"
  done
  find /tmp/phase2a-final-verify -type f -exec sha256sum {} \; | sort | sed 's|/tmp/phase2a-final-verify/|/tmp/ai-records-baseline/|' > /tmp/phase2a-final-verify/HASHES_normalized
  diff <(grep -v 'HASHES$' /tmp/ai-records-baseline/HASHES) <(grep -v 'HASHES$' /tmp/phase2a-final-verify/HASHES_normalized)
  echo "exit: $?"
  ```

  Expected: empty diff, exit 0.

- [ ] **Step F.7: Merge-base anchor unchanged**

  Run: `git merge-base refactor/ai-ecosystem-records sentinel/monorepo-plan`

  Expected: `31590a37df86af0c65d14185b598558d6ed2899a`.

- [ ] **Step F.8: Refactor branch has 7 new commits from Phase 2a**

  Run: `git log --oneline 8d5d9c4..refactor/ai-ecosystem-records`

  Expected: 7 commits listed in reverse order:
  - `<hash> refactor(ai): remove dead let bindings after adapter rollout`
  - `<hash> refactor(ai): replace kiro inline fanout with adapter`
  - `<hash> refactor(ai): replace copilot inline fanout with adapter`
  - `<hash> refactor(ai): replace claude inline fanout with adapter`
  - `<hash> feat(lib): add mk-ai-ecosystem-hm-module adapter`
  - `<hash> test(ai): add phase 2a safety-net assertions for inline fanout`
  - `<hash> refactor(generate): rename composedByPkg to composedByPackage`

---

## Phase 2a complete — what's next

After this plan lands, the HM ai module is driven entirely by ecosystem records via the adapter. The per-ecosystem fanout logic lives in `lib/mk-ai-ecosystem-hm-module.nix` (single dispatch point) and `lib/ai-ecosystems/<name>.nix` (per-ecosystem policy). Adding a new ecosystem is a 3-step process with no touching of `modules/ai/default.nix`'s config block.

**Phase 2b (next plan): Layered option pools.**
- Extend `lib/mk-ai-ecosystem-hm-module.nix` to declare per-ecosystem option extension points (`ai.<eco>.skills`, `ai.<eco>.instructions`, `ai.<eco>.mcpServers`, etc.) using the shared option types from `lib/ai-options.nix`
- Implement the `recursiveUpdate shared per-eco` merge semantics
- Add tests for layered behavior: `ai.kiro.mcpServers.aws = ...` adds AWS only to Kiro, not Claude
- Migrate `lspServers` from the direct `mkCopilotLspConfig`/`mkLspConfig` calls in the adapter to the ecosystem record's `translators.lspServer` function (consolidates the per-ecosystem dispatch)
- Clean up the `instructionsBlock` per-ecosystem-name switch by making it a generic dispatch through `ecoRecord.upstream.hm.instructionsOption` (add that field to the records + Phase 1 scaffolding)

**Phase 3 (later plan): devenv adapter + helpers.**
- Mirror Phase 2a + 2b in `modules/devenv/ai.nix` via `lib/mk-ai-ecosystem-devenv-module.nix`
- Introduce `lib/mk-raw-ecosystem.nix`
- Add `examples/external-ecosystem/` worked example

**Phase 4 (later plan): doc ecosystems + fragment refresh.**
- README and mdBook ecosystem records in `packages/fragments-docs/ecosystems/`
- Update architecture fragments to document the new pattern

To draft Phase 2b: re-invoke the writing-plans skill with this plan's "Out of scope" section as the starting input.
