# Generated Docs Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all content generation to Nix derivations wrapped in devenv tasks, organized by scope (instructions, repo docs, doc site).

**Architecture:** Each generation output is a Nix derivation (cached by store). Devenv tasks are thin wrappers that `nix build` and copy results. Tasks organized by scope: `generate:instructions:*`, `generate:repo:*`, `generate:site:*`. Fragment composition logic moves from devenv.nix inline code to a shared `dev/generate.nix` module.

**Tech Stack:** Nix (derivations, fragments, transforms), devenv tasks, mdbook

**Spec:** `docs/superpowers/specs/2026-04-06-generated-docs-design.md`

---

## Phase 3a — Instruction Task Migration

### Task 0: Capture baseline instruction files

**Files:**

- None modified

- [ ] **Step 1: Generate current files and save baseline**

```bash
mkdir -p /tmp/gen-baseline
# Dereference symlinks to capture actual content
for f in .claude/rules/*.md; do cp -L "$f" /tmp/gen-baseline/claude-$(basename "$f"); done
cp -L .github/copilot-instructions.md /tmp/gen-baseline/copilot-root.md
for f in .github/instructions/*.md; do cp -L "$f" /tmp/gen-baseline/copilot-$(basename "$f"); done
for f in .kiro/steering/*.md; do cp -L "$f" /tmp/gen-baseline/kiro-$(basename "$f"); done
cp -L AGENTS.md /tmp/gen-baseline/AGENTS.md
cp -L CLAUDE.md /tmp/gen-baseline/CLAUDE.md
```

- [ ] **Step 2: Verify baseline captured**

```bash
ls /tmp/gen-baseline/ | wc -l
```

Expected: ~15 files.

---

### Task 1: Extract fragment composition to dev/generate.nix

The fragment composition logic is duplicated between `devenv.nix` and
`flake.nix`. Extract it to a shared module so both consumers and the
new task derivations use the same source of truth.

**Files:**

- Create: `dev/generate.nix`
- Modify: `devenv.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Create dev/generate.nix**

This module provides fragment composition and instruction content
as pure Nix values. It takes `{ lib, pkgs }` (pkgs with overlays applied)
and returns all composed content needed for instruction generation.

```nix
# dev/generate.nix — Shared fragment composition for all generation tasks.
#
# Pure Nix values: composed fragments, rendered instruction content.
# Consumed by: devenv.nix tasks, flake.nix derivations.
{lib, pkgs}: let
  fragments = import ../lib/fragments.nix {inherit lib;};
  aiTransforms = pkgs.fragments-ai.passthru.transforms;

  # ── Fragment sources ──────────────────────────────────────────────
  commonFragments = builtins.attrValues pkgs.coding-standards.passthru.fragments;
  swsFragments = builtins.attrValues pkgs.stacked-workflows-content.passthru.fragments;

  mkDevFragment = pkg: name:
    fragments.mkFragment {
      text = builtins.readFile ../dev/fragments/${pkg}/${name}.md;
      description = "dev/${pkg}/${name}";
      priority = 5;
    };

  # ── Package scoping ──────────────────────────────────────────────
  packagePaths = {
    ai-clis = ''"modules/copilot-cli/**,modules/kiro-cli/**,packages/ai-clis/**"'';
    mcp-servers = ''"modules/mcp-servers/**,packages/mcp-servers/**"'';
    monorepo = null;
    stacked-workflows = ''"packages/stacked-workflows/**"'';
  };

  devFragmentNames = {
    ai-clis = ["packaging-guide"];
    monorepo = [
      "build-commands"
      "change-propagation"
      "linting"
      "naming-conventions"
      "nix-standards"
      "project-overview"
    ];
    mcp-servers = ["overlay-guide"];
    stacked-workflows = ["development"];
  };

  nonRootPackages = lib.filterAttrs (name: _: name != "monorepo") devFragmentNames;

  extraPublishedFragments = {
    monorepo = swsFragments;
    stacked-workflows = swsFragments;
  };

  # ── Composition ──────────────────────────────────────────────────
  mkDevComposed = package: let
    devFrags = map (mkDevFragment package) (devFragmentNames.${package} or []);
    extraFrags = extraPublishedFragments.${package} or [];
  in
    fragments.compose {fragments = commonFragments ++ extraFrags ++ devFrags;};

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

  # ── Pre-composed content ────────────────────────────────────────
  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";

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

  # ── Per-ecosystem rendered content ──────────────────────────────
  # Attrset of { path = content; } for each ecosystem output file.
  claudeFiles =
    {
      "common.md" = monorepoEco.claude rootComposed;
    }
    // lib.mapAttrs' (pkg: _:
      lib.nameValuePair "${pkg}.md"
      ((mkEcosystemFile pkg).claude (mkDevComposed pkg)))
    nonRootPackages;

  copilotFiles =
    {
      "copilot-instructions.md" = monorepoEco.copilot rootComposed;
    }
    // lib.mapAttrs' (pkg: _:
      lib.nameValuePair "${pkg}.instructions.md"
      ((mkEcosystemFile pkg).copilot (mkDevComposed pkg)))
    nonRootPackages;

  kiroFiles =
    {
      "common.md" = aiTransforms.kiro {name = "common";} rootComposed;
    }
    // lib.mapAttrs' (pkg: _:
      lib.nameValuePair "${pkg}.md"
      ((mkEcosystemFile pkg).kiro (mkDevComposed pkg)))
    nonRootPackages;

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
in {
  inherit agentsMd claudeFiles claudeMd copilotFiles kiroFiles;
  inherit mkDevComposed mkEcosystemFile nonRootPackages rootComposed;
  inherit fragments aiTransforms;
}
```

- [ ] **Step 2: Verify dev/generate.nix evaluates**

```bash
nix eval --impure --expr '
  let
    pkgs = import <nixpkgs> {
      overlays = [(import ./packages/coding-standards {}) (import ./packages/fragments-ai {}) (import ./packages/stacked-workflows {})];
    };
    gen = import ./dev/generate.nix { inherit (pkgs) lib; inherit pkgs; };
  in builtins.attrNames gen
