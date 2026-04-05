# Composable Fragment Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the static fragment pipeline into a composable library where fragments are first-class packages, consumers compose from presets, and this repo eats its own cooking.

**Architecture:** Fragments are typed attrsets (text + metadata) backed by markdown files. Composition functions live in `lib/`. Consumable fragment content lives in `packages/` as derivations (like skills already do). The `ai.*` module and devenv both derive instructions from the same library. Frontmatter generation is decoupled and exposed for consumers.

**Tech Stack:** Nix (alejandra format), markdown fragments, NixOS module system types

---

## Key Design Decisions

1. **Fragment packages under `packages/`** — consumable exports are derivations, not raw lib. `packages/fragments/common/` for shared fragments, stacked-workflows package already has skills/references/fragments.
2. **`lib/fragments.nix` provides composition** — `compose`, `mkFragment`, type definitions. Lib is functions, packages are data.
3. **Existing `instructionModule` type is the fragment type** — it already has `text`, `description`, `paths`. We extend it with `priority` for ordering. No new type explosion.
4. **Self-cooking** — devenv.nix and apps.generate refactored to use the same compose + frontmatter functions consumers use.
5. **Frontmatter generators exposed in `flake.nix` lib** — consumers can generate ecosystem files without importing modules.
6. **TODO: research moving HM/devenv modules into packages** — deferred, just leave a note in plan.md.

## File Structure

```
lib/fragments.nix              — MODIFY: add compose, mkFragment; keep read helpers
lib/ai-common.nix              — UNCHANGED (frontmatter generators already here)
packages/fragments/            — CREATE: new overlay group
packages/fragments/common.nix  — CREATE: package exposing common fragment attrset
packages/fragments/default.nix — CREATE: overlay entry point
flake.nix                      — MODIFY: add fragments overlay, expose lib functions
devenv.nix                     — MODIFY: self-cook with compose + mkFragment
apps/ (generate script)        — MODIFY: self-cook (in flake.nix apps section)
modules/stacked-workflows/     — MODIFY: consume from lib instead of raw fragment reads
docs/plan.md                   — MODIFY: mark done, add module-packages TODO
```

---

### Task 1: Extend lib/fragments.nix with compose and mkFragment

**Files:**

- Modify: `lib/fragments.nix`

This is the core: add `mkFragment` (constructor that returns an `instructionModule`-compatible attrset) and `compose` (merge multiple fragments into one).

- [ ] **Step 1: Add mkFragment constructor**

`mkFragment` takes `{ text, description?, paths?, priority? }` and returns a normalized fragment attrset. This is the canonical way to create a fragment — ensures all fields have defaults.

```nix
# Add to lib/fragments.nix, in the let block after existing code:

# Canonical fragment constructor. Returns an instructionModule-compatible attrset.
# Consumers use this to create fragments; compose operates on these.
mkFragment = {
  text,
  description ? "",
  paths ? null,
  priority ? 0,
}: {
  inherit text description paths priority;
};
```

- [ ] **Step 2: Add compose function**

`compose` takes a list of fragments, sorts by priority (higher = earlier), deduplicates by text content hash, and concatenates into a single fragment.

```nix
# Add to lib/fragments.nix, after mkFragment:

# Compose multiple fragments into one. Higher priority = appears first.
# Deduplicates by text hash. Returns a single fragment (instructionModule-compatible).
compose = fragments: let
  # Sort: higher priority first, stable sort preserves input order for ties
  sorted = lib.sort (a: b: (a.priority or 0) > (b.priority or 0)) fragments;
  # Deduplicate by text content
  seen = builtins.foldl' (acc: frag: let
    h = builtins.hashString "sha256" frag.text;
  in
    if acc.hashes ? ${h}
    then acc
    else {
      hashes = acc.hashes // {${h} = true;};
      result = acc.result ++ [frag];
    }) {
    hashes = {};
    result = [];
  }
  sorted;
in
  mkFragment {
    text = builtins.concatStringsSep "\n\n" (map (f: f.text) seen.result);
  };
```

- [ ] **Step 3: Wrap existing readCommon/readPackage with mkFragment**

Add `readCommonFragment` and `readPackageFragment` that return typed fragments instead of raw strings. Keep the old functions for backward compat during migration.

```nix
# Add after the existing readCommon/readPackage:

readCommonFragment = name:
  mkFragment {
    text = readCommon name;
    description = "Common: ${name}";
    priority = 10; # common fragments sort first
  };

readPackageFragment = package: name:
  mkFragment {
    text = readPackage package name;
    description = "${package}: ${name}";
    priority = 5; # package fragments sort after common
  };
```

- [ ] **Step 4: Export new functions**

```nix
# Update the exports at the bottom of lib/fragments.nix:
in {
  inherit
    compose
    ecosystems
    mkContent
    mkFragment
    mkFrontmatter
    mkInstructions
    mkPackageContent
    packagePaths
    packageProfiles
    packagesWithProfile
    readCommon
    readCommonFragment
    readPackage
    readPackageFragment
    ;
}
```

