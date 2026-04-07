# Architecture Foundation Batch Implementation Plan (2026-04-08)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land three independent TOP-priority architecture cleanups
in one session: (1) make `homeManagerModules.ai` self-contained
so consumers need only one import, (2) reduce always-loaded
steering content from ~27k tokens to ~5-7k, and (3) finish the
overlay cache-hit parity fix so consumers actually hit
`nix-agentic-tools.cachix.org` instead of rebuilding from source.

**Architecture:** Three independent phases, each touching a
distinct surface area. Phase 1 is a single-file change with a
module-eval regression test. Phase 2 reshapes `dev/generate.nix`
to stop triple-loading orientation content and audits the
`monorepo` fragment list for moveable content. Phase 3 threads
`inputs` through each overlay composition layer and switches
every compiled package to `ourPkgs = import inputs.nixpkgs {
... }`, landing one group at a time (Rust → npm → Python → Go →
AI CLIs) with per-package store-path verification.

**Tech Stack:** Nix module system, home-manager, `lib.evalModules`
for tests, `nixosOptionsDoc`, `builtins.readDir`, `pkgs.runCommand`,
`fragments-ai` transforms, cachix narinfo lookups.

---

## Required reading (in order)

Before starting any phase, read these to understand the
constraints and the state of the codebase:

1. **`docs/plan.md` lines 63-150** — current TOP priority backlog
   including the three items this plan closes.
2. **`dev/notes/overlay-cache-hit-parity-fix.md`** — complete
   long-form spec for Phase 3, including the before/after
   transformation example for `git-branchless.nix`, threading
   changes for `packages/*/default.nix`, and the verification
   protocol.
3. **`dev/fragments/overlays/cache-hit-parity.md`** — condensed
   architecture fragment Phase 3 updates.
4. **`dev/fragments/hm-modules/module-conventions.md`** — module
   conventions including the "activation exit" and "Nix path
   types" warnings from commit `feeb5fb`. Auto-loads when editing
   HM modules.
5. **`modules/ai/default.nix`** — Phase 1's target file. No
   `imports` field currently; it references
   `programs.{copilot-cli,kiro-cli}.*` and
   `programs.claude-code.buddy` unconditionally inside mkIf
   blocks.
6. **`dev/generate.nix`** — Phase 2's target file. Focus on
   `agentsContent` (~236-247), `claudeFiles` (~250-260), `claudeMd`
   (~299-305), and `devFragmentNames.monorepo` (~171-182).

---

## Working conventions

- **Branch:** `sentinel/monorepo-plan` (additive commits, no
  rebase, no amend).
- **Commit convention:** Conventional Commits with lowercase
  imperative subject, Co-Authored-By footer on every commit.
- **Tool preferences:** Read/Edit/Glob/Grep over bash variants.
  Bash only for `nix`, `git`, `treefmt`, `devenv tasks run`, and
  the verification scripts in Phase 3.
- **Formatting:** After editing any file, run `treefmt <file>`
  before committing.
- **Regenerate steering files** after editing any `dev/fragments/`
  content: `devenv tasks run --mode before generate:instructions`.
- **Never push until a phase is user-reviewed.** The user will
  review each phase's commits before the next phase starts.

---

## Phase 1: `homeManagerModules.ai` imports its deps

**Scope:** Make `modules/ai/default.nix` a single-import entry
point by adding `imports = [../claude-code-buddy ../copilot-cli
../kiro-cli];`. Consumers currently have to register four
surgical HM modules (see nixos-config flake.nix lines 294-297
prior to cleanup). After this phase they register one.

**Why this is phase 1:** smallest surface, immediate consumer
win, exercises the module-eval harness without touching any
generation pipeline code.

### Task 1: Add a failing module-eval test for surgical `ai` import

**Files:**

- Modify: `checks/module-eval.nix` (add test alongside
  `aiDisabled`, `aiWithClis`, etc.)

**Steps:**

- [ ] **Step 1: Add the failing test binding.** Inside the `let`
      block of `checks/module-eval.nix`, after the existing
      `aiSkillsFanout` binding, add:

```nix
  # Test: homeManagerModules.ai is self-contained — importing
  # only the ai module (not the full default bundle) should
  # still declare the programs.{copilot-cli,kiro-cli}.* and
  # programs.claude-code.buddy option paths that ai.nix
  # references unconditionally inside its mkIf blocks.
  aiSelfContained = evalModule [
    self.homeManagerModules.ai
    {
      config = {
        ai = {
          copilot.enable = true;
          kiro.enable = true;
        };
      };
    }
  ];
```

- [ ] **Step 2: Add the output derivation.** In the returned
      attrset at the bottom of the file, after
      `ai-skills-fanout-eval`, add:

```nix
  ai-self-contained-eval = pkgs.runCommand "ai-self-contained-eval" {} ''
    ${
      if
        aiSelfContained.config.programs.copilot-cli.enable
        && aiSelfContained.config.programs.kiro-cli.enable
      then "echo ok > $out"
      else "echo 'FAIL: ai module not self-contained — importing homeManagerModules.ai alone did not bring in copilot-cli/kiro-cli modules' >&2; exit 1"
    }
  '';
```

- [ ] **Step 3: Verify the check fails against current code.**

```bash
nix build .#checks.x86_64-linux.ai-self-contained-eval 2>&1 | tail -15
```

      Expected: evaluation error about
      `programs.copilot-cli.enable` not being a declared option
      (since `homeManagerModules.ai` doesn't import `copilot-cli`
      yet). This is the TDD red state.

### Task 2: Add `imports` to the ai module

**Files:**

- Modify: `modules/ai/default.nix` (top-level, add `imports`
  attribute before `options.ai`)

**Steps:**

- [ ] **Step 1: Read the current module shape** to confirm where
      `imports` should go. The module currently starts with
      `options.ai = { ... }` around line 57. `imports` goes
      ABOVE options, as a top-level attribute alongside
      `options` and `config`.

- [ ] **Step 2: Add the imports field.** Edit
      `modules/ai/default.nix`. Insert immediately after the
      final `in {` line (around line 56 — right before
      `options.ai = {`):

```nix
  # Pull in the HM modules this one references inside its mkIf
  # blocks. Without these imports, consumers importing only
  # `homeManagerModules.ai` get eval errors like
  # "programs.copilot-cli.enable is not a declared option"
  # because NixOS modules need option paths declared even when
  # the mkIf guard is false.
  imports = [
    ../claude-code-buddy
    ../copilot-cli
    ../kiro-cli
  ];

```

      Leave one blank line after the closing `];` so
      `options.ai = {` is visually separated.

- [ ] **Step 3: Run the failing check — expect PASS.**

```bash
nix build .#checks.x86_64-linux.ai-self-contained-eval
```

      Expected: builds successfully. Output file contains `ok`.

- [ ] **Step 4: Run full flake check to catch regressions.**

```bash
nix flake check
```

      Expected: all checks pass. Pay particular attention to
      `aiDisabled`, `aiWithClis`, `aiBuddy`, and
      `aiWithSettings` — they should still pass, now exercising
      a slightly larger module set due to the new imports.

### Task 3: Commit

**Files:** None beyond Task 1 and 2.

**Steps:**

- [ ] **Step 1: Format the changed files.**

```bash
treefmt modules/ai/default.nix checks/module-eval.nix
```

- [ ] **Step 2: Stage and commit.**

