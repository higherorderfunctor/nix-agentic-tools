# Fragment FP Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the fragment system into a target-agnostic core (`lib/fragments.nix`) with a topic package (`packages/fragments-ai/`) that bundles AI ecosystem transforms via passthru, unifying two parallel transform systems.

**Architecture:** Core `lib/fragments.nix` exports `mkFragment`, `compose`, `mkFrontmatter`, and `render`. The new `packages/fragments-ai/` overlay package bundles curried transform factories (`claude`, `copilot`, `kiro`, `agentsmd`) in passthru. Frontmatter generators are removed from `lib/ai-common.nix` and all 6 caller files migrate to the new API.

**Tech Stack:** Nix (pure functions, overlays, NixOS modules)

**Spec:** `docs/superpowers/specs/2026-04-06-fragment-fp-refactor.md`

---

### Task 0: Capture baseline output

Capture current generated instruction files so we can verify
byte-identical output after the refactor.

**Files:**

- None modified

- [ ] **Step 1: Generate current instruction files**

```bash
nix run .#generate
```

- [ ] **Step 2: Capture baseline files**

```bash
mkdir -p /tmp/fragment-refactor-baseline
cp .claude/rules/*.md /tmp/fragment-refactor-baseline/
cp .github/copilot-instructions.md /tmp/fragment-refactor-baseline/
cp .github/instructions/*.md /tmp/fragment-refactor-baseline/
cp .kiro/steering/*.md /tmp/fragment-refactor-baseline/
cp AGENTS.md /tmp/fragment-refactor-baseline/
```

- [ ] **Step 3: Verify baseline exists**

```bash
ls -la /tmp/fragment-refactor-baseline/
```

Expected: 10+ files (common.md + per-package files per ecosystem + AGENTS.md).

---

### Task 1: Add `render` to core and remove ecosystem dispatch

**Files:**

- Modify: `lib/fragments.nix`

- [ ] **Step 1: Add `render` function**

Add after the `compose` function in `lib/fragments.nix`:

```nix
  # Apply a transform to a composed fragment.
  # transform is a curried function: fragment -> string
  render = {
    composed,
    transform,
  }:
    transform composed;
```

- [ ] **Step 2: Remove `ecosystems` map and `mkEcosystemContent`**

Remove the entire `ecosystems` attrset (lines 16-42) and the
`mkEcosystemContent` function (lines 102-114).

- [ ] **Step 3: Update exports**

Change the final `in` block from:

```nix
in {
  inherit compose ecosystems mkEcosystemContent mkFragment mkFrontmatter;
}
```

To:

```nix
in {
  inherit compose mkFragment mkFrontmatter render;
}
```

- [ ] **Step 4: Format**

```bash
treefmt lib/fragments.nix
```

- [ ] **Step 5: Verify the file evaluates**

```bash
nix eval --expr 'let lib = (import <nixpkgs> {}).lib; f = import ./lib/fragments.nix { inherit lib; }; in builtins.attrNames f'
```

Expected: `[ "compose" "mkFragment" "mkFrontmatter" "render" ]`

- [ ] **Step 6: Commit**

```bash
git add lib/fragments.nix
git commit -m "refactor(fragments): add render, remove ecosystem dispatch

Core is now target-agnostic. mkEcosystemContent and ecosystems map
removed — transforms move to packages/fragments-ai in next commit."
```

---

### Task 2: Create `packages/fragments-ai/` overlay package

**Files:**

- Create: `packages/fragments-ai/default.nix`
- Create: `packages/fragments-ai/templates/claude.md`
- Create: `packages/fragments-ai/templates/copilot.md`
- Create: `packages/fragments-ai/templates/kiro.md`

- [ ] **Step 1: Create the overlay package**

Create `packages/fragments-ai/default.nix`:

```nix
# AI ecosystem transforms — curried frontmatter generators.
# Derivation: pkgs.fragments-ai
# passthru.transforms provides eval-time access to transform factories.
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
  inherit (fragmentsLib) mkFrontmatter;
  inherit (final) lib;
in {
  fragments-ai =
    final.runCommand "fragments-ai" {} ''
      mkdir -p $out/templates
      cp ${./templates}/*.md $out/templates/
    ''
    // {
      passthru.transforms = {
        # Claude Code: ---\ndescription: ...\npaths: ...\n---
        # Usage: transforms.claude { package = "my-app"; } fragment
        claude = {package}: fragment: let
          desc =
            if (fragment.description or null) != null
            then fragment.description
            else "Instructions for the ${package} package";
          pathsAttr = fragment.paths or null;
          fm =
            if pathsAttr == null
            then null
            else
              {
                description = desc;
                paths = pathsAttr;
              };
          fmStr =
            if fm == null
            then ""
            else mkFrontmatter fm + "\n";
        in
          fmStr + fragment.text;

        # Copilot: ---\napplyTo: "paths or **"\n---
        # Usage: transforms.copilot {} fragment
        copilot = {}: fragment: let
          pathsAttr = fragment.paths or null;
          applyTo =
            if pathsAttr == null
            then ''"**"''
            else pathsAttr;
        in
          mkFrontmatter {inherit applyTo;} + "\n" + fragment.text;

        # Kiro: ---\nname: ...\ninclusion: ...\n---
        # Usage: transforms.kiro { name = "my-rule"; } fragment
        kiro = {name}: fragment: let
          pathsAttr = fragment.paths or null;
          inclusion =
            if pathsAttr != null
            then "fileMatch"
            else "always";
          descAttr = fragment.description or null;
          fm =
            {
              inherit inclusion name;
            }
            // lib.optionalAttrs (descAttr != null) {
              description = descAttr;
            }
            // lib.optionalAttrs (pathsAttr != null) {
              fileMatchPattern = pathsAttr;
            };
        in
          mkFrontmatter fm + "\n" + fragment.text;

        # AGENTS.md: identity (no frontmatter)
        # Usage: transforms.agentsmd {} fragment
        agentsmd = {}: fragment: fragment.text;
      };
    };
}
```

- [ ] **Step 2: Create template files**

Create `packages/fragments-ai/templates/claude.md`:

```markdown
---
description: Instructions for the example package
paths: "src/**"
---

Example Claude Code instruction file generated by fragments-ai transforms.
```

Create `packages/fragments-ai/templates/copilot.md`:

```markdown
---
applyTo: "**"
---

Example Copilot instruction file generated by fragments-ai transforms.
```

Create `packages/fragments-ai/templates/kiro.md`:

```markdown
---
name: example
description: Example steering document
inclusion: always
---

Example Kiro steering file generated by fragments-ai transforms.
```

- [ ] **Step 3: Register in flake overlays**

In `flake.nix`, add `fragments-ai` to the overlays:

Add to the `overlays` attrset (alphabetically):

```nix
fragments-ai = import ./packages/fragments-ai {};
```

Add to the `default` overlay's `composeManyExtensions` list
(alphabetically between `coding-standards` and `git-tools`):

```nix
(import ./packages/fragments-ai {})
```

- [ ] **Step 4: Export as a package**

In `flake.nix`, in the `packages` output section, add:

```nix
inherit (pkgs) fragments-ai;
```

- [ ] **Step 5: Format**

```bash
treefmt packages/fragments-ai/default.nix flake.nix
```

- [ ] **Step 6: Verify the package evaluates**

```bash
nix eval .#fragments-ai.name
```

Expected: `"fragments-ai"`

```bash
nix eval --json .#fragments-ai.passthru.transforms --apply builtins.attrNames
```

Expected: `["agentsmd","claude","copilot","kiro"]`

- [ ] **Step 7: Commit**

```bash
git add packages/fragments-ai/ flake.nix
git commit -m "feat(fragments-ai): add AI ecosystem transform package

Curried transform factories for claude, copilot, kiro, agentsmd.
Each takes context args and returns fragment -> string."
```

---

### Task 3: Reconcile frontmatter output formats

Before migrating callers, verify that `fragments-ai` transforms produce
the same output as both the old `mkEcosystemContent` and the old
`mkClaudeRule`/`mkCopilotInstruction`/`mkKiroSteering`. Fix any
divergence.

**Files:**

- Possibly modify: `packages/fragments-ai/default.nix`

- [ ] **Step 1: Test claude transform against mkEcosystemContent**

```bash
nix eval --raw --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    fragmentsLib = import ./lib/fragments.nix { inherit lib; };
    aiPkg = (import ./packages/fragments-ai {} lib.id {}).fragments-ai;
    transforms = aiPkg.passthru.transforms;
    frag = fragmentsLib.mkFragment {
      text = "test content";
      paths = "\"src/**\"";
    };
  in transforms.claude { package = "test-pkg"; } frag
'
```