- [ ] **Step 5: Format and verify evaluation**

```bash
treefmt lib/fragments.nix
nix flake check --no-build
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
git add lib/fragments.nix
git commit -m "feat(fragments): add compose, mkFragment, typed fragment readers"
```

---

### Task 2: Create common fragments package

**Files:**

- Create: `packages/fragments/default.nix`
- Create: `packages/fragments/common.nix`
- Modify: `flake.nix` (add overlay, export package)

This package exposes common fragments as a Nix attrset derivation. Consumers do `pkgs.agentic-fragments.common.coding-standards` to get a fragment.

- [ ] **Step 1: Create the overlay entry point**

```nix
# packages/fragments/default.nix
_: _final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {lib = _final.lib;};
  common = import ./common.nix {inherit fragmentsLib;};
in {
  agentic-fragments = {
    inherit common;
    inherit (fragmentsLib) compose mkFragment;
  };
}
```

- [ ] **Step 2: Create common.nix with all common fragments**

```nix
# packages/fragments/common.nix
{fragmentsLib}: {
  coding-standards = fragmentsLib.readCommonFragment "coding-standards";
  commit-convention = fragmentsLib.readCommonFragment "commit-convention";
  config-parity = fragmentsLib.readCommonFragment "config-parity";
  tooling-preference = fragmentsLib.readCommonFragment "tooling-preference";
  validation = fragmentsLib.readCommonFragment "validation";
}
```

- [ ] **Step 3: Register overlay in flake.nix**

Add `fragments` overlay alongside existing overlays, and compose into default:

```nix
# In flake.nix overlays section, add:
fragments = import ./packages/fragments {};

# Update default overlay:
default = lib.composeManyExtensions [
  (import ./packages/ai-clis {inherit inputs;})
  (import ./packages/fragments {})
  (import ./packages/git-tools {inherit inputs;})
  (import ./packages/mcp-servers {inherit inputs;})
];
```

- [ ] **Step 4: Export the package in flake.nix packages**

```nix
# In flake.nix packages section, add after AI CLIs:
# Fragments
inherit (pkgs) agentic-fragments;
```

Note: `agentic-fragments` is an attrset, not a derivation. This is fine — flake packages can be attrsets. But if `nix flake check` requires derivations only, we'll wrap it. Test first.

- [ ] **Step 5: Expose compose + frontmatter in flake.nix lib**

```nix
# In flake.nix lib section, update fragments export:
inherit fragments;
# becomes:
inherit fragments;
inherit (fragments) compose mkFragment;
# And from ai-common:
aiCommon = import ./lib/ai-common.nix {inherit lib;};
inherit (aiCommon) mkClaudeRule mkCopilotInstruction mkKiroSteering;
```

- [ ] **Step 6: Format and check**

```bash
treefmt packages/fragments/default.nix packages/fragments/common.nix flake.nix
nix flake check --no-build
```

If packages must be derivations, remove `agentic-fragments` from `packages` output and keep it accessible only via overlay (`pkgs.agentic-fragments`) and `lib.fragments`.

- [ ] **Step 7: Commit**

```bash
git add packages/fragments/ flake.nix
git commit -m "feat(fragments): add common fragments package and expose compose in lib"
```

---

### Task 3: Self-cook devenv.nix with compose

**Files:**

- Modify: `devenv.nix`

Replace the hardcoded `mkEcosystemFiles` pipeline with `compose` + frontmatter generators. The devenv should build its instructions the same way a consumer would.

- [ ] **Step 1: Refactor the let block to use compose**

Replace the `mkEcosystemFiles` helper with composition from fragments:

```nix
# In devenv.nix, replace mkEcosystemFiles with:
mkEcosystemFiles = let
  # Compose fragments per package using the same lib consumers use
  mkComposed = package: profile:
    fragments.compose (
      map fragments.readCommonFragment
        (fragments.packageProfiles.${package}.${profile}).common
      ++ map (fragments.readPackageFragment package)
        (fragments.packageProfiles.${package}.${profile}).package
    );

  aiCommon = import ./lib/ai-common.nix {inherit lib;};

  # Generate per-ecosystem file from a composed fragment
  mkEcosystemFile = ecosystem: package: composed: let
    fm = fragments.ecosystems.${ecosystem}.mkFrontmatter package;
    fmStr =
      if fm == null
      then ""
      else fragments.mkFrontmatter fm + "\n";
  in
    fmStr + composed.text;

  rootComposed = mkComposed "monorepo" "dev";
in
  {
    ".claude/rules/common.md".text = mkEcosystemFile "claude" "monorepo" rootComposed;
    ".kiro/steering/common.md".text = mkEcosystemFile "kiro" "monorepo" rootComposed;
    ".github/copilot-instructions.md".text = mkEcosystemFile "copilot" "monorepo" rootComposed;
  }
  // (lib.concatMapAttrs (pkg: _: let
      composed = mkComposed pkg "dev";
    in {
      ".claude/rules/${pkg}.md".text = mkEcosystemFile "claude" pkg composed;
      ".kiro/steering/${pkg}.md".text = mkEcosystemFile "kiro" pkg composed;
      ".github/instructions/${pkg}.instructions.md".text = mkEcosystemFile "copilot" pkg composed;
    })
    nonRootPackages);
```