```bash
git add modules/ai/default.nix checks/module-eval.nix
git commit -m "$(cat <<'EOF'
refactor(ai): self-contain dep imports for single-import consumers

modules/ai/default.nix references programs.copilot-cli.*,
programs.kiro-cli.*, and programs.claude-code.buddy inside
mkIf blocks. These references are evaluated even when the
guard is false (NixOS modules need the option paths declared),
so consumers importing only homeManagerModules.ai got eval
errors unless they manually imported copilot-cli, kiro-cli,
and claude-code-buddy HM modules alongside.

Real-world cost surfaced in nixos-config (2026-04-06):
flake.nix registered four surgical imports where one should
suffice. The workaround comment even said "Drop these and
switch to homeManagerModules.default once SWS is removed" —
but that's just papering over the missing imports.

Fix: add `imports = [../claude-code-buddy ../copilot-cli
../kiro-cli]` at the top of the ai module so the option paths
it references are always declared.

Adds aiSelfContained module-eval check (only imports
homeManagerModules.ai, expects programs.{copilot-cli,kiro-cli}
.enable to be true). Prevents regression where someone
removes an import without noticing the downstream reference.

Consumers can now drop the surgical
`nix-agentic-tools-{claude-code-buddy,copilot-cli,kiro-cli}`
entries from their homeManagerModules attrset — the single
`nix-agentic-tools.homeManagerModules.ai` import brings
everything needed.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: Consumer verification (user-run, not subagent-run)

**Files:** None in this repo. Tests run against
`~/Documents/projects/nixos-config`.

- [ ] **Step 1: User bumps the flake input.** Inform the user
      to run, in nixos-config:

```bash
cd ~/Documents/projects/nixos-config
nix flake update nix-agentic-tools
```

- [ ] **Step 2: User tries removing the redundant surgical
      import.** The nixos-config `flake.nix` now has:

```nix
homeManagerModules = (import ./modules/home-manager) // {
  nix-agentic-tools = inputs.nix-agentic-tools.homeManagerModules.default;
  # ... other consumer-specific modules ...
};
```

      Already using `default` bundle, so no surgical imports
      left to drop. Verification just needs
      `home-manager switch` to succeed, proving the self-contained
      `ai` module option paths still resolve through the `default`
      bundle's transitive imports.

- [ ] **Step 3: User reports back.** Controller marks Phase 1
      complete and proceeds to Phase 2 if activation succeeds.

---

## Phase 2: Always-loaded content audit + dynamic loading fix

**Scope:** Reduce session-startup context load in this repo
from ~27k tokens (measured 2026-04-07) to ~5-7k by fixing three
cascading bugs in `dev/generate.nix`:

1. CLAUDE.md body duplicates AGENTS.md (which itself is loaded
   via `@AGENTS.md` import) and also duplicates `.claude/rules/
common.md` byte-for-byte. Triple-load.
2. AGENTS.md concatenates every scoped architecture fragment in
   addition to orientation content, bloating to ~19k tokens.
3. The `monorepo` always-loaded fragment category has 10
   fragments, ~390 lines, several of which only apply to
   specific files (binary-cache, platforms, naming-conventions,
   etc.).

**Why this is phase 2:** high-leverage for every future session,
but more exploratory than Phase 1 (requires measurement +
audit judgment calls). Should land between the mechanical
phases so the orientation context stays healthy for the Phase
3 work.

**Expected impact:** ~5x reduction in always-loaded tokens.
Verified after the fix by re-running the measurement script
from Task 1.

### Task 1: Baseline token measurement

**Files:**

- Create: `dev/scripts/measure-context.sh` (new helper script)

**Steps:**

- [ ] **Step 1: Write the measurement script.** Create
      `dev/scripts/measure-context.sh`:

```bash
#!/usr/bin/env bash
# Measure always-loaded steering token budget for each
# ecosystem. Runs from repo root. Token count is approximate
# (wc -w as a proxy — claude's tokenizer is different but
# word-count is proportional for English prose).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

cd "$(git rev-parse --show-toplevel)"

report() {
  local label=$1
  shift
  local total_lines=0
  local total_words=0
  for f in "$@"; do
    if [ -f "$f" ]; then
      lines=$(wc -l < "$f")
      words=$(wc -w < "$f")
      printf '  %-50s %5d lines  %6d words\n' "$f" "$lines" "$words"
      total_lines=$((total_lines + lines))
      total_words=$((total_words + words))
    else
      printf '  %-50s MISSING\n' "$f"
    fi
  done
  printf '  %-50s %5d lines  %6d words (total)\n' "== $label ==" "$total_lines" "$total_words"
  printf '\n'
}

echo "=== Always-loaded steering budget ==="
printf '\n'

report "Claude" \
  CLAUDE.md \
  .claude/rules/common.md

report "Copilot" \
  .github/copilot-instructions.md

report "Kiro" \
  .kiro/steering/common.md

report "AGENTS.md (Codex + flat consumers)" \
  AGENTS.md