Compare output format against what the old `mkEcosystemContent` produced
for Claude (from the old `ecosystems.claude.mkFrontmatter`). The old
system produced:

```
---
description: Instructions for the test-pkg package
paths: "src/**"
---

test content
```

- [ ] **Step 2: Test against mkClaudeRule from ai-common.nix**

The old `mkClaudeRule` takes `{ text, description, paths }` where
`description` is a string (empty string = no description) and `paths`
is a list or null. Test with the instruction submodule shape:

```bash
nix eval --raw --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    aiPkg = (import ./packages/fragments-ai {} lib.id {}).fragments-ai;
    transforms = aiPkg.passthru.transforms;
    instr = {
      text = "test content";
      description = "Test desc";
      paths = ["src/**" "lib/**"];
    };
  in transforms.claude { package = "test-pkg"; } instr
'
```

The old `mkClaudeRule` produced:

```
---
description: Test desc
paths:
  - "src/**"
  - "lib/**"
---

test content
```

Note the difference: old `mkClaudeRule` uses YAML list format for paths
(`paths:\n  - "..."`) while old `mkEcosystemContent` uses a single
string (`paths: "src/**"`). The new transforms must handle **both**
input shapes — paths as a string (from fragments) and paths as a list
(from instruction submodules).

- [ ] **Step 3: Adjust transforms to handle both path formats**

In `packages/fragments-ai/default.nix`, the `claude` transform must
check if `paths` is a list or a string and format accordingly:

```nix
claude = {package}: fragment: let
  desc =
    if (fragment.description or null) != null && fragment.description != ""
    then fragment.description
    else "Instructions for the ${package} package";
  pathsAttr = fragment.paths or null;
  pathsYaml =
    if pathsAttr == null
    then null
    else if builtins.isList pathsAttr
    then lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") pathsAttr
    else pathsAttr;
  fm =
    if pathsAttr == null
    then null
    else {};
  fmStr =
    if pathsAttr == null
    then ""
    else
      "---\n"
      + "description: ${desc}\n"
      + (
        if builtins.isList pathsAttr
        then "paths:\n${pathsYaml}\n"
        else "paths: ${pathsAttr}\n"
      )
      + "---\n\n";
in
  fmStr + fragment.text;
```

Similarly adjust `copilot` and `kiro` for list vs string paths. The
`copilot` transform needs to handle `paths` as either a list (join
with `,`) or a string. The `kiro` transform needs the same.

- [ ] **Step 4: Handle description = "" (ai-common compat)**

The old `mkClaudeRule` treats `description = ""` as "no description"
(omits it from frontmatter). The old `mkEcosystemContent` always
includes description. Align to the `mkClaudeRule` behavior: empty
string = omit. The new transform already handles this if we check
`!= ""` in addition to `!= null`.

- [ ] **Step 5: Test all four transforms with both input shapes**

Run eval tests for each transform with:

1. A fragment (`{ text, paths = "\"src/**\""; }`) — string paths
2. An instruction (`{ text, description = "desc"; paths = ["src/**"]; }`) — list paths
3. Null paths (`{ text, description = ""; }`) — no paths

Verify output matches the old system for each case.

- [ ] **Step 6: Format and commit if changes were needed**

```bash
treefmt packages/fragments-ai/default.nix
git add packages/fragments-ai/default.nix
git commit -m "fix(fragments-ai): reconcile frontmatter format with ai-common

Handle both list and string paths inputs. Treat empty description
as omit. Matches output of both mkEcosystemContent and mkClaudeRule."
```

---

### Task 4: Remove frontmatter generators from `lib/ai-common.nix`

**Files:**

- Modify: `lib/ai-common.nix`

- [ ] **Step 1: Remove mkClaudeRule, mkCopilotInstruction, mkKiroSteering**

Remove lines 99-153 from `lib/ai-common.nix` (the three frontmatter
generator functions and their section comment).

- [ ] **Step 2: Format**

```bash
treefmt lib/ai-common.nix
```

- [ ] **Step 3: Commit**

```bash
git add lib/ai-common.nix
git commit -m "refactor(ai-common): remove frontmatter generators

mkClaudeRule, mkCopilotInstruction, mkKiroSteering now live in
packages/fragments-ai as curried transforms."
```

Note: This commit will temporarily break callers. That's OK — we fix
them in the next tasks. If you prefer no broken intermediate commits,
combine Tasks 4-7 into a single commit at the end.

---

### Task 5: Migrate HM `modules/ai/default.nix`