'
```

Expected: list containing `agentsMd`, `claudeFiles`, `claudeMd`, etc.

- [ ] **Step 3: Format**

```bash
treefmt dev/generate.nix
```

- [ ] **Step 4: Commit**

```bash
git add dev/generate.nix
git commit -m "refactor(generate): extract fragment composition to dev/generate.nix

Single source of truth for fragment composition, replacing duplicated
logic in devenv.nix and flake.nix. Consumed by both devenv tasks and
flake derivations."
```

---

### Task 2: Create instruction derivations in flake.nix

**Files:**

- Modify: `flake.nix`

- [ ] **Step 1: Add instruction derivations to packages output**

In `flake.nix`, in the `packages = forAllSystems` block, add derivations
that use `dev/generate.nix` to build instruction files. Each derivation
writes its content to `$out/`.

Read the current `flake.nix` packages section to find the right location
(after `inherit (pkgs) fragments-ai;`), then add:

```nix
instructions-agents = let
  gen = import ./dev/generate.nix {inherit lib pkgs;};
in
  pkgs.writeText "AGENTS.md" gen.agentsMd;

instructions-claude = let
  gen = import ./dev/generate.nix {inherit lib pkgs;};
in
  pkgs.writeText "CLAUDE.md" gen.claudeMd;

instructions-copilot = let
  gen = import ./dev/generate.nix {inherit lib pkgs;};
in
  pkgs.runCommand "instructions-copilot" {} (
    ''
      mkdir -p $out/instructions
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: ''
        cat > $out/${
          if name == "copilot-instructions.md"
          then name
          else "instructions/${name}"
        } << 'EOF'
        ${content}
        EOF
      '')
      gen.copilotFiles)
  );

instructions-kiro = let
  gen = import ./dev/generate.nix {inherit lib pkgs;};
in
  pkgs.runCommand "instructions-kiro" {} (
    ''
      mkdir -p $out
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content: ''
        cat > $out/${name} << 'EOF'
        ${content}
        EOF
      '')
      gen.kiroFiles)
  );