echo "=== Source monorepo fragments (composed into common.md) ==="
printf '\n'
for f in dev/fragments/monorepo/*.md; do
  lines=$(wc -l < "$f")
  words=$(wc -w < "$f")
  printf '  %-60s %5d lines  %6d words\n' "$f" "$lines" "$words"
done
```

- [ ] **Step 2: Make it executable and run it.**

```bash
chmod +x dev/scripts/measure-context.sh
dev/scripts/measure-context.sh > /tmp/baseline-context.txt
cat /tmp/baseline-context.txt
```

      Expected: captures per-ecosystem always-loaded file sizes
      and each monorepo fragment's size. Save this as the
      pre-fix baseline for comparison after Task 5.

- [ ] **Step 3: Commit the helper script.**

```bash
treefmt dev/scripts/measure-context.sh
git add dev/scripts/measure-context.sh
git commit -m "$(cat <<'EOF'
chore(dev): add context budget measurement script

New helper at dev/scripts/measure-context.sh reports
per-ecosystem always-loaded file sizes (CLAUDE.md, AGENTS.md,
Copilot, Kiro) plus per-fragment sizes for the monorepo
always-loaded category. Used to measure the baseline before
the always-loaded dynamic-loading fix and verify the
reduction after.

Word count (via wc -w) is a proxy for token count — claude's
tokenizer is different but word-count is proportional for
English prose, and the goal is relative comparison not
absolute budget accounting.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2: Drop `common.md` generation (Bug 1 fix)

**Files:**

- Modify: `dev/generate.nix` (`claudeFiles` attrset,
  approximately line 250)

**Steps:**

- [ ] **Step 1: Read the current `claudeFiles` shape** at
      `dev/generate.nix:250-260` to understand exactly what
      lines to remove:

```nix
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
```

- [ ] **Step 2: Remove the `common.md` entry.** Edit
      `dev/generate.nix` to change the block to:

```nix
  claudeFiles =
    # Scoped rule files only. No common.md — the content is
    # already loaded via CLAUDE.md (which @-imports AGENTS.md).
    # A separate .claude/rules/common.md byte-identical to the
    # body was pure waste and triple-loaded orientation content.
    lib.concatMapAttrs (pkg: _: let
      composed = mkDevComposed pkg;
      pkgEco = mkEcosystemFile pkg;
    in {
      "${pkg}.md" = pkgEco.claude composed;
    })
    nonRootPackages;
```

- [ ] **Step 3: Regenerate instruction files.**

```bash
devenv tasks run --mode before generate:instructions:claude
```

      Expected: succeeds. Verify the file was removed:

```bash
ls .claude/rules/ | grep common.md || echo "removed (ok)"
```

      Expected: `removed (ok)`.

- [ ] **Step 4: Run full flake check.**

```bash
nix flake check
```

      Expected: passes.

- [ ] **Step 5: Commit.**

```bash
treefmt dev/generate.nix
git add dev/generate.nix
git commit -m "$(cat <<'EOF'
refactor(generate): drop .claude/rules/common.md generation

.claude/rules/common.md was byte-identical to CLAUDE.md's body,
which was itself duplicated in AGENTS.md (which CLAUDE.md
@-imports). At session start Claude Code loaded the same
orientation content THREE times: once via CLAUDE.md body, once
via the @AGENTS.md expansion inside CLAUDE.md, and once via the
always-loaded common.md scoped rule.

Drop the common.md entry from claudeFiles. Scoped rule files
stay — they auto-load based on path scopes. Orientation
content is still reached via CLAUDE.md -> @AGENTS.md.

This is Bug 1 of three in the "always-loaded content audit"
plan item. Bugs 2 (AGENTS.md flat concat) and 3 (monorepo
category bloat) land in follow-up commits.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: CLAUDE.md → minimal stub (Bug 1 fix continued)

**Files:**

- Modify: `dev/generate.nix` (`claudeMd` string,
  approximately line 299-305)

**Steps:**

- [ ] **Step 1: Read the current `claudeMd`** at
      `dev/generate.nix:299-305`:

```nix
  claudeMd = ''
    # CLAUDE.md

    @AGENTS.md

    ${rootComposed.text}
  '';
```

- [ ] **Step 2: Change it to a minimal stub.** Replace the
      block with:

```nix
  # CLAUDE.md is a one-liner that @-imports AGENTS.md. All
  # orientation content lives in AGENTS.md. Keeping CLAUDE.md
  # body content alongside the @AGENTS.md import would
  # double-load the content at every session start (the import
  # expansion plus the inline body).
  claudeMd = ''
    # CLAUDE.md

    @AGENTS.md
  '';
```

- [ ] **Step 3: Regenerate.**

```bash
devenv tasks run --mode before generate:instructions:claude
```

- [ ] **Step 4: Verify CLAUDE.md is now minimal.**

```bash
wc -l CLAUDE.md
head -5 CLAUDE.md
```

      Expected: 3-4 lines total. Contents should be just
      `# CLAUDE.md`, blank line, `@AGENTS.md`.

- [ ] **Step 5: Run flake check.**

```bash
nix flake check
```

- [ ] **Step 6: Commit.**

```bash
treefmt dev/generate.nix CLAUDE.md
git add dev/generate.nix CLAUDE.md
git commit -m "$(cat <<'EOF'
refactor(generate): CLAUDE.md becomes @AGENTS.md stub

CLAUDE.md was generated as "# CLAUDE.md\n\n@AGENTS.md\n\n" plus
the full body content. At load time Claude Code follows the
@-import AND reads the body content, so the orientation
material landed twice. Previous commit removed the .claude/
rules/common.md triple-load; this commit removes the CLAUDE.md
double-load by trimming its body.

claudeMd is now just "# CLAUDE.md\n\n@AGENTS.md\n". All
orientation content lives in AGENTS.md.

Part of the 3-bug "always-loaded content audit" fix.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: AGENTS.md = orientation only (Bug 2 fix)

**Files:**

- Modify: `dev/generate.nix` (`agentsContent` binding,
  approximately line 236-247)

**Steps:**

- [ ] **Step 1: Read the current `agentsContent`** at
      `dev/generate.nix:236-247`:

```nix
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
```

- [ ] **Step 2: Strip the per-package concatenation.** Replace
      with:

```nix
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
```

- [ ] **Step 3: Add a pointer to the deep-dives** inside the
      AGENTS.md header body (still in `dev/generate.nix`).
      Find the `agentsMd = ''` block at approximately line
      289-297:

```nix
  agentsMd = ''
    # AGENTS.md

    Project instructions for AI coding assistants working in this repository.
    Read by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that
    support the [AGENTS.md standard](https://agents.md).

    ${agentsContent}
  '';
```

      Replace with:

```nix
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
```

- [ ] **Step 4: Regenerate and measure.**

```bash
devenv tasks run --mode before generate:instructions:agents generate:instructions:claude
wc -l AGENTS.md CLAUDE.md
```

      Expected: AGENTS.md drops from ~1870 lines to ~390 lines
      (orientation only). CLAUDE.md stays at ~3 lines.

- [ ] **Step 5: Run flake check + baseline comparison.**

```bash
nix flake check
dev/scripts/measure-context.sh > /tmp/after-bugs-1-2.txt
diff /tmp/baseline-context.txt /tmp/after-bugs-1-2.txt
```

      Expected: every ecosystem's always-loaded file shrinks
      by ~75%. Claude ecosystem drops from 392+387 to just
      ~3 lines (CLAUDE.md only; common.md removed).

- [ ] **Step 6: Commit.**

```bash
treefmt dev/generate.nix AGENTS.md
git add dev/generate.nix AGENTS.md
git commit -m "$(cat <<'EOF'
refactor(generate): AGENTS.md is orientation only, not flat concat

agentsContent was building AGENTS.md as rootComposed.text
PLUS a flat concatenation of every per-package scoped fragment
(claude-code-wrapper, buddy-activation, ai-module-fanout,
ai-skills, devenv-files, hm-modules, overlays, pipeline, etc.).
The result was 1870 lines / ~19k tokens of content loaded at
every session start, 95% of which was irrelevant to any given
edit.

Since agents.md has no scoping primitive, the previous
generator chose to dump everything. This commit picks the
other horn: AGENTS.md is orientation only (the monorepo
category fragments — project overview, build commands,
conventions). Deep-dive architecture fragments stay available
via:

- `.claude/rules/<name>.md`       (path-scoped, Claude)
- `.github/instructions/<name>.*` (applyTo, Copilot)
- `.kiro/steering/<name>.md`      (fileMatch, Kiro)
- mdbook contributing/architecture section (human-facing)

Adds a pointer in the AGENTS.md header explaining where
deep-dive docs live for Codex / generic agents.md consumers
that don't have scoped loading.

Expected reduction: AGENTS.md ~1870 → ~390 lines. Combined
with the CLAUDE.md/common.md fixes (previous two commits),
the Claude ecosystem always-loaded budget drops from
~27k tokens to ~5-7k.

Part of the 3-bug "always-loaded content audit" fix.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: Monorepo fragment audit (Bug 3 fix)

**Scope:** The `monorepo` category has 10 fragments composed
into every ecosystem's always-loaded file. Several don't
need always-loaded status. Re-scope them to specific code
paths.

**Files:**

- Modify: `dev/generate.nix` (`devFragmentNames.monorepo`
  approximately line 171-182, `packagePaths` approximately
  line 71-144)
- Possibly relocate: `dev/fragments/monorepo/*.md` source files
  (move to new category sub-directories if re-scoping)
- Modify: `flake.nix` `siteArchitecture` if any fragment
  gains/loses a docsite output path

**Steps:**

- [ ] **Step 1: Audit each monorepo fragment.** Read each file
      in `dev/fragments/monorepo/` and classify as "keep always"
      or "move to scoped category". The classification from
      docs/plan.md line 322-347:

      **Keep always-loaded:**
      - `architecture-fragments.md` (orientation + self-maintenance)
      - `project-overview.md` (what is this repo)
      - `build-commands.md` (universal)
      - `linting.md` (universal)
      - `change-propagation.md` (cross-cutting rule)

      **Move to scoped:**
      - `binary-cache.md` → scope to `flake.nix`, `devenv.nix`
        (files that touch `nixConfig` / cachix settings)
      - `platforms.md` → scope to `nvfetcher.toml`,
        `packages/**/sources.nix`, `packages/**/*.nix`
      - `naming-conventions.md` → scope to `packages/**`,
        `modules/**`
      - `nix-standards.md` → scope to `**/*.nix`
      - `generation-architecture.md` → scope to
        `dev/generate.nix`, `dev/tasks/**`, `flake.nix`
        (potentially merge with the existing `pipeline`
        category)

      If your audit disagrees with this classification, deviate
      but justify in the commit message.

- [ ] **Step 2: For each fragment being re-scoped, decide the
      target category.** You have two options:

      (a) Add to an existing category: e.g., `nix-standards`
      could go into `hm-modules` or a broader `nix` category.
      (b) Create a new category: e.g., `infra` for binary-cache
      + platforms, or `packaging` for naming-conventions +
      platforms.

      Create new categories ONLY if no existing one fits.
      Alphabetize and keep the list tidy.

      Recommended new categories (minimum churn):
      - `flake`: `binary-cache`, scoped to
        `["flake.nix" "devenv.nix"]`
      - `packaging`: `naming-conventions`, `platforms`, scoped
        to `["packages/**/*.nix" "nvfetcher.toml"]`
      - Keep `nix-standards` in `hm-modules` (broaden the
        `hm-modules` scope to include `**/*.nix`? No — too
        broad. Instead create `nix-standards` as its own
        category scoped to `["**/*.nix"]`.)
      - `generation-architecture` merge with existing
        `pipeline` category (add to `devFragmentNames.pipeline`
        as a bare string, keep existing scope).

- [ ] **Step 3: Update `devFragmentNames` and `packagePaths`.**
      For each relocated fragment, remove it from the
      `monorepo` array and add it to the target category's
      array. Update `packagePaths` with the new scope entry if
      creating a new category.

      Example snippet — create `flake` category for
      `binary-cache`:

```nix
  packagePaths = {
    # ... existing entries ...
    flake = ["flake.nix" "devenv.nix"];
    # ... rest ...
  };

  devFragmentNames = {
    # ... existing entries ...
    flake = ["binary-cache"];
    monorepo = [
      "architecture-fragments"
      "build-commands"
      "change-propagation"
      "linting"
      "project-overview"
      # binary-cache moved to flake category
      # generation-architecture moved to pipeline category
      # naming-conventions moved to packaging category
      # nix-standards moved to nix-standards category
      # platforms moved to packaging category
    ];
    # ... rest ...
  };
```

- [ ] **Step 4: Move fragment files if needed.** The
      `mkDevFragment` helper resolves based on the `location`
      discriminator. For the legacy `"dev"` location, the path
      is `dev/fragments/<dir>/<name>.md` where `<dir>` is the
      category key. So if you create a new category `flake`
      containing `binary-cache`, you either:

      (a) Leave the file at `dev/fragments/monorepo/binary-cache.md`
      and use the explicit `dir = "monorepo"` override:

```nix
  flake = [
    {
      location = "dev";
      name = "binary-cache";
      dir = "monorepo";
    }
  ];
```

      (b) Move the file to `dev/fragments/flake/binary-cache.md`
      (`git mv`) and keep the bare string form.

      Option (b) is cleaner. Use `git mv` for every relocated
      fragment and create the new category sub-directories as
      needed:

```bash
mkdir -p dev/fragments/flake dev/fragments/packaging dev/fragments/nix-standards
git mv dev/fragments/monorepo/binary-cache.md dev/fragments/flake/
git mv dev/fragments/monorepo/naming-conventions.md dev/fragments/packaging/
git mv dev/fragments/monorepo/platforms.md dev/fragments/packaging/
git mv dev/fragments/monorepo/nix-standards.md dev/fragments/nix-standards/
```

      For `generation-architecture`, moving into the existing
      `pipeline` category means the file lives at
      `dev/fragments/pipeline/generation-architecture.md`:

```bash
mkdir -p dev/fragments/pipeline
git mv dev/fragments/monorepo/generation-architecture.md dev/fragments/pipeline/
```

- [ ] **Step 5: Update `flake.nix:siteArchitecture`** if any
      relocated fragment was referenced there. Grep for the
      fragment names:

```bash
grep -n 'binary-cache\|naming-conventions\|platforms\|nix-standards\|generation-architecture' flake.nix
```

      Expected: no matches (those fragments aren't currently
      in siteArchitecture). siteArchitecture lists only the
      cross-cutting architecture fragments, not the monorepo
      orientation ones. If this grep returns results, update
      the `cp ${./dev/fragments/...}` lines to the new paths.

- [ ] **Step 6: Regenerate and verify all three ecosystem
      outputs have the expected orientation content.**

```bash
devenv tasks run --mode before generate:instructions
```

      Verify `.claude/rules/` now contains the new category
      files (e.g., `flake.md`, `packaging.md`, `nix-standards.md`):

```bash
ls .claude/rules/
```

- [ ] **Step 7: Run final measurement and compare to baseline.**

```bash
dev/scripts/measure-context.sh > /tmp/after-audit.txt
diff /tmp/baseline-context.txt /tmp/after-audit.txt
```

      Expected: monorepo category file sizes drop significantly
      (roughly half the fragments moved out). Total always-loaded
      across ecosystems should be ~5-7k tokens.

- [ ] **Step 8: Run `nix flake check` + `devenv test`.**

```bash
nix flake check
devenv test
```

      `devenv test` is important here because the scoped fragment
      files are written via the module system and exercised by
      real activation.

- [ ] **Step 9: Commit.**

```bash
treefmt dev/generate.nix dev/fragments/
git add -A dev/generate.nix dev/fragments/ flake.nix
git commit -m "$(cat <<'EOF'
refactor(fragments): re-scope monorepo fragments to reduce always-load

Bug 3 of the 3-bug "always-loaded content audit". The monorepo
category had 10 fragments composing into every ecosystem's
always-loaded file (~390 lines / ~4k tokens). Several don't
need always-loaded status — they only apply when editing
specific files.

Re-scoped per the audit in docs/plan.md line 322-347:

Kept always-loaded (5):
- architecture-fragments (orientation + self-maintenance)
- build-commands (universal)
- change-propagation (cross-cutting rule)
- linting (universal)
- project-overview (what is this repo)

Moved to scoped categories (5):
- binary-cache      -> flake          (flake.nix, devenv.nix)
- generation-architecture -> pipeline (merged with existing)
- naming-conventions -> packaging    (packages/**, modules/**)
- nix-standards     -> nix-standards  (**/*.nix)
- platforms         -> packaging     (see above)

File relocations via `git mv` so history is preserved. Two
new category directories: `dev/fragments/flake/`,
`dev/fragments/packaging/`, `dev/fragments/nix-standards/`.
`packagePaths` gets matching entries.

Combined with the previous two commits (drop common.md, trim
CLAUDE.md, de-flatten AGENTS.md), the always-loaded budget
for this repo drops from ~27k tokens to roughly ~5-7k. Scoped
fragments load on demand when editing matching paths — the
per-edit total stays similar, but the constant cost every
session-start shrinks ~5x.

Verified via dev/scripts/measure-context.sh before/after diff.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6: Update architecture-fragments.md self-maintenance doc

**Files:**

- Modify: `dev/fragments/monorepo/architecture-fragments.md`

**Steps:**

- [ ] **Step 1: Read the current self-maintenance section.**
      This always-loaded fragment is the one that orients
      sessions on the fragment system. It may need updating
      to mention the new categories and the expanded
      `devFragmentNames` structure.

- [ ] **Step 2: Add a short note** (3-5 lines) documenting the
      "AGENTS.md = orientation, deep-dives = scoped" decision
      so future sessions understand why AGENTS.md doesn't
      contain the scoped fragments.

- [ ] **Step 3: Update the category list** if you added new
      categories in Task 5 (e.g., flake, packaging,
      nix-standards). Keep alphabetical.

- [ ] **Step 4: Bump the Last-verified marker** to today's
      date and "pending" for the commit hash (matching the
      Task 4 convention from the skills-fanout-fix plan).

- [ ] **Step 5: Regenerate and commit.**

```bash
devenv tasks run --mode before generate:instructions
treefmt dev/fragments/monorepo/architecture-fragments.md
git add dev/fragments/monorepo/architecture-fragments.md
git commit -m "$(cat <<'EOF'
docs(fragments): update architecture-fragments for re-scoped categories

Post-Bug 3 fix (previous commit): the monorepo always-loaded
set shrank from 10 to 5 fragments. The self-maintenance
architecture fragment needs to reflect:

1. The new category list including flake, packaging,
   nix-standards (if created in the audit task).
2. The "AGENTS.md = orientation only, deep-dives via scoped
   files" decision so future sessions know where to look.

Also bumps the Last-verified marker.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: Overlay cache-hit parity fix

**Scope:** Every compiled overlay package in
`packages/{git-tools,mcp-servers,ai-clis}/` must instantiate its
own `ourPkgs = import inputs.nixpkgs { ... }` and use `ourPkgs.*`
for all build inputs. Currently they use `final.*` / `prev.*`
which binds to the consumer's nixpkgs pin, causing store-path
drift against CI's standalone builds → cache miss on every
consumer rebuild.

**Why this is phase 3:** broadest surface (22 package files) but
mostly mechanical once the pattern is established. Comes last
because it's the longest phase and benefits from the steady
hand after the focused phases 1 and 2.

**Reference:** `dev/notes/overlay-cache-hit-parity-fix.md` has
the full before/after example and verification protocol. Read
it before starting.

**Out of scope:** `packages/{coding-standards,fragments-ai,
fragments-docs,stacked-workflows}/` — content-only packages with
no compiled inputs. Skip entirely.

### Task 1: Add a failing cache-hit parity flake check

**Files:**

- Create: `checks/cache-hit-parity.nix`
- Modify: `flake.nix` (register the new check file alongside
  existing `moduleChecks`/`devshellChecks`)

**Steps:**

- [ ] **Step 1: Write the check module.** Create
      `checks/cache-hit-parity.nix`:

```nix
# Cache-hit parity check — verifies that overlay packages
# evaluate to the same store path when built standalone (as
# CI does) vs through a consumer's pkgs set (how consumers
# actually get them). Drift means the cachix substituter
# won't serve the consumer.
#
# The check works by comparing:
#   A) `self.packages.${system}.<pkg>` — the standalone path
#      that CI builds and pushes to cachix
#   B) An eval that applies `self.overlays.default` to a fresh
#      `import inputs.nixpkgs` — simulates what a consumer gets
#
# If A and B differ for any package, the consumer build will
# miss the cache. Fail loudly with the mismatched paths.
{
  inputs,
  lib,
  pkgs,
  self,
}: let
  system = pkgs.stdenv.hostPlatform.system;

  # Simulate a consumer's pkgs: fresh nixpkgs with our overlay
  # applied. If the overlay still uses `final.X` for build
  # inputs, the result derivation will bind to this fresh
  # nixpkgs instead of the one this repo pinned.
  consumerPkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [self.overlays.default];
  };

  # Packages to check — list every COMPILED package we ship.
  # Content-only packages (coding-standards, fragments-ai,
  # fragments-docs, stacked-workflows-content) have no build
  # inputs, so their paths are already identical. Skip them.
  compiledPackages = [
    # git-tools
    "agnix"
    "git-absorb"
    "git-branchless"
    "git-revise"
    # ai-clis
    "claude-code"
    "github-copilot-cli"
    "kiro-cli"
    "kiro-gateway"
    # mcp-servers (via nix-mcp-servers namespace)
  ];

  # MCP servers live under `nix-mcp-servers.<name>`
  mcpPackages = [
    "context7-mcp"
    "effect-mcp"
    "fetch-mcp"
    "git-intel-mcp"
    "git-mcp"
    "github-mcp"
    "kagi-mcp"
    "mcp-language-server"
    "mcp-proxy"
    "nixos-mcp"
    "openmemory-mcp"
    "sequential-thinking-mcp"
    "serena-mcp"
    "sympy-mcp"
  ];

  # For each package, compare the standalone path to the
  # consumer-simulated path. Build a list of mismatches.
  checkTopLevel = name: let
    standalone = self.packages.${system}.${name}.outPath;
    consumer = consumerPkgs.${name}.outPath;
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  checkMcp = name: let
    standalone = self.packages.${system}.${name}.outPath;
    consumer = consumerPkgs.nix-mcp-servers.${name}.outPath;
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  topLevelDrifts = lib.filter (x: x != null) (map checkTopLevel compiledPackages);
  mcpDrifts = lib.filter (x: x != null) (map checkMcp mcpPackages);
  allDrifts = topLevelDrifts ++ mcpDrifts;
in {
  cache-hit-parity = pkgs.runCommand "cache-hit-parity" {} ''
    ${
      if allDrifts == []
      then "echo 'ok — no drift detected' > $out"
      else let
        drifts = builtins.concatStringsSep "\n" (map (d: ''
            ${d.name}:
              standalone: ${d.standalone}
              consumer:   ${d.consumer}
          '')
          allDrifts);
      in ''
        echo "FAIL: consumer-side store paths differ from standalone for ${toString (builtins.length allDrifts)} package(s):" >&2
        cat >&2 <<'DRIFT'
        ${drifts}
        DRIFT
        echo "" >&2
        echo "These packages will NOT hit cachix for consumers." >&2
        echo "Fix: each affected package must use 'ourPkgs = import inputs.nixpkgs { ... }'" >&2
        echo "     instead of the consumer-provided 'final'/'prev'." >&2
        echo "See dev/notes/overlay-cache-hit-parity-fix.md for the full pattern." >&2
        exit 1
      ''
    }
  '';
}
```

- [ ] **Step 2: Wire the new check into `flake.nix`.** Find the
      `checks` forAllSystems block (around line 127-132) which
      currently reads:

```nix
    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
      devshellChecks = import ./checks/devshell-eval.nix {inherit lib pkgs self;};
    in
      moduleChecks // devshellChecks);
```

      Change to:

```nix
    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs self;};
      devshellChecks = import ./checks/devshell-eval.nix {inherit lib pkgs self;};
      parityChecks = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
    in
      moduleChecks // devshellChecks // parityChecks);
```

- [ ] **Step 3: Verify the check fails against current code
      (TDD red state).**

```bash
nix build .#checks.x86_64-linux.cache-hit-parity 2>&1 | tail -30
```

      Expected: build fails with drift report for some/all
      compiled packages. This confirms the check works.

- [ ] **Step 4: Commit the failing check.**

```bash
treefmt checks/cache-hit-parity.nix flake.nix
git add checks/cache-hit-parity.nix flake.nix
git commit -m "$(cat <<'EOF'
test(checks): add cache-hit parity regression check

New flake check checks/cache-hit-parity.nix verifies that every
compiled overlay package evaluates to the same store path when
built standalone (as CI does for cachix) vs through a
consumer's pkgs set (how consumers actually get them). Mismatch
means cachix substituters won't serve the consumer path.

The check constructs a "consumer simulation" by running
`import inputs.nixpkgs { overlays = [self.overlays.default]; }`
then comparing each package's outPath to the standalone
`self.packages.<system>.<name>` outPath.

On mismatch the check fails with a full drift report
(standalone path + consumer path per package) and a pointer
to dev/notes/overlay-cache-hit-parity-fix.md.

Expected to FAIL immediately — this commit only adds the check,
it does NOT fix any packages. The actual fixes land in
subsequent commits, one package group at a time (Rust first,
then npm, Python, Go, AI CLIs). The check gates regressions
going forward.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2: Thread `inputs` through overlay composition

**Files:**

- Modify: `packages/git-tools/default.nix`
- Modify: `packages/ai-clis/default.nix`
- Modify: `packages/mcp-servers/default.nix` (already supports
  `{inputs, ...}` via `callPkg` — audit to confirm)

**Steps:**

- [ ] **Step 1: Update `packages/git-tools/default.nix`.**
      Current code passes `sources final prev` to each
      per-package overlay. Change to pass `{inherit inputs;}
  sources final prev` so each package file receives
      `inputs`. Also drop the top-level
      `inputs.rust-overlay.overlays.default` from the
      `composeManyExtensions` — each package will apply
      rust-overlay to its own `ourPkgs` internally.

      Replace the body with:

```nix
{inputs, ...}: let
  inherit (inputs.nixpkgs) lib;

  # Evaluate sources once per composition, pass to all overlays.
  withSources = overlayPaths: final: prev: let
    sources = import ./sources.nix {
      inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
    };
    # Thread `inputs` into each per-package overlay so it can
    # instantiate its own `ourPkgs = import inputs.nixpkgs`.
    applyOverlay = path: (import path) {inherit inputs;} sources final prev;
  in
    lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);

  localOverlays = [
    ./agnix.nix
    ./git-absorb.nix
    ./git-branchless.nix
    ./git-revise.nix
  ];
in
  # Per-package overlays now apply rust-overlay internally to
  # their own ourPkgs, so the top-level composition no longer
  # needs it. Keeping the top-level entry would double-apply
  # and couple build infra to the consumer's evaluation.
  withSources localOverlays
```

- [ ] **Step 2: Update `packages/ai-clis/default.nix`.** It
      currently uses a different pattern (direct `import` with
      explicit attrset args, not the `path -> sources -> final
  -> prev` chain). Each package file takes
      `{ final, prev, nv, ... }`. Update to also accept and
      pass `inputs`.

      Read the current file to confirm the pattern:

```bash
cat packages/ai-clis/default.nix
```

      Then rewrite to:

```nix
# AI CLI package overlay: claude-code, copilot-cli, kiro-cli, kiro-gateway.
# Packages are top-level (pkgs.claude-code, pkgs.github-copilot-cli, etc.).
#
# Note: buddy customization for claude-code lives in the HM module
# (modules/claude-code-buddy/), not as package passthru. The any-buddy
# worker source tree is exposed as `any-buddy` (matching upstream
# package name) for the activation script to use.
{inputs, ...}: final: prev: let
  sources = import ./sources.nix {inherit final;};
in {
  any-buddy = import ./any-buddy.nix {
    inherit final;
    nv = sources.any-buddy;
  };
  claude-code = import ./claude-code.nix {
    inherit inputs final prev;
    nv = sources.claude-code;
    lockFile = ./locks/claude-code-package-lock.json;
  };
  github-copilot-cli = import ./copilot-cli.nix {
    inherit inputs final prev;
    nv = sources.copilot-cli;
  };
  kiro-cli = import ./kiro-cli.nix {
    inherit inputs final prev;
    nv = sources.kiro-cli;
    nv-darwin = sources.kiro-cli-darwin;
  };
  kiro-gateway = import ./kiro-gateway.nix {
    inherit inputs final;
    nv = sources.kiro-gateway;
  };
}
```

- [ ] **Step 3: Audit `packages/mcp-servers/default.nix`.** It
      already uses the `callPkg` pattern that detects `inputs`
      in the package function's args. Verify no change needed:

```bash
grep -n 'inputs' packages/mcp-servers/default.nix
```

      Expected: `callPkg` checks `if args ? inputs` and passes
      `{inherit inputs;}` through to files that accept it.
      This means per-package files get `inputs` automatically
      once they declare it in their args. No default.nix
      change needed — the per-package files are the ones that
      need updating (in later tasks).

- [ ] **Step 4: Verify flake.nix still evaluates cleanly.**
      Note: individual packages will still be broken, but the
      overlay composition layer should evaluate:

```bash
nix flake show 2>&1 | head -20
```

      Expected: no eval errors about argument mismatches in
      `packages/git-tools/default.nix` or
      `packages/ai-clis/default.nix`. Individual package
      derivations may fail to build but the flake should
      enumerate them.

- [ ] **Step 5: Commit.**

```bash
treefmt packages/git-tools/default.nix packages/ai-clis/default.nix
git add packages/git-tools/default.nix packages/ai-clis/default.nix
git commit -m "$(cat <<'EOF'
refactor(overlay): thread inputs into per-package overlay functions

Per-package overlay functions need access to `inputs` so they
can instantiate their own `ourPkgs = import inputs.nixpkgs {
...}` (the cache-hit parity pattern documented in
dev/notes/overlay-cache-hit-parity-fix.md and the
`overlays/cache-hit-parity.md` fragment).