**Files:**

- Modify: `modules/ai/default.nix`

- [ ] **Step 1: Replace ai-common imports**

Change line 39-40 from:

```nix
  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkClaudeRule mkCopilotInstruction mkCopilotLspConfig mkKiroSteering mkLspConfig;
```

To:

```nix
  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;
  aiTransforms = pkgs.fragments-ai.passthru.transforms;
```

- [ ] **Step 2: Replace mkClaudeRule call**

Change line 192 from:

```nix
text = mkDefault (mkClaudeRule name instr);
```

To:

```nix
text = mkDefault (aiTransforms.claude {package = name;} instr);
```

- [ ] **Step 3: Replace mkCopilotInstruction call**

Change line 220 from:

```nix
mkDefault (mkCopilotInstruction name instr))
```

To:

```nix
mkDefault (aiTransforms.copilot {} instr))
```

- [ ] **Step 4: Replace mkKiroSteering call**

Change line 250 from:

```nix
mkDefault (mkKiroSteering name instr))
```

To:

```nix
mkDefault (aiTransforms.kiro {inherit name;} instr))
```

- [ ] **Step 5: Format**

```bash
treefmt modules/ai/default.nix
```

- [ ] **Step 6: Commit**

```bash
git add modules/ai/default.nix
git commit -m "refactor(ai): migrate HM module to fragments-ai transforms"
```

---

### Task 6: Migrate devenv `modules/devenv/ai.nix`

**Files:**

- Modify: `modules/devenv/ai.nix`

- [ ] **Step 1: Replace ai-common imports**

Change lines 40-41 from:

```nix
  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkClaudeRule mkCopilotInstruction mkCopilotLspConfig mkKiroSteering mkLspConfig;
```

To:

```nix
  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;
  aiTransforms = pkgs.fragments-ai.passthru.transforms;
```

- [ ] **Step 2: Replace mkClaudeRule call**

Change line 164 from:

```nix
".claude/rules/${name}.md".text = mkDefault (mkClaudeRule name instr);
```

To:

```nix
".claude/rules/${name}.md".text = mkDefault (aiTransforms.claude {package = name;} instr);
```

- [ ] **Step 3: Replace mkCopilotInstruction call**

Change line 188 from:

```nix
mkDefault (mkCopilotInstruction name instr))
```

To:

```nix
mkDefault (aiTransforms.copilot {} instr))
```

- [ ] **Step 4: Replace mkKiroSteering call**

Change line 217 from:

```nix
mkDefault (mkKiroSteering name instr))
```

To:

```nix
mkDefault (aiTransforms.kiro {inherit name;} instr))
```

- [ ] **Step 5: Format**

```bash
treefmt modules/devenv/ai.nix
```

- [ ] **Step 6: Commit**

```bash
git add modules/devenv/ai.nix
git commit -m "refactor(devenv): migrate ai module to fragments-ai transforms"
```

---

### Task 7: Migrate `modules/stacked-workflows/default.nix`

**Files:**

- Modify: `modules/stacked-workflows/default.nix`

- [ ] **Step 1: Remove ai-common import**

Change lines 17-18 from:

```nix
  fragments = import ../../lib/fragments.nix {inherit lib;};
  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
```

To:

```nix
  fragments = import ../../lib/fragments.nix {inherit lib;};
  aiTransforms = pkgs.fragments-ai.passthru.transforms;
```

- [ ] **Step 2: Replace transform calls**

Change lines 28-30 from:

```nix
    instructionsClaude = aiCommon.mkClaudeRule "stacked-workflows" composed;
    instructionsCopilot = aiCommon.mkCopilotInstruction "stacked-workflows" composed;
    instructionsKiro = aiCommon.mkKiroSteering "stacked-workflows" composed;
```

To:

```nix
    instructionsClaude = aiTransforms.claude {package = "stacked-workflows";} composed;
    instructionsCopilot = aiTransforms.copilot {} composed;
    instructionsKiro = aiTransforms.kiro {name = "stacked-workflows";} composed;
```

- [ ] **Step 3: Format**

```bash
treefmt modules/stacked-workflows/default.nix
```

- [ ] **Step 4: Commit**

```bash
git add modules/stacked-workflows/default.nix
git commit -m "refactor(stacked-workflows): migrate to fragments-ai transforms"
```

---

### Task 8: Migrate `flake.nix` lib exports and generate app

**Files:**

- Modify: `flake.nix`