- [ ] **Step 2: Refactor AGENTS.md generation similarly**

```nix
# Replace agentsBase/agentsPackageContent/agentsContent with:
agentsContent = let
  rootComposed = mkComposed "monorepo" "dev";
  packageContents = lib.mapAttrsToList (pkg: _: let
    prof = fragments.packageProfiles.${pkg}."dev";
    pkgFragments = map (fragments.readPackageFragment pkg) prof.package;
    composed = fragments.compose pkgFragments;
  in
    composed.text)
  nonRootPackages;
in
  rootComposed.text
  + lib.optionalString (packageContents != [])
    ("\n" + builtins.concatStringsSep "\n" packageContents);
```

- [ ] **Step 3: Format and test**

```bash
treefmt devenv.nix
devenv test
```

Expected: all tests pass, generated files are identical to before.

- [ ] **Step 4: Commit**

```bash
git add devenv.nix
git commit -m "refactor(devenv): self-cook instruction files via fragments.compose"
```

---

### Task 4: Self-cook apps.generate with compose

**Files:**

- Modify: `flake.nix` (apps section, lines ~88-170)

Same refactor as Task 3 but for the `nix run .#generate` app.

- [ ] **Step 1: Refactor the generate script**

The generate script currently uses `fragments.mkInstructions` and `fragments.mkPackageContent`. Refactor to use `compose` + ecosystem frontmatter, matching the devenv.nix pattern from Task 3.

The key change: replace `mkInstructions` calls with `compose` + frontmatter, keeping the shell heredoc output pattern.

- [ ] **Step 2: Format and verify**

```bash
treefmt flake.nix
nix flake check --no-build
nix run .#generate  # verify generated files match
```

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "refactor(generate): self-cook via fragments.compose"
```

---

### Task 5: Refactor stacked-workflows module to consume from lib

**Files:**

- Modify: `modules/stacked-workflows/default.nix`

The stacked-workflows HM module currently calls `fragments.mkInstructions` directly. Refactor to use `compose` so it follows the same pattern as devenv and consumers.

- [ ] **Step 1: Replace mkInstructions with compose + frontmatter**

```nix
# In modules/stacked-workflows/default.nix, replace self.instructionsClaude etc:
aiCommon = import ../../lib/ai-common.nix {inherit lib;};

composed = fragments.compose (
  map (fragments.readPackageFragment "stacked-workflows")
    (fragments.packageProfiles.stacked-workflows.package).package
);

self = {
  skillsDir = ../../skills;
  referencesDir = ../../references;
  instructionsClaude = aiCommon.mkClaudeRule "stacked-workflows" composed;
  instructionsCopilot = aiCommon.mkCopilotInstruction "stacked-workflows" composed;
  instructionsKiro = aiCommon.mkKiroSteering "stacked-workflows" composed;
  # ...rest unchanged
};
```

- [ ] **Step 2: Format and check**

```bash
treefmt modules/stacked-workflows/default.nix
nix flake check --no-build
```

- [ ] **Step 3: Commit**

```bash
git add modules/stacked-workflows/default.nix
git commit -m "refactor(stacked-workflows): consume fragments via compose"
```

---

### Task 6: Update plan.md and docs

**Files:**

- Modify: `docs/plan.md`

- [ ] **Step 1: Mark fragment library tasks as done**

Update the Solo section checkboxes for all completed items.

- [ ] **Step 2: Add TODO for module-to-packages research**

Add under Backlog:

```markdown
- [ ] Research moving HM/devenv modules into packages — would allow
      `pkgs.agentic-modules.ai`, `pkgs.agentic-modules.mcp-servers` etc.
      Currently modules live in `modules/` and are referenced by path in
      flake.nix homeManagerModules. Packaging them would make composition
      more FP but needs research on NixOS module packaging patterns.
```

- [ ] **Step 3: Add cspell terms if needed**

Check for any new terms introduced (e.g., `agentic-fragments`).

- [ ] **Step 4: Final format and full test**

```bash
treefmt docs/plan.md
nix flake check --no-build
devenv test
```

- [ ] **Step 5: Commit**

```bash
git add docs/plan.md .cspell/project-terms.txt
git commit -m "docs: mark fragment library done, add module-packages research TODO"
```

---

## Scope Notes

- **Module fragment exposure** (MCP servers contributing their own fragments) is deferred — it requires the module system to declare fragment options, which is a bigger change. The infrastructure (`compose`, `mkFragment`) lands now; module integration is a follow-up.
- **HM/devenv modules as packages** — TODO only, needs research on NixOS module packaging patterns.
- **Fragment content expansion** (code review, security, testing presets) — separate task after the infrastructure lands. The `common.nix` package currently wraps existing fragments only.