Changes:

- `packages/git-tools/default.nix` — `applyOverlay` now passes
  `{inherit inputs;}` as the first argument to each
  per-package overlay. Also drops the top-level
  `inputs.rust-overlay.overlays.default` from
  composeManyExtensions since each package will apply
  rust-overlay to its own ourPkgs internally — keeping it at
  the top level would double-apply and couple the toolchain
  to the consumer's nixpkgs.

- `packages/ai-clis/default.nix` — now takes `{inputs, ...}`
  and threads `inputs` into each per-package import.

- `packages/mcp-servers/default.nix` — already supports
  inputs via the `callPkg` pattern (`if args ? inputs`),
  verified and left alone.

Per-package files will be updated in subsequent commits
(Rust → npm → Python → Go → AI CLIs). This commit only
threads the plumbing; individual packages are still broken
until their per-file commits land. The cache-hit-parity check
will remain red until every package is updated.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: Rust packages (git-tools group)

**Files:**

- Modify: `packages/git-tools/git-branchless.nix`
- Modify: `packages/git-tools/git-absorb.nix`
- Modify: `packages/git-tools/git-revise.nix`
- Modify: `packages/git-tools/agnix.nix`

**Steps:**

- [ ] **Step 1: Rewrite `git-branchless.nix`** using the
      `ourPkgs` pattern. Replace the entire file with:

```nix
{inputs}: sources: final: _prev: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final) system;
    overlays = [(import inputs.rust-overlay)];
    config.allowUnfree = true;
  };
  nv = sources.git-branchless;

  # Pin to 1.88.0 — git-branchless v0.10.0 has esl01-indexedlog build
  # failure on Rust 1.89+ (arxanas/git-branchless#1585). Update this
  # when upstream fixes the issue or a new release ships.
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in {
  git-branchless = ourPkgs.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          # Strip "v" prefix — nvfetcher gives "v0.10.0" from the tag
          # but the binary prints "0.10.0" in --version output.
          version = ourPkgs.lib.removePrefix "v" nv.version;
          inherit (nv) src;
          inherit (nv) cargoHash;
          postPatch = null;
        });
  });
}
```

- [ ] **Step 2: Rewrite `git-absorb.nix`**. Read the current
      file first:

```bash
cat packages/git-tools/git-absorb.nix
```

      Apply the same transformation: add `{inputs}:` as the
      first curried arg, instantiate `ourPkgs`, replace every
      `final.X` and `prev.X` with `ourPkgs.X` except
      `final.system` (used to initialize `ourPkgs`).

- [ ] **Step 3: Rewrite `git-revise.nix`** and `agnix.nix`
      with the same pattern. Note `git-revise` uses
      `buildPythonApplication`, and `agnix` uses a Rust
      build with darwin sdk — both still get `ourPkgs.X`
      everywhere.

- [ ] **Step 4: Run the cache-hit parity check on just the
      Rust packages.** The check validates all compiled
      packages at once, but we can spot-check by building
      individually first:

```bash
nix build .#git-branchless .#git-absorb .#git-revise .#agnix
```

      Expected: all four build successfully using this repo's
      nixpkgs.

- [ ] **Step 5: Verify standalone vs consumer store paths
      match.** Use the verification snippet from
      `dev/notes/overlay-cache-hit-parity-fix.md`:

```bash
STANDALONE=$(nix eval --raw .#git-branchless)
CONSUMER=$(nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs {
      system = "x86_64-linux";
      overlays = [ flake.overlays.default ];
      config.allowUnfree = true;
    };
  in pkgs.git-branchless.outPath')
echo "standalone: $STANDALONE"
echo "consumer:   $CONSUMER"
[ "$STANDALONE" = "$CONSUMER" ] && echo "MATCH" || echo "DRIFT"
```

      Expected: `MATCH` for git-branchless. Repeat for
      git-absorb, git-revise, agnix. Any `DRIFT` means the
      `ourPkgs` pattern wasn't applied correctly — some
      reference still uses `final.*` or `prev.*`.

- [ ] **Step 6: Commit.**