- [ ] **Step 1: Update lib exports**

In the `lib` output section (around line 80-115), change:

Remove from the lib output:

```nix
inherit (aiCommon) mkClaudeRule mkCopilotInstruction mkKiroSteering;
```

And:

```nix
inherit (fragments) compose mkEcosystemContent mkFragment mkFrontmatter;
```

Replace with:

```nix
inherit (fragments) compose mkFragment mkFrontmatter render;
```

The `aiCommon` import at line 81 can stay (it still exports other
things used by lib like `mkLspConfig`). But remove the three
frontmatter generators from its re-exports.

- [ ] **Step 2: Update generate app — replace mkEcosystemFile helper**

In the `apps` section (around line 117-225), the `mkEcosystemFile`
helper at line 155-159 currently uses `fragments.mkEcosystemContent`.

First, add access to the AI transforms near the top of the apps let
block (after `pkgs = pkgsFor system;`):

```nix
aiTransforms = pkgs.fragments-ai.passthru.transforms;
```

Then replace the `mkEcosystemFile` helper:

From:

```nix
mkEcosystemFile = ecosystem: package: composed:
  fragments.mkEcosystemContent {
    inherit ecosystem package composed;
    paths = packagePaths.${package} or null;
  };
```

To:

```nix
mkEcosystemFile = package: let
  paths = packagePaths.${package} or null;
  withPaths = composed:
    if paths != null
    then composed // {inherit paths;}
    else composed;
in {
  claude = composed: aiTransforms.claude {inherit package;} (withPaths composed);
  copilot = composed: aiTransforms.copilot {} (withPaths composed);
  kiro = composed: aiTransforms.kiro {name = package;} (withPaths composed);
  agentsmd = composed: aiTransforms.agentsmd {} (withPaths composed);
};
```

- [ ] **Step 3: Update generate app — update all mkEcosystemFile callers**

The generate script builds heredocs per ecosystem. Update each call
site. For example, the root composed section changes from:

```nix
claudeCommon = mkEcosystemFile "claude" "monorepo" rootComposed;
kiroCommon = mkEcosystemFile "kiro" "monorepo" rootComposed;
copilotCommon = mkEcosystemFile "copilot" "monorepo" rootComposed;
```

To:

```nix
monorepoEco = mkEcosystemFile "monorepo";
claudeCommon = monorepoEco.claude rootComposed;
kiroCommon = monorepoEco.kiro rootComposed;
copilotCommon = monorepoEco.copilot rootComposed;
```

And the per-package loop changes from:

```nix
claude = mkEcosystemFile "claude" pkg composed;
kiro = mkEcosystemFile "kiro" pkg composed;
copilot = mkEcosystemFile "copilot" pkg composed;
```

To:

```nix
pkgEco = mkEcosystemFile pkg;
claude = pkgEco.claude composed;
kiro = pkgEco.kiro composed;
copilot = pkgEco.copilot composed;
```

- [ ] **Step 4: Format**

```bash
treefmt flake.nix
```

- [ ] **Step 5: Commit**

```bash
git add flake.nix
git commit -m "refactor(flake): migrate lib exports and generate app to fragments-ai"
```

---

### Task 9: Migrate `devenv.nix` file generation

**Files:**

- Modify: `devenv.nix`

- [ ] **Step 1: Update fragment imports**

Near the top of the `let` block (around line 15), where fragments is
imported, add access to AI transforms:

```nix
aiTransforms = contentPkgs.fragments-ai.passthru.transforms;
```

Note: `contentPkgs` applies overlays manually. Add `fragments-ai` to
the `composeManyExtensions` list:

```nix
contentPkgs = pkgs.extend (lib.composeManyExtensions [
  (import ./packages/coding-standards {})
  (import ./packages/fragments-ai {})
  (import ./packages/stacked-workflows {})
]);
```

- [ ] **Step 2: Replace mkEcosystemFile helper**

Replace the `mkEcosystemFile` helper (around line 65-69) from:

```nix
mkEcosystemFile = ecosystem: package: composed:
  fragments.mkEcosystemContent {
    inherit ecosystem package composed;
    paths = packagePaths.${package} or null;
  };
```

To the same pattern as flake.nix:

```nix
mkEcosystemFile = package: let
  paths = packagePaths.${package} or null;
  withPaths = composed:
    if paths != null
    then composed // {inherit paths;}
    else composed;
in {
  claude = composed: aiTransforms.claude {inherit package;} (withPaths composed);
  copilot = composed: aiTransforms.copilot {} (withPaths composed);
  kiro = composed: aiTransforms.kiro {name = package;} (withPaths composed);
};
```

- [ ] **Step 3: Update mkEcosystemFiles callers**

Update the `mkEcosystemFiles` let block (around line 90-105) to use
the new helper shape. Change from:

```nix
mkEcosystemFiles = let
  rootComposed = mkDevComposed "monorepo";
in
  {
    ".claude/rules/common.md".text = mkEcosystemFile "claude" "monorepo" rootComposed;
    ".github/copilot-instructions.md".text = mkEcosystemFile "copilot" "monorepo" rootComposed;
    ".kiro/steering/common.md".text = mkEcosystemFile "kiro" "monorepo" rootComposed;
  }
  // ...
```

To:

```nix
mkEcosystemFiles = let
  rootComposed = mkDevComposed "monorepo";
  monorepoEco = mkEcosystemFile "monorepo";
in
  {
    ".claude/rules/common.md".text = monorepoEco.claude rootComposed;
    ".github/copilot-instructions.md".text = monorepoEco.copilot rootComposed;
    ".kiro/steering/common.md".text = monorepoEco.kiro rootComposed;
  }
  // (lib.concatMapAttrs (pkg: _: let
      composed = mkDevComposed pkg;
      pkgEco = mkEcosystemFile pkg;
    in {
      ".claude/rules/${pkg}.md".text = pkgEco.claude composed;
      ".github/instructions/${pkg}.instructions.md".text = pkgEco.copilot composed;
      ".kiro/steering/${pkg}.md".text = pkgEco.kiro composed;
    })
    nonRootPackages);
```

- [ ] **Step 4: Format**

```bash
treefmt devenv.nix
```

- [ ] **Step 5: Commit**

```bash
git add devenv.nix
git commit -m "refactor(devenv): migrate file generation to fragments-ai transforms"
```

---

### Task 10: Verify byte-identical output

**Files:**

- None modified

- [ ] **Step 1: Run flake check**

```bash
nix flake check
```

Expected: all checks pass.

- [ ] **Step 2: Run devenv test**

```bash
devenv test
```

Expected: passes.

- [ ] **Step 3: Regenerate instruction files and diff**

```bash
nix run .#generate
diff -r /tmp/fragment-refactor-baseline/ . --include='*.md' -x 'node_modules' 2>/dev/null | head -50
```

Compare each file:

```bash
for f in /tmp/fragment-refactor-baseline/*; do
  name=$(basename "$f")
  # Find the matching file in the repo
  match=$(find .claude/rules .github .kiro/steering -name "$name" 2>/dev/null | head -1)
  if [ "$name" = "AGENTS.md" ]; then match="./AGENTS.md"; fi
  if [ -n "$match" ]; then
    if diff -q "$f" "$match" > /dev/null 2>&1; then
      echo "PASS: $name"
    else
      echo "FAIL: $name"
      diff "$f" "$match" | head -20
    fi
  else
    echo "MISSING: $name"
  fi
done
```

Expected: all files PASS.

- [ ] **Step 4: If any files FAIL, fix the transforms**

Go back to `packages/fragments-ai/default.nix` and adjust the
transform that produces different output. Common issues:

- Trailing newline differences
- YAML frontmatter key ordering
- Quoting differences in paths

- [ ] **Step 5: Clean up baseline**

```bash
rm -rf /tmp/fragment-refactor-baseline
```

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix(fragments-ai): align transform output with baseline"
```

---

### Task 11: Update CLAUDE.md and docs references

**Files:**

- Modify: `CLAUDE.md` (if it references `mkEcosystemContent` or the old API)
- Modify: `docs/src/reference/lib-api.md` (if it documents the old API)

- [ ] **Step 1: Grep for stale references**

```bash
grep -r 'mkEcosystemContent\|mkClaudeRule\|mkCopilotInstruction\|mkKiroSteering' \
  CLAUDE.md AGENTS.md docs/ dev/ packages/stacked-workflows/references/ \
  --include='*.md' -l
```

- [ ] **Step 2: Update any stale references found**

Replace mentions of the old API with the new `render` + transforms
pattern. Update code examples if present.

- [ ] **Step 3: Format and commit**

```bash
treefmt <changed files>
git add <changed files>
git commit -m "docs: update references to new fragment transform API"
```