```

Note: `writeText` works for single-file outputs (AGENTS.md, CLAUDE.md).
`runCommand` is needed for multi-file outputs (copilot, kiro).

- [ ] **Step 2: Verify derivations build**

```bash
nix build .#instructions-agents --print-out-paths
nix build .#instructions-claude --print-out-paths
nix build .#instructions-copilot --print-out-paths
nix build .#instructions-kiro --print-out-paths
```

Each should produce a store path. Check content:

```bash
cat $(nix build .#instructions-agents --print-out-paths)
head -5 $(nix build .#instructions-claude --print-out-paths)
ls $(nix build .#instructions-copilot --print-out-paths)/
ls $(nix build .#instructions-kiro --print-out-paths)/
```

- [ ] **Step 3: Format and commit**

```bash
treefmt flake.nix
git add flake.nix
git commit -m "feat(flake): add instruction generation derivations

instructions-agents, instructions-claude, instructions-copilot,
instructions-kiro. Each builds from dev/generate.nix, cached by store."
```

---

### Task 3: Create instruction devenv tasks

**Files:**

- Create: `dev/tasks/generate.nix`
- Modify: `devenv.nix`

- [ ] **Step 1: Create dev/tasks/generate.nix**

Follow the pattern from `dev/update.nix` — a module that returns task
attrsets. Each task runs `nix build` and copies the result.

```nix
# dev/tasks/generate.nix — Devenv tasks for instruction generation.
#
# Thin wrappers around Nix derivations. Each task builds a derivation
# and copies the result to the working tree.
{lib, ...}: let
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  log = ''log() { echo "==> $*" >&2; }'';
in {
  tasks = {
    "generate:instructions:agents" = {
      description = "Generate AGENTS.md from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building AGENTS.md"
        src=$(nix build .#instructions-agents --no-link --print-out-paths)
        cp -f "$src" AGENTS.md
        log "AGENTS.md updated"
      '';
    };

    "generate:instructions:claude" = {
      description = "Generate CLAUDE.md from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building CLAUDE.md"
        src=$(nix build .#instructions-claude --no-link --print-out-paths)
        cp -f "$src" CLAUDE.md
        log "CLAUDE.md updated"
      '';
    };

    "generate:instructions:copilot" = {
      description = "Generate Copilot instruction files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building Copilot instructions"
        src=$(nix build .#instructions-copilot --no-link --print-out-paths)
        mkdir -p .github/instructions
        cp -f "$src/copilot-instructions.md" .github/copilot-instructions.md
        for f in "$src"/instructions/*.md; do
          cp -f "$f" ".github/instructions/$(basename "$f")"
        done
        log "Copilot instructions updated"
      '';
    };

    "generate:instructions:kiro" = {
      description = "Generate Kiro steering files from fragments";
      before = ["generate:instructions"];
      exec = ''
        ${bashPreamble}
        ${log}
        log "Building Kiro steering files"
        src=$(nix build .#instructions-kiro --no-link --print-out-paths)
        mkdir -p .kiro/steering
        for f in "$src"/*.md; do
          cp -f "$f" ".kiro/steering/$(basename "$f")"
        done
        log "Kiro steering files updated"
      '';
    };

    "generate:instructions" = {
      description = "Generate all instruction files";
      after = [
        "generate:instructions:agents"
        "generate:instructions:claude"
        "generate:instructions:copilot"
        "generate:instructions:kiro"
      ];
      exec = ''
        ${bashPreamble}
        ${log}
        log "All instruction files generated"
      '';
    };
  };
}
```

- [ ] **Step 2: Wire tasks into devenv.nix**

In `devenv.nix`, in the `tasks` section (around line 359), add the
generate tasks alongside the update tasks:

```nix
tasks = let
  updateTasks = (import ./dev/update.nix {inherit lib pkgs;}).tasks;
  generateTasks = (import ./dev/tasks/generate.nix {inherit lib;}).tasks;
in
  updateTasks
  // generateTasks
  // {
    "update:all" = {
      description = "Run full update pipeline";
      after = ["update:verify"];
      exec = ''
        echo "Update pipeline complete"
      '';
    };
  };
```

- [ ] **Step 3: Verify tasks are discoverable**

```bash
devenv tasks list 2>&1 | grep generate
```

Expected: all 5 generate:instructions tasks listed.

- [ ] **Step 4: Test a single task**

```bash
devenv tasks run generate:instructions:agents
cat AGENTS.md | head -5
```

Expected: AGENTS.md updated with generated content.

- [ ] **Step 5: Format and commit**

```bash
treefmt dev/tasks/generate.nix devenv.nix
git add dev/tasks/generate.nix devenv.nix
git commit -m "feat(generate): add instruction generation devenv tasks

generate:instructions:{agents,claude,copilot,kiro} and meta task.
Thin wrappers around nix build derivations."
```

---

### Task 4: Remove old instruction generation from devenv.nix and flake.nix

**Files:**

- Modify: `devenv.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Remove instruction files.\* from devenv.nix**

Remove from the `files = mkEcosystemFiles // { ... }` block (lines 184-205):

- The entire `mkEcosystemFiles` merge
- The `"AGENTS.md".text` entry
- The `"CLAUDE.md".text` entry

Keep `files` if there are other non-instruction entries remaining.
If `files` only contained instruction entries, remove the entire
`files = ...;` block.

Also remove from the top-level `let` block (lines 31-130):

- `commonFragments`
- `swsFragments`
- `mkDevFragment`
- `packagePaths`
- `devFragmentNames`
- `nonRootPackages`
- `extraPublishedFragments`
- `mkDevComposed`
- `aiTransforms`
- `mkEcosystemFile`
- `agentsContent`
- `mkEcosystemFiles`

Keep: `fragments` import (still used by the module system if needed),
`contentPkgs` (used for skills), `mcpLib`, `mkPackageEntry`, `agnix`,
`gitToolsPkgs`.

Actually — check if `fragments` is still used anywhere in devenv.nix
after removing the composition logic. If not, remove it too.

Check if `contentPkgs` still needs the `fragments-ai` overlay after
removing the composition logic. If only `coding-standards` and
`stacked-workflows` are used (for skills passthru), drop `fragments-ai`
from the overlay list.

- [ ] **Step 2: Remove apps.generate from flake.nix**

Remove the entire `apps` output section (the `generateScript` and
`apps.generate` definitions). The composition logic now lives in
`dev/generate.nix` and the task derivations are in `packages`.

Also remove the duplicated composition let bindings from the apps
section (lines 120-182):

- `commonFragments`, `swsFragments`, `mkDevFragment`, `packagePaths`,
  `devFragmentNames`, `nonRootPackages`, `extraPublishedFragments`,
  `mkDevComposed`, `aiTransforms`, `mkEcosystemFile`

These are now in `dev/generate.nix`.

- [ ] **Step 3: Update enterTest in devenv.nix**

The enterTest currently checks for instruction files as symlinks
(`test -L`). After migration, instruction files are regular files
(copied from nix build output), not symlinks. Update tests to check
for file existence (`test -f`) instead of symlink (`test -L`) for
instruction files. Keep `-L` for skills/settings (still symlinked
by module system).

Change:

```bash
test -L .claude/rules/common.md || ...
test -L .kiro/steering/common.md || ...
test -L .github/copilot-instructions.md || ...
test -L AGENTS.md || ...
test -L CLAUDE.md || ...
```

To:

```bash
test -f .claude/rules/common.md || ...
test -f .kiro/steering/common.md || ...
test -f .github/copilot-instructions.md || ...
test -f AGENTS.md || ...
test -f CLAUDE.md || ...
```

Note: these files won't exist until someone runs `generate:instructions`.
Consider whether enterTest should run `generate:instructions` as a
prerequisite, or just skip instruction file checks. For now, change
to `-f` and leave it — the tests run after shell entry which
materializes files.

Actually — since we're removing instruction files from `files.*`,
they won't be materialized on shell entry anymore. The enterTest
needs to either:
a) Remove instruction file checks (tasks are explicit, not automatic)
b) Run generate:instructions as part of enterShell

Choose (a) for now — instruction generation is an explicit task, not
automatic. Remove instruction file checks from enterTest. Keep
skill/settings checks.

- [ ] **Step 4: Update .gitignore**

Instruction files are already in .gitignore. No changes needed for
instruction files. But `.claude/rules/` is gitignored as a directory —
ensure that still works when files are regular files instead of symlinks.

Actually, check if `.claude/rules/` needs to exist before tasks run.
Add directory creation to the task if needed, or to enterShell.

- [ ] **Step 5: Format all changed files**

```bash
treefmt devenv.nix flake.nix
```

- [ ] **Step 6: Verify**

```bash
nix flake check --no-build
devenv test
```

- [ ] **Step 7: Commit**

```bash
git add devenv.nix flake.nix
git commit -m "refactor(generate): remove old instruction generation pipeline

Instruction files now generated via devenv tasks backed by nix
derivations. Removes files.* instruction entries, mkEcosystemFiles,
and apps.generate."
```

---

### Task 5: Verify byte-identical output

**Files:**

- None modified

- [ ] **Step 1: Run instruction generation**

```bash
devenv tasks run generate:instructions
```

- [ ] **Step 2: Compare against baseline**

```bash
for f in /tmp/gen-baseline/claude-*.md; do
  name=$(basename "$f" | sed 's/^claude-//')
  if diff -q "$f" ".claude/rules/$name" > /dev/null 2>&1; then
    echo "PASS: claude/$name"
  else
    echo "FAIL: claude/$name"
    diff "$f" ".claude/rules/$name" | head -10
  fi
done

diff -q /tmp/gen-baseline/copilot-root.md .github/copilot-instructions.md && echo "PASS: copilot-root" || echo "FAIL: copilot-root"

for f in /tmp/gen-baseline/copilot-*.instructions.md; do
  name=$(basename "$f" | sed 's/^copilot-//')
  if diff -q "$f" ".github/instructions/$name" > /dev/null 2>&1; then
    echo "PASS: copilot/$name"
  else
    echo "FAIL: copilot/$name"
  fi
done

for f in /tmp/gen-baseline/kiro-*.md; do
  name=$(basename "$f" | sed 's/^kiro-//')
  if diff -q "$f" ".kiro/steering/$name" > /dev/null 2>&1; then
    echo "PASS: kiro/$name"
  else
    echo "FAIL: kiro/$name"
    diff "$f" ".kiro/steering/$name" | head -10
  fi
done

diff -q /tmp/gen-baseline/AGENTS.md AGENTS.md && echo "PASS: AGENTS.md" || echo "FAIL: AGENTS.md"
diff -q /tmp/gen-baseline/CLAUDE.md CLAUDE.md && echo "PASS: CLAUDE.md" || echo "FAIL: CLAUDE.md"
```

Expected: all PASS. If any FAIL, fix the derivation output and re-test.

Common issues:

- Trailing newlines from heredoc/writeText differences
- Leading whitespace from Nix multiline string indentation
- File permissions (nix store files are read-only; cp makes them writable)

- [ ] **Step 3: Clean up baseline**

```bash
rm -rf /tmp/gen-baseline
```

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix(generate): align instruction task output with baseline"
```

---

### Task 6: Create architecture dev fragment

**Files:**

- Create: `dev/fragments/monorepo/generation-architecture.md`
- Modify: `devenv.nix` (add to devFragmentNames)
- Modify: `flake.nix` (add to devFragmentNames — if still referenced)

- [ ] **Step 1: Create the fragment**

````markdown
## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks,
organized by scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md,
  AGENTS.md, Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md,
  CONTRIBUTING.md) from fragments + nix-evaluated data
- `generate:site:*` — doc site (mdbook) from authored prose +
  nix-evaluated reference pages and data snippets
- `generate:all` — runs all scopes

Each task wraps a `nix build .#<derivation>` and copies output to the
working tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `dev/docs/` — authored prose (getting-started guides, concepts,
  troubleshooting). Copied to `docs/src/` by `generate:site:prose`.
- `dev/fragments/` — dev-only instruction fragments. Composed into
  instruction files and CLAUDE.md.
- `docs/src/` — gitignored generated output. mdbook serves from here.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published routing table.
- `packages/fragments-ai/` — AI ecosystem transforms (passthru).
- `packages/fragments-docs/` — doc site transforms and generators
  (passthru).

### What Stays in Module System

Skills, settings.json, MCP config, and CLI settings use `files.*`
(devenv) or `home.file` (HM). These are symlinks to immutable store
paths — no generation step.

### Running Generation

```bash
devenv tasks run generate:instructions    # all instruction files
devenv tasks run generate:instructions:claude  # just CLAUDE.md
devenv tasks run generate:repo            # README.md + CONTRIBUTING.md
devenv tasks run generate:site            # full doc site
devenv tasks run generate:all             # everything
```
````

````

- [ ] **Step 2: Add to devFragmentNames**

In `dev/generate.nix`, add `"generation-architecture"` to the monorepo
fragment list (alphabetically):

```nix
monorepo = [
  "build-commands"
  "change-propagation"
  "generation-architecture"
  "linting"
  "naming-conventions"
  "nix-standards"
  "project-overview"
];
````

- [ ] **Step 3: Regenerate instruction files**

```bash
devenv tasks run generate:instructions
```

- [ ] **Step 4: Verify CLAUDE.md contains the new section**

```bash
grep "Generation Architecture" CLAUDE.md
```

- [ ] **Step 5: Format and commit**

```bash
treefmt dev/fragments/monorepo/generation-architecture.md dev/generate.nix
git add dev/fragments/monorepo/generation-architecture.md dev/generate.nix CLAUDE.md AGENTS.md
git commit -m "docs(fragments): add generation architecture steering fragment

Describes task-based generation pipeline, source layout, and what
stays in the module system. Composed into CLAUDE.md and AGENTS.md."
```

---

## Phase 3b — Repo Doc Generation

### Task 7: Create README.md generation derivation

**Files:**

- Create: `dev/readme.nix` (or add to `dev/generate.nix`)
- Modify: `flake.nix` (add `repo-readme` derivation)
- Modify: `dev/tasks/generate.nix` (add `generate:repo:readme` task)

- [ ] **Step 1: Read current README.md**

Read the entire current README.md to understand the structure and
identify which sections contain data-driven tables that should come
from nix evaluation.

- [ ] **Step 2: Identify nix-evaluatable data**

The README has these data-driven elements:

- MCP server table (from `pkgs.nix-mcp-servers` attrNames + package meta)
- Git tools table (from git-tools overlay)
- AI CLIs table (from ai-clis overlay)
- Skills table (from stacked-workflows-content skillsDir)
- Feature matrix (hand-authored for now — complex to auto-generate)

For Phase 3b, generate at minimum the package tables from overlay
introspection. Feature matrix can stay hand-authored initially.

- [ ] **Step 3: Add README generation to dev/generate.nix**

Add a `readmeMd` output that composes the README from:

- A hand-authored intro/structure template (could be a dev fragment
  or a file in `dev/docs/`)
- Nix-evaluated package tables
- Hand-authored configuration examples and other prose

The simplest approach: the entire README is a nix string in
`dev/generate.nix` that interpolates nix-evaluated data for tables
and uses `builtins.readFile` for prose sections stored in `dev/docs/`.

- [ ] **Step 4: Create the derivation in flake.nix**

```nix
repo-readme = let
  gen = import ./dev/generate.nix {inherit lib pkgs;};
in
  pkgs.writeText "README.md" gen.readmeMd;
```

- [ ] **Step 5: Add devenv task**

In `dev/tasks/generate.nix`, add:

```nix
"generate:repo:readme" = {
  description = "Generate README.md from fragments and nix data";
  before = ["generate:repo"];
  exec = ''
    ${bashPreamble}
    ${log}
    log "Building README.md"
    src=$(nix build .#repo-readme --no-link --print-out-paths)
    cp -f "$src" README.md
    log "README.md updated"
  '';
};

"generate:repo" = {
  description = "Generate all repo front-door files";
  after = ["generate:repo:readme"];
  exec = ''
    ${bashPreamble}
    ${log}
    log "All repo docs generated"
  '';
};
```

- [ ] **Step 6: Verify**

```bash
devenv tasks run generate:repo:readme
head -20 README.md
```

Compare key tables with current README to ensure data matches.

- [ ] **Step 7: Format and commit**

```bash
treefmt dev/generate.nix dev/tasks/generate.nix flake.nix
git add dev/generate.nix dev/tasks/generate.nix flake.nix README.md
git commit -m "feat(generate): add README.md generation from nix data

Package tables, server lists, skill matrices derived from actual
overlay attrsets. README.md committed as front-door file."
```

---

## Phase 3c — Doc Site Generation

### Task 8: Move authored prose to dev/docs/

**Files:**

- Create: `dev/docs/` directory tree
- Modify: `docs/src/` (remove from git tracking)
- Modify: `.gitignore`

- [ ] **Step 1: Create dev/docs/ structure**

```bash
mkdir -p dev/docs/{assets,getting-started,concepts,guides,reference}
```

- [ ] **Step 2: Move prose pages**

Move pages that are authored prose or mixed (NOT pure reference):

```bash
git mv docs/src/SUMMARY.md dev/docs/
git mv docs/src/index.md dev/docs/
git mv docs/src/assets/ dev/docs/
git mv docs/src/getting-started/choose-your-path.md dev/docs/getting-started/
git mv docs/src/getting-started/home-manager.md dev/docs/getting-started/
git mv docs/src/getting-started/devenv.md dev/docs/getting-started/
git mv docs/src/getting-started/manual-lib.md dev/docs/getting-started/
git mv docs/src/concepts/unified-ai-module.md dev/docs/concepts/
git mv docs/src/concepts/fragments.md dev/docs/concepts/
git mv docs/src/concepts/credentials.md dev/docs/concepts/
git mv docs/src/concepts/config-parity.md dev/docs/concepts/
git mv docs/src/guides/stacked-workflows.md dev/docs/guides/
git mv docs/src/troubleshooting.md dev/docs/
```

Do NOT move (these will be fully generated):

- `docs/src/concepts/overlays-packages.md`
- `docs/src/guides/home-manager.md`
- `docs/src/guides/devenv.md`
- `docs/src/guides/mcp-servers.md`
- `docs/src/reference/lib-api.md`
- `docs/src/reference/types.md`
- `docs/src/reference/ai-mapping.md`

Delete those files from git (they'll be regenerated):

```bash
git rm docs/src/concepts/overlays-packages.md
git rm docs/src/guides/home-manager.md
git rm docs/src/guides/devenv.md
git rm docs/src/guides/mcp-servers.md
git rm docs/src/reference/lib-api.md
git rm docs/src/reference/types.md
git rm docs/src/reference/ai-mapping.md
```

- [ ] **Step 3: Add docs/src/ to .gitignore**

Add to `.gitignore`:

```
# Generated doc site (mdbook source, built from dev/docs/ + nix eval)
docs/src/
```

- [ ] **Step 4: Commit**

```bash
git add dev/docs/ .gitignore
git commit -m "refactor(docs): move authored prose to dev/docs/

Source of truth for prose is now dev/docs/. docs/src/ is gitignored
and will be generated. Pure reference pages deleted (will be
generated from nix eval)."
```

---

### Task 9: Create packages/fragments-docs/

**Files:**

- Create: `packages/fragments-docs/default.nix`
- Modify: `flake.nix` (register overlay + package export)

- [ ] **Step 1: Create the package**

Follow the `fragments-ai` pattern. This package provides generators
that produce markdown from nix-evaluated data.

Read the current data-driven doc pages to understand what tables and
content they contain. The generators must reproduce this content from
nix evaluation.

Create `packages/fragments-docs/default.nix` with:

- `passthru.generators.snippets.*` — small table generators for
  `{{#include}}` in mixed pages
- `passthru.generators.*` — full page generators for reference pages

Each generator is a function that takes `{ pkgs, lib, ... }` or
specific data and returns a markdown string.

- [ ] **Step 2: Register in flake.nix**

Add overlay and package export, same pattern as fragments-ai.

- [ ] **Step 3: Verify**

```bash
nix eval .#fragments-docs.name
nix eval --json .#fragments-docs.passthru.generators --apply builtins.attrNames
```

- [ ] **Step 4: Format and commit**

```bash
treefmt packages/fragments-docs/default.nix flake.nix
git add packages/fragments-docs/ flake.nix
git commit -m "feat(fragments-docs): add doc site transform and generator package"
```

---

### Task 10: Create doc site derivations

**Files:**

- Modify: `dev/generate.nix` (add doc site content)
- Modify: `flake.nix` (add derivations)

- [ ] **Step 1: Add docs-site-prose derivation**

Copies `dev/docs/` to `$out/`:

```nix
docs-site-prose = pkgs.runCommand "docs-site-prose" {} ''
  cp -r ${./dev/docs} $out
  chmod -R u+w $out
'';
```

- [ ] **Step 2: Add docs-site-snippets derivation**

Uses `fragments-docs` generators to produce data table snippets:

```nix
docs-site-snippets = let
  docGen = pkgs.fragments-docs.passthru.generators;
in pkgs.runCommand "docs-site-snippets" {} ''
  mkdir -p $out/snippets
  cat > $out/snippets/overlay-table.md << 'EOF'
  ${docGen.snippets.overlayTable { inherit pkgs lib; }}
  EOF
  # ... repeat for each snippet
'';
```

- [ ] **Step 3: Add docs-site-reference derivation**

Uses `fragments-docs` generators to produce full reference pages:

```nix
docs-site-reference = let
  docGen = pkgs.fragments-docs.passthru.generators;
in pkgs.runCommand "docs-site-reference" {} ''
  mkdir -p $out/{concepts,guides,reference}
  cat > $out/concepts/overlays-packages.md << 'EOF'
  ${docGen.overlayPackages { inherit pkgs lib; }}
  EOF
  # ... repeat for each reference page
'';
```

- [ ] **Step 4: Add docs-site combined derivation**

```nix
docs-site = pkgs.runCommand "docs-site" {} ''
  cp -r ${docs-site-prose} $out
  chmod -R u+w $out
  mkdir -p $out/generated
  cp -r ${docs-site-snippets}/* $out/generated/
  # Overlay reference pages into the structure
  cp -r ${docs-site-reference}/concepts/* $out/concepts/
  cp -r ${docs-site-reference}/guides/* $out/guides/
  cp -r ${docs-site-reference}/reference/* $out/reference/
'';
```

- [ ] **Step 5: Verify**

```bash
nix build .#docs-site --print-out-paths
ls $(nix build .#docs-site --print-out-paths)/
```

Expected: complete `docs/src/` directory structure with all pages.

- [ ] **Step 6: Format and commit**

```bash
treefmt flake.nix dev/generate.nix
git add flake.nix dev/generate.nix
git commit -m "feat(flake): add doc site generation derivations

docs-site-prose, docs-site-snippets, docs-site-reference, docs-site.
All cached by nix store."
```

---

### Task 11: Create doc site devenv tasks and wire devenv up

**Files:**

- Modify: `dev/tasks/generate.nix`
- Modify: `devenv.nix`

- [ ] **Step 1: Add site generation tasks**

In `dev/tasks/generate.nix`, add:

```nix
"generate:site:prose" = {
  description = "Copy authored prose to docs/src/";
  before = ["generate:site"];
  exec = ''
    ${bashPreamble}
    ${log}
    log "Copying prose to docs/src/"
    src=$(nix build .#docs-site-prose --no-link --print-out-paths)
    rm -rf docs/src
    cp -rL "$src" docs/src
    chmod -R u+w docs/src
    log "Prose copied"
  '';
};

"generate:site:snippets" = {
  description = "Generate data table snippets for doc site";
  after = ["generate:site:prose"];
  before = ["generate:site"];
  exec = ''
    ${bashPreamble}
    ${log}
    log "Generating snippets"
    src=$(nix build .#docs-site-snippets --no-link --print-out-paths)
    mkdir -p docs/src/generated
    cp -rL "$src"/* docs/src/generated/
    chmod -R u+w docs/src/generated
    log "Snippets generated"
  '';
};

"generate:site:reference" = {
  description = "Generate reference pages for doc site";
  after = ["generate:site:prose"];
  before = ["generate:site"];
  exec = ''
    ${bashPreamble}
    ${log}
    log "Generating reference pages"
    src=$(nix build .#docs-site-reference --no-link --print-out-paths)
    for dir in concepts guides reference; do
      if [ -d "$src/$dir" ]; then
        cp -rL "$src/$dir"/* "docs/src/$dir/"
        chmod -R u+w "docs/src/$dir/"
      fi
    done
    log "Reference pages generated"
  '';
};

"generate:site" = {
  description = "Generate complete doc site";
  after = [
    "generate:site:prose"
    "generate:site:snippets"
    "generate:site:reference"
  ];
  exec = ''
    ${bashPreamble}
    ${log}
    log "Doc site generation complete"
  '';
};

"generate:all" = {
  description = "Generate all content (instructions + repo + site)";
  after = [
    "generate:instructions"
    "generate:repo"
    "generate:site"
  ];
  exec = ''
    ${bashPreamble}
    ${log}
    log "All generation complete"
  '';
};
```

- [ ] **Step 2: Wire devenv up docs**

In `devenv.nix`, update the docs process to run generation first:

```nix
processes.docs.exec = ''
  devenv tasks run generate:site
  ${pkgs.mdbook}/bin/mdbook serve docs/ --open
'';
```

Or if `devenv tasks run` isn't available inside a process, use
`nix build` directly:

```nix
processes.docs.exec = let
  gen = import ./dev/generate.nix {inherit lib; pkgs = contentPkgs;};
in ''
  # Generate site content
  src=$(nix build .#docs-site --no-link --print-out-paths)
  rm -rf docs/src
  cp -rL "$src" docs/src
  chmod -R u+w docs/src
  # Serve
  ${pkgs.mdbook}/bin/mdbook serve docs/ --open
'';
```

- [ ] **Step 3: Verify**

```bash
devenv tasks run generate:site
ls docs/src/
${pkgs.mdbook}/bin/mdbook build docs/
```

Then test hot reload:

```bash
devenv up docs &
# Edit a file in dev/docs/, run generate:site:prose, check browser
```

- [ ] **Step 4: Format and commit**

```bash
treefmt dev/tasks/generate.nix devenv.nix
git add dev/tasks/generate.nix devenv.nix
git commit -m "feat(generate): add doc site devenv tasks and wire devenv up docs

generate:site:{prose,snippets,reference} tasks and generate:all meta.
devenv up docs generates site before serving."
```

---

### Task 12: Add {{#include}} markers to mixed pages

**Files:**

- Modify: `dev/docs/getting-started/home-manager.md`
- Modify: `dev/docs/getting-started/devenv.md`
- Modify: other mixed pages as identified

- [ ] **Step 1: Identify data tables in mixed pages**

For each mixed page in `dev/docs/`, find the hand-maintained tables
that should come from generated snippets. Replace them with
`{{#include}}` markers pointing to `generated/snippets/<name>.md`.

- [ ] **Step 2: Update each mixed page**

For example, in `dev/docs/getting-started/home-manager.md`, replace
the overlay table with:

```markdown
{{#include ../../generated/snippets/overlay-table.md}}
```

The path is relative to the markdown file's location in `docs/src/`.

- [ ] **Step 3: Regenerate and verify**

```bash
devenv tasks run generate:site
mdbook build docs/
```

Check that the built site renders correctly with includes resolved.

- [ ] **Step 4: Commit**

```bash
git add dev/docs/
git commit -m "refactor(docs): replace hand-maintained tables with generated includes

Mixed pages in dev/docs/ now use {{#include}} for data tables.
Tables generated from nix eval via generate:site:snippets."
```

---

### Task 13: Final verification

**Files:**

- None modified

- [ ] **Step 1: Full generation**

```bash
devenv tasks run generate:all
```

- [ ] **Step 2: Build doc site**

```bash
mdbook build docs/
```

- [ ] **Step 3: Verify all instruction files**

```bash
nix flake check --no-build
devenv test
```

- [ ] **Step 4: Visual check**

```bash
devenv up docs
```

Open browser, navigate through all pages, verify content renders.

- [ ] **Step 5: Commit any final fixes**

```bash
git add -A
git commit -m "fix(generate): final adjustments for generated docs pipeline"
```