```bash
treefmt packages/git-tools/*.nix
git add packages/git-tools/agnix.nix packages/git-tools/git-absorb.nix packages/git-tools/git-branchless.nix packages/git-tools/git-revise.nix
git commit -m "$(cat <<'EOF'
fix(git-tools): instantiate ourPkgs for cache-hit parity

Rewrites all four git-tools overlay packages to use the
`ourPkgs = import inputs.nixpkgs { ... }` pattern documented
in dev/notes/overlay-cache-hit-parity-fix.md. Every build
input (rust toolchain, makeRustPlatform, buildPythonApplication
for git-revise, pkg-config/darwin sdk for agnix) now routes
through ourPkgs instead of the consumer's final/prev.

Consequence: consumers that apply `overlays.default` now get
byte-identical store paths to the ones CI builds and pushes
to nix-agentic-tools.cachix.org. Verified per-package with
the standalone-vs-consumer eval comparison from the notes
file — all four MATCH.

Packages affected:
- agnix (Rust, darwin sdk)
- git-absorb (Rust)
- git-branchless (Rust, pinned to 1.88.0)
- git-revise (buildPythonApplication)

Does NOT yet fully pass the cache-hit-parity check — the npm,
Python (MCP), Go, and AI CLI packages are still on the old
pattern. Those land in subsequent commits.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: npm MCP packages

**Files:**

- Modify: `packages/mcp-servers/context7-mcp.nix`
- Modify: `packages/mcp-servers/effect-mcp.nix`
- Modify: `packages/mcp-servers/git-intel-mcp.nix`
- Modify: `packages/mcp-servers/openmemory-mcp.nix`
- Modify: `packages/mcp-servers/sequential-thinking-mcp.nix`

**Steps:**

- [ ] **Step 1: Inspect one npm package to understand the
      current shape.** Read `context7-mcp.nix`:

```bash
cat packages/mcp-servers/context7-mcp.nix
```

      Note: because `callPkg` in `mcp-servers/default.nix`
      merges `final` with `nv-sources`, the function takes
      `final` as its primary argument (not the
      `final: prev:` overlay shape). The `{inputs, ...}`
      prefix is a separate curried arg.

- [ ] **Step 2: Rewrite `context7-mcp.nix`** to instantiate
      `ourPkgs` and use it for every build input. Template
      (adapt to the actual file):

```nix
{inputs}: {
  nv-sources,
  stdenv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  nv = nv-sources.context7-mcp;
in
  ourPkgs.buildNpmPackage {
    pname = nv.pname;
    inherit (nv) version src npmDepsHash;
    # ... rest of the existing attrs, but any final.X → ourPkgs.X
  }
```

      The trick: the existing file uses `final.buildNpmPackage`
      and various `final.X` helpers. Replace every `final.X`
      (except `final.stdenv.hostPlatform.system`) with
      `ourPkgs.X`. The function arg list changes from
      `{nv-sources, ...}` (which pulls from `final`) to
      `{inputs}: {nv-sources, stdenv, ...}` so we can use
      `stdenv.hostPlatform.system` to pick the platform for
      `ourPkgs`.

- [ ] **Step 3: Repeat for the other four npm packages.**
      Same transformation. The build attrs may differ
      (`makeWrapper` etc.) but the pattern is identical.

- [ ] **Step 4: Build each updated package to verify.**

```bash
for p in context7-mcp effect-mcp git-intel-mcp openmemory-mcp sequential-thinking-mcp; do
  echo "=== $p ==="
  nix build .#${p} || { echo "FAIL: $p"; exit 1; }
done
```

- [ ] **Step 5: Verify standalone vs consumer path match per
      package.** Use the verification snippet, substituting
      `pkgs.nix-mcp-servers.<name>` for the consumer-side lookup:

```bash
for p in context7-mcp effect-mcp git-intel-mcp openmemory-mcp sequential-thinking-mcp; do
  STANDALONE=$(nix eval --raw .#${p})
  CONSUMER=$(nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ./.);
      pkgs = import flake.inputs.nixpkgs {
        system = \"x86_64-linux\";
        overlays = [ flake.overlays.default ];
        config.allowUnfree = true;
      };
    in pkgs.nix-mcp-servers.${p}.outPath")
  if [ "$STANDALONE" = "$CONSUMER" ]; then
    echo "$p: MATCH"
  else
    echo "$p: DRIFT"
    echo "  standalone: $STANDALONE"
    echo "  consumer:   $CONSUMER"
  fi
done
```

      Expected: every package reports `MATCH`.

- [ ] **Step 6: Commit.**

```bash
treefmt packages/mcp-servers/context7-mcp.nix packages/mcp-servers/effect-mcp.nix packages/mcp-servers/git-intel-mcp.nix packages/mcp-servers/openmemory-mcp.nix packages/mcp-servers/sequential-thinking-mcp.nix
git add packages/mcp-servers/context7-mcp.nix packages/mcp-servers/effect-mcp.nix packages/mcp-servers/git-intel-mcp.nix packages/mcp-servers/openmemory-mcp.nix packages/mcp-servers/sequential-thinking-mcp.nix
git commit -m "$(cat <<'EOF'
fix(mcp-servers): npm packages use ourPkgs for cache-hit parity

Rewrites all five npm-based MCP server packages (context7-mcp,
effect-mcp, git-intel-mcp, openmemory-mcp,
sequential-thinking-mcp) to instantiate
`ourPkgs = import inputs.nixpkgs {...}` and use it for
buildNpmPackage + nodejs + any other build helpers.

Previously all `final.buildNpmPackage` / `final.nodejs` /
`final.makeWrapper` etc. references bound the derivations to
the consumer's nixpkgs, causing store-path drift vs CI's
standalone builds. Now everything routes through ourPkgs and
the paths match — cachix substitution works for consumers.

Verified per-package with the standalone-vs-consumer outPath
comparison. All 5 MATCH.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: Python MCP packages

**Files:**

- Modify: `packages/mcp-servers/fetch-mcp.nix`
- Modify: `packages/mcp-servers/git-mcp.nix`
- Modify: `packages/mcp-servers/kagi-mcp.nix`
- Modify: `packages/mcp-servers/mcp-proxy.nix`
- Modify: `packages/mcp-servers/nixos-mcp.nix`
- Modify: `packages/mcp-servers/serena-mcp.nix`
- Modify: `packages/mcp-servers/sympy-mcp.nix`

**Steps:**

- [ ] **Step 1: Same pattern as Task 4** but for Python
      packages. Each file uses `final.python3Packages.X` or
      `final.python3.withPackages` — replace with
      `ourPkgs.python3Packages.X` / `ourPkgs.python3.
  withPackages`.

- [ ] **Step 2: Rewrite all seven Python package files.**
      Template:

```nix
{inputs}: {
  nv-sources,
  stdenv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  nv = nv-sources.<package-name>;
in
  ourPkgs.python3Packages.buildPythonApplication {
    pname = nv.pname;
    inherit (nv) version src;
    # ... rest, all final.X → ourPkgs.X
  }
```

- [ ] **Step 3: Build + verify each.**

```bash
for p in fetch-mcp git-mcp kagi-mcp mcp-proxy nixos-mcp serena-mcp sympy-mcp; do
  echo "=== $p ==="
  nix build .#${p} || { echo "FAIL: $p"; exit 1; }
done
```

      Then standalone vs consumer per-package as in Task 4
      Step 5.

- [ ] **Step 4: Commit.**

```bash
treefmt packages/mcp-servers/fetch-mcp.nix packages/mcp-servers/git-mcp.nix packages/mcp-servers/kagi-mcp.nix packages/mcp-servers/mcp-proxy.nix packages/mcp-servers/nixos-mcp.nix packages/mcp-servers/serena-mcp.nix packages/mcp-servers/sympy-mcp.nix
git add packages/mcp-servers/fetch-mcp.nix packages/mcp-servers/git-mcp.nix packages/mcp-servers/kagi-mcp.nix packages/mcp-servers/mcp-proxy.nix packages/mcp-servers/nixos-mcp.nix packages/mcp-servers/serena-mcp.nix packages/mcp-servers/sympy-mcp.nix
git commit -m "$(cat <<'EOF'
fix(mcp-servers): python packages use ourPkgs for cache-hit parity

Rewrites all seven Python-based MCP server packages (fetch-mcp,
git-mcp, kagi-mcp, mcp-proxy, nixos-mcp, serena-mcp, sympy-mcp)
to instantiate `ourPkgs = import inputs.nixpkgs {...}` and use
it for python3/python3Packages + build helpers.

Python env closures are particularly sensitive to nixpkgs
drift — different consumer pins pull different python/hatchling/
setuptools versions, producing different store paths for the
same source. These were some of the worst cache-hit offenders.

Verified per-package: all 7 standalone paths match consumer
paths.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6: Go MCP packages

**Files:**

- Modify: `packages/mcp-servers/github-mcp.nix`
- Modify: `packages/mcp-servers/mcp-language-server.nix`

**Steps:**

- [ ] **Step 1: Rewrite both Go packages.** Same pattern.
      Go packages use `final.buildGoModule`.

- [ ] **Step 2: Build + verify.**

```bash
nix build .#github-mcp .#mcp-language-server
```

      Plus the standalone-vs-consumer comparison for both.

- [ ] **Step 3: Commit.**

```bash
treefmt packages/mcp-servers/github-mcp.nix packages/mcp-servers/mcp-language-server.nix
git add packages/mcp-servers/github-mcp.nix packages/mcp-servers/mcp-language-server.nix
git commit -m "$(cat <<'EOF'
fix(mcp-servers): go packages use ourPkgs for cache-hit parity

Rewrites github-mcp and mcp-language-server (both buildGoModule)
to instantiate ourPkgs and use ourPkgs.buildGoModule plus any
go-toolchain references. Matches CI's standalone store paths;
cachix substitution works for consumers.

Verified: both MATCH.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7: AI CLI packages

**Files:**

- Modify: `packages/ai-clis/claude-code.nix`
- Modify: `packages/ai-clis/copilot-cli.nix`
- Modify: `packages/ai-clis/kiro-cli.nix`
- Modify: `packages/ai-clis/kiro-gateway.nix`

**Steps:**

- [ ] **Step 1: claude-code.nix** — complex. Uses
      `final.symlinkJoin` + `final.writeShellScript` +
      `final.bun` (the runtime wrapper) plus
      `prev.claude-code.override`. Every `final.X` and `prev.X`
      (except `final.stdenv.hostPlatform.system`) becomes
      `ourPkgs.X`. Maintain the `passthru.baseClaudeCode`
      escape hatch — see the wrapper-chain fragment for
      details.

      Read the current file carefully before editing:

```bash
cat packages/ai-clis/claude-code.nix | head -100
```

- [ ] **Step 2: copilot-cli.nix** — simpler. Uses
      `prev.github-copilot-cli.overrideAttrs` with just
      src/version. The base derivation comes from `prev`
      (consumer's nixpkgs), so we need to switch to
      `ourPkgs.github-copilot-cli.overrideAttrs`.

      Updated template:

```nix
{
  inputs,
  final,
  prev,
  nv,
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  inherit (ourPkgs.stdenv.hostPlatform) system;
  suffix =
    platformMap.${system}
    or (throw "copilot-cli: unsupported system ${system}");
  src = ourPkgs.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-${suffix}.tar.gz";
    hash =
      nv.${system}
      or (throw "copilot-cli: no hash for ${system}");
  };
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
```

      Note `prev` is kept in the arg list for signature
      compatibility with the `default.nix` call site, but is
      no longer used.

- [ ] **Step 3: kiro-cli.nix** — similar to copilot-cli but
      with platform split (Linux tarball, Darwin dmg) and
      `final.makeWrapper` for postFixup. Same transformation.

- [ ] **Step 4: kiro-gateway.nix** — uses
      `final.python314.withPackages` with explicit Python
      3.14 + fastapi/httpx/etc. Build against `ourPkgs.python314`.

- [ ] **Step 5: Build + verify each.**

```bash
for p in claude-code github-copilot-cli kiro-cli kiro-gateway; do
  echo "=== $p ==="
  nix build .#${p} || { echo "FAIL: $p"; exit 1; }
done
```

      Per-package standalone-vs-consumer comparison as before.

- [ ] **Step 6: Commit.**

```bash
treefmt packages/ai-clis/*.nix
git add packages/ai-clis/claude-code.nix packages/ai-clis/copilot-cli.nix packages/ai-clis/kiro-cli.nix packages/ai-clis/kiro-gateway.nix
git commit -m "$(cat <<'EOF'
fix(ai-clis): use ourPkgs for cache-hit parity

Rewrites claude-code, github-copilot-cli, kiro-cli, and
kiro-gateway to instantiate ourPkgs and route every build
input through it.

claude-code is the most complex: symlinkJoin + writeShellScript
+ bun runtime wrapper + prev.claude-code.override (npm build).
Every final.X and prev.X that was touching build infra now
goes through ourPkgs. passthru.baseClaudeCode still points at
ourPkgs.claude-code so the buddy activation script can find
the nixpkgs-managed lib/node_modules layout.

copilot-cli and kiro-cli are pure binary fetches with
overrideAttrs on prev — switched to ourPkgs.github-copilot-cli
and ourPkgs.kiro-cli so the base derivation closure matches
CI's standalone build.

kiro-gateway is a python314.withPackages environment —
particularly sensitive to nixpkgs drift because Python 3.14
is still moving fast in nixpkgs master.

Verified: all 4 standalone paths match consumer paths.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8: Run the full cache-hit parity check

**Files:** None modified.

**Steps:**

- [ ] **Step 1: Run the parity check — expect PASS.**

```bash
nix build .#checks.x86_64-linux.cache-hit-parity
```

      Expected: builds successfully, output file contains
      `ok — no drift detected`.

- [ ] **Step 2: Run full flake check.**

```bash
nix flake check
```

      Expected: all checks pass including the new parity
      check and the eval + devshell checks.

- [ ] **Step 3: Run devenv test.**

```bash
devenv test
```

      Expected: passes. Skills still present on disk (the
      activation from earlier phases).

- [ ] **Step 4: Spot-check cachix narinfo for a couple of
      packages.** CI hasn't pushed these new store paths yet
      (this session's work is local), so this step is
      informational only — expected behavior is that the
      new standalone hashes are NOT in cachix yet. After
      push + CI run, re-check.

```bash
for p in git-branchless context7-mcp claude-code; do
  STANDALONE=$(nix eval --raw .#${p})
  HASH=$(basename "$STANDALONE" | cut -d- -f1)
  STATUS=$(curl -sI "https://nix-agentic-tools.cachix.org/${HASH}.narinfo" | head -1 | awk '{print $2}')
  echo "$p: hash=$HASH cachix=$STATUS"
done
```

      Expected right now: `cachix=404` (paths not yet pushed).
      Expected AFTER a future CI run: `cachix=200`.

### Task 9: Update fragment Last-verified marker

**Files:**

- Modify: `dev/fragments/overlays/cache-hit-parity.md`

**Steps:**

- [ ] **Step 1: Read the current Last-verified line** at
      `dev/fragments/overlays/cache-hit-parity.md:3`. It
      currently says "Last verified: 2026-04-07 (commit
      0f4228d)" and mentions the rule is "NOT yet
      consistently applied" and "backlog in progress".

- [ ] **Step 2: Update the marker** to today's date +
      "pending" (will be filled after the commit lands). Also
      remove the "backlog in progress" caveat since the
      pattern is now fully applied:

```markdown
> **Last verified:** 2026-04-08 (commit pending — full
> rollout across git-tools, mcp-servers, and ai-clis). If you
> touch any `packages/<group>/*.nix` overlay file or the
> overlay composition machinery and this fragment isn't
> updated in the same commit, stop and fix it.
```

- [ ] **Step 3: Remove the "Status: backlog item in progress"
      section** since the backlog item is now closed. The
      section currently reads:

```markdown
### Status: backlog item in progress

As of 2026-04-07 the rule is NOT yet consistently applied. Current
overlay code in `packages/git-tools/git-branchless.nix` (and
friends) still uses `final.rust-bin` and `prev.git-branchless`.
...
```

      Delete it entirely.

- [ ] **Step 4: Update `docs/plan.md`** to check off the
      "Overlay cache-hit parity fix" item at line 67-75. Change
      the `- [ ]` to `- [x]` and add a one-line note:

```markdown
- [x] **Overlay cache-hit parity fix** — landed 2026-04-08.
      Every compiled overlay package now instantiates its own
      `ourPkgs = import inputs.nixpkgs {...}`. Verified end-to-end
      with the new `checks.cache-hit-parity` flake check. Consumer
      store paths match CI's standalone paths; cachix substitution
      works after next CI run.
```

- [ ] **Step 5: Regenerate instructions, format, and commit.**

```bash
devenv tasks run --mode before generate:instructions
treefmt dev/fragments/overlays/cache-hit-parity.md docs/plan.md
git add dev/fragments/overlays/cache-hit-parity.md docs/plan.md
git commit -m "$(cat <<'EOF'
docs(overlays): close out cache-hit parity backlog item

Every compiled overlay package in packages/git-tools/,
packages/mcp-servers/, and packages/ai-clis/ now uses the
`ourPkgs = import inputs.nixpkgs {...}` pattern. The fragment's
"status: backlog in progress" caveat is removed and the
Last-verified marker bumped.

The `checks.cache-hit-parity` flake check (added at the start
of this phase) gates regressions — any future package that
uses `final.X` or `prev.X` for a build input will fail the
check with a drift report.

Closes the "Overlay cache-hit parity fix" item from docs/plan.md
TOP priority.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification protocol (end of plan)

After all three phases land, run the full verification suite:

- [ ] `nix flake check` — all checks pass including the new
      `ai-self-contained-eval` (Phase 1) and `cache-hit-parity`
      (Phase 3) checks
- [ ] `devenv test` — full devenv task DAG succeeds
- [ ] `dev/scripts/measure-context.sh` — compare to the baseline
      captured in Phase 2 Task 1. Expected ~5x reduction in
      always-loaded tokens per ecosystem
- [ ] Phase 1 consumer check: user confirms `home-manager switch`
      on nixos-config succeeds without any surgical
      `nix-agentic-tools-*` imports
- [ ] Phase 2 consumer check: launch claude in the repo, verify
      orientation context loads (no errors about missing rules),
      spot-check that scoped fragments appear when editing
      their target files
- [ ] Phase 3 consumer check: after the commits push + CI runs + cachix has the new store paths, user does `home-manager
  switch` on nixos-config and verifies no rebuild for
      git-branchless, claude-code, etc. (these should pull from
      cachix rather than compiling locally)

---

## Out of scope (do NOT do in this session)

- Tasks 3-7 of the `ai.claude.*` full passthrough (memory,
  settings, mcpServers, skills, plugins). Separate plan after
  these three phases land.
- Task D devenv ai module mirror of the passthrough.
- Bumping Last-verified markers on all 9 architecture fragments.
  Only touches the fragments whose content this plan modifies
  (`overlays/cache-hit-parity.md` in Task 9 Phase 3, possibly
  `monorepo/architecture-fragments.md` in Phase 2 Task 6).
- Refactoring `packages/mcp-servers/default.nix` further than
  already handled by the existing `callPkg` pattern.
- Moving memory files (project\_\* memories) — separate cleanup.
- Always-loaded fragment deduplication beyond the monorepo
  audit — other cross-category duplicates (if any) are
  follow-up work.

---

## Commit count target

~20 commits across the three phases:

**Phase 1 (2 commits):**

1. `refactor(ai): self-contain dep imports for single-import consumers`
2. (Task 4 is consumer-side, no commit)

**Phase 2 (6 commits):**

1. `chore(dev): add context budget measurement script`
2. `refactor(generate): drop .claude/rules/common.md generation`
3. `refactor(generate): CLAUDE.md becomes @AGENTS.md stub`
4. `refactor(generate): AGENTS.md is orientation only, not flat concat`
5. `refactor(fragments): re-scope monorepo fragments to reduce always-load`
6. `docs(fragments): update architecture-fragments for re-scoped categories`

**Phase 3 (9 commits):**

1. `test(checks): add cache-hit parity regression check`
2. `refactor(overlay): thread inputs into per-package overlay functions`
3. `fix(git-tools): instantiate ourPkgs for cache-hit parity`
4. `fix(mcp-servers): npm packages use ourPkgs for cache-hit parity`
5. `fix(mcp-servers): python packages use ourPkgs for cache-hit parity`
6. `fix(mcp-servers): go packages use ourPkgs for cache-hit parity`
7. `fix(ai-clis): use ourPkgs for cache-hit parity`
8. (Task 8 is verification, no commit)
9. `docs(overlays): close out cache-hit parity backlog item`

Each commit is atomic and the tree should pass `nix flake check`
at every commit BOUNDARY (except Phase 3 Task 1 which adds a
failing check intentionally — TDD red state). The check turns
green at Task 8 after all per-group fixes land.

---

## After this session

Once this plan lands, the TOP-priority "Architecture foundation"
section of `docs/plan.md` still contains:

- **Consolidate fragment enumeration** — single metadata table
  for fragments (low urgency, cleanup)
- **npm hash contingency monitoring** — passive backlog watch
- Various Codex / mkAgenticShell unblocks

The next plan should target the `ai.claude.*` full passthrough
work (Tasks 3-7 + Task D), which is no longer blocked by the
skills fanout or any architecture foundation item. Draft that
plan from `memory/project_ai_claude_passthrough.md` when ready.
