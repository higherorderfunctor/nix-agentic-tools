# Package-Focused Fragment Restructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all published content (skills, references, fragments) into domain packages. Root-level `skills/`, `references/`, `fragments/` go away. Each package owns its content; consumers install from packages.

**Architecture:** Packages are derivations (`runCommand`) with `passthru.fragments.*` for eval-time composition. `lib/` provides pure functions (compose, mkFragment, frontmatter). Dev-only content stays in `dev/fragments/`. devenv/HM consume from packages.

**Tech Stack:** Nix overlays, `runCommand` derivations, passthru attrsets

---

## Target State

```
packages/
  stacked-workflows/            ← NEW content package
    default.nix                 ← overlay: derivation + passthru.fragments
    skills/
      stack-fix/SKILL.md
      stack-plan/SKILL.md
      stack-split/SKILL.md
      stack-submit/SKILL.md
      stack-summary/SKILL.md
      stack-test/SKILL.md
    references/
      git-absorb.md
      git-branchless.md
      git-revise.md
      nix-workflow.md
      philosophy.md
      recommended-config.md
    fragments/
      routing-table.md

  coding-standards/             ← NEW content package
    default.nix                 ← overlay: derivation + passthru.fragments
    fragments/
      coding-standards.md
      commit-convention.md
      config-parity.md
      tooling-preference.md
      validation.md

dev/
  fragments/                    ← dev-only, NOT exported
    monorepo/
      project-overview.md
    ai-clis/
      packaging-guide.md
    mcp-servers/
      overlay-guide.md
    stacked-workflows/
      development.md
  references/
    agnix.md                    ← agnix-specific, not SWS

DELETED:
  skills/                       ← moved to packages/stacked-workflows/
  references/                   ← split: SWS→package, agnix→dev
  fragments/                    ← split: published→packages, dev→dev/
  packages/fragments/           ← replaced by coding-standards + per-domain
```

---

### Task 1: Create packages/stacked-workflows/ content package

**Files:**
- Create: `packages/stacked-workflows/default.nix`
- Move: `skills/*` → `packages/stacked-workflows/skills/`
- Move: `references/{git-absorb,git-branchless,git-revise,nix-workflow,philosophy,recommended-config}.md` → `packages/stacked-workflows/references/`
- Move: `fragments/packages/stacked-workflows/routing-table.md` → `packages/stacked-workflows/fragments/`

- [ ] **Step 1: Create the package directory and move content**

```bash
mkdir -p packages/stacked-workflows/{skills,references,fragments}

# Skills
mv skills/stack-fix packages/stacked-workflows/skills/
mv skills/stack-plan packages/stacked-workflows/skills/
mv skills/stack-split packages/stacked-workflows/skills/
mv skills/stack-submit packages/stacked-workflows/skills/
mv skills/stack-summary packages/stacked-workflows/skills/
mv skills/stack-test packages/stacked-workflows/skills/

# SWS references (not agnix.md — that's dev-only)
mv references/git-absorb.md packages/stacked-workflows/references/
mv references/git-branchless.md packages/stacked-workflows/references/
mv references/git-revise.md packages/stacked-workflows/references/
mv references/nix-workflow.md packages/stacked-workflows/references/
mv references/philosophy.md packages/stacked-workflows/references/
mv references/recommended-config.md packages/stacked-workflows/references/

# Published fragment
mv fragments/packages/stacked-workflows/routing-table.md packages/stacked-workflows/fragments/
```

- [ ] **Step 2: Create the overlay default.nix**

The package is a real derivation (store path with files) plus passthru for eval-time composition:

```nix
# packages/stacked-workflows/default.nix
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
in {
  stacked-workflows-content = final.runCommand "stacked-workflows-content" {} ''
    mkdir -p $out/{fragments,references,skills}
    cp -r ${./fragments}/* $out/fragments/
    cp -r ${./references}/* $out/references/
    cp -r ${./skills}/* $out/skills/
  '' // {
    passthru = {
      fragments = {
        routing-table = fragmentsLib.mkFragment {
          text = builtins.readFile ./fragments/routing-table.md;
          description = "Stacked workflow skill routing table";
        };
      };
      # Direct path access for consumers who just need the dirs
      skillsDir = ./skills;
      referencesDir = ./references;
    };
  };
}
```

- [ ] **Step 3: Register overlay in flake.nix**

Add to overlays section (alphabetically) and compose into default:

```nix
overlays = {
  ...
  default = lib.composeManyExtensions [
    (import ./packages/ai-clis {inherit inputs;})
    (import ./packages/coding-standards {})
    (import ./packages/git-tools {inherit inputs;})
    (import ./packages/mcp-servers {inherit inputs;})
    (import ./packages/stacked-workflows {})
  ];
  ...
  stacked-workflows = import ./packages/stacked-workflows {};
};
```

Export in packages:
```nix
inherit (pkgs) stacked-workflows-content;
```

- [ ] **Step 4: Format and check**

```bash
treefmt packages/stacked-workflows/default.nix flake.nix
git add packages/stacked-workflows/
nix flake check --no-build
```

- [ ] **Step 5: Commit**

```bash
git add -A  # captures moves + new files
git commit -m "feat(stacked-workflows): create content package with skills, references, fragments"
```

---

### Task 2: Create packages/coding-standards/ content package

**Files:**
- Create: `packages/coding-standards/default.nix`
- Move: `fragments/common/*.md` → `packages/coding-standards/fragments/`
- Remove: `packages/fragments/` (replaced by this)

- [ ] **Step 1: Create package and move content**

```bash
mkdir -p packages/coding-standards/fragments
mv fragments/common/coding-standards.md packages/coding-standards/fragments/
mv fragments/common/commit-convention.md packages/coding-standards/fragments/
mv fragments/common/config-parity.md packages/coding-standards/fragments/
mv fragments/common/tooling-preference.md packages/coding-standards/fragments/
mv fragments/common/validation.md packages/coding-standards/fragments/
```

- [ ] **Step 2: Create overlay default.nix**

```nix
# packages/coding-standards/default.nix
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
  mkFrag = name:
    fragmentsLib.mkFragment {
      text = builtins.readFile ./fragments/${name}.md;
      description = "coding-standards/${name}";
      priority = 10;
    };
in {
  coding-standards = final.runCommand "coding-standards" {} ''
    mkdir -p $out/fragments
    cp ${./fragments}/* $out/fragments/
  '' // {
    passthru.fragments = {
      coding-standards = mkFrag "coding-standards";
      commit-convention = mkFrag "commit-convention";
      config-parity = mkFrag "config-parity";
      tooling-preference = mkFrag "tooling-preference";
      validation = mkFrag "validation";
    };
  };
}
```

- [ ] **Step 3: Remove old packages/fragments/**

```bash
rm -rf packages/fragments/
```

- [ ] **Step 4: Register in flake.nix**

Replace `fragments` overlay with `coding-standards` in overlays section.
Export `coding-standards` in packages output.
Remove `agentic-fragments` references.

- [ ] **Step 5: Format, check, commit**

```bash
treefmt packages/coding-standards/default.nix flake.nix
git add -A
nix flake check --no-build
git commit -m "feat(coding-standards): create content package, replace packages/fragments/"
```

---

### Task 3: Move dev-only content to dev/

**Files:**
- Create: `dev/fragments/` structure
- Create: `dev/references/`
- Move: remaining dev-only fragments and references

- [ ] **Step 1: Move dev-only content**

```bash
mkdir -p dev/fragments/{monorepo,ai-clis,mcp-servers,stacked-workflows}
mkdir -p dev/references

# Dev fragments
mv fragments/packages/monorepo/project-overview.md dev/fragments/monorepo/
mv fragments/packages/ai-clis/packaging-guide.md dev/fragments/ai-clis/
mv fragments/packages/mcp-servers/overlay-guide.md dev/fragments/mcp-servers/
mv fragments/packages/stacked-workflows/development.md dev/fragments/stacked-workflows/

# Dev references
mv references/agnix.md dev/references/

# Clean up empty dirs
rm -rf fragments/ references/ skills/
```

- [ ] **Step 2: Update lib/fragments.nix fragmentsDir**

Change `fragmentsDir = ../fragments;` to `fragmentsDir = ../dev/fragments;`
for the remaining dev-only fragment reading. Or better: remove the hardcoded
path entirely and pass it as an argument (see Task 4).

- [ ] **Step 3: Update devenv.nix references**

Any `./skills/`, `./references/`, `./fragments/` paths in devenv.nix need
updating. Skill references now come from the stacked-workflows package.
Dev fragment reads point to `dev/fragments/`.

- [ ] **Step 4: Update .gitignore, cspell ignorePaths, CLAUDE.md directory tree**

- [ ] **Step 5: Format, check, test, commit**

```bash
treefmt lib/fragments.nix devenv.nix
git add -A
nix flake check --no-build
devenv test
git commit -m "refactor: move dev-only fragments and references to dev/"
```

---

### Task 4: Refactor lib/fragments.nix to pure functions

**Files:**
- Modify: `lib/fragments.nix`

Remove all file-reading code and hardcoded paths. Keep only pure functions.
`packageProfiles` data moves to callers or to a separate data file.

- [ ] **Step 1: Extract what stays vs what goes**

**Stays (pure functions):**
- `compose`
- `mkFragment`
- `mkFrontmatter`
- `ecosystems` (frontmatter generators per ecosystem)

**Goes (file I/O, hardcoded data):**
- `fragmentsDir`
- `readCommon`, `readPackage`
- `readCommonFragment`, `readPackageFragment` (these read files)
- `packageProfiles` (data, not a function)
- `packagePaths` (data)
- `mkContent`, `mkInstructions`, `mkPackageContent` (use removed functions)
- `packagesWithProfile` (operates on removed data)

**Moves to callers:**
- devenv.nix builds its own profile data from packages
- apps.generate builds its own profile data from packages
- stacked-workflows module reads from its package

- [ ] **Step 2: Rewrite lib/fragments.nix as pure functions**

```nix
{lib}: let
  # Compose multiple fragments into one. Higher priority = appears first.
  compose = { fragments, description ? null, paths ? null, priority ? 0 }: ...;

  # Canonical fragment constructor.
  mkFragment = { text, description ? null, paths ? null, priority ? 0 }: ...;

  # Build YAML frontmatter block from an attrset.
  mkFrontmatter = attrs: ...;

  # Ecosystem frontmatter generators.
  ecosystems = {
    agentsmd.mkFrontmatter = _: null;
    claude.mkFrontmatter = ...;
    copilot.mkFrontmatter = ...;
    kiro.mkFrontmatter = ...;
  };

  # Apply ecosystem frontmatter to a composed fragment.
  mkEcosystemContent = { ecosystem, package, composed }: let
    fm = ecosystems.${ecosystem}.mkFrontmatter package;
    fmStr = if fm == null then "" else mkFrontmatter fm + "\n";
  in fmStr + composed.text;
in {
  inherit compose ecosystems mkEcosystemContent mkFragment mkFrontmatter;
}
```

Note: `mkEcosystemContent` is extracted from the pattern duplicated in
devenv.nix and apps.generate — DRY.

- [ ] **Step 3: Update flake.nix lib exports**

Remove stale exports (readCommon, packageProfiles, etc.), keep compose,
mkFragment, mkFrontmatter, ecosystems, mkEcosystemContent.

- [ ] **Step 4: Format, check, commit**

```bash
treefmt lib/fragments.nix flake.nix
nix flake check --no-build
git commit -m "refactor(fragments): pure functions only, remove file I/O and hardcoded data"
```

---

### Task 5: Update devenv.nix to consume from packages

**Files:**
- Modify: `devenv.nix`

Replace root path references with package references. Apply stacked-workflows
overlay alongside git-tools.

- [ ] **Step 1: Apply stacked-workflows + coding-standards overlays**

```nix
# Add alongside gitToolsPkgs:
swsPkgs = pkgs.extend (import ./packages/stacked-workflows {});
codingStdPkgs = pkgs.extend (import ./packages/coding-standards {});
```

Or compose all content overlays once:
```nix
contentPkgs = pkgs.extend (final.lib.composeManyExtensions [
  (import ./packages/coding-standards {})
  (import ./packages/stacked-workflows {})
]);
```

- [ ] **Step 2: Replace skill path references**

```nix
# Old:
sws-stack-fix = ./skills/stack-fix;
# New:
sws-stack-fix = "${contentPkgs.stacked-workflows-content}/skills/stack-fix";
# Or via passthru:
sws-stack-fix = "${contentPkgs.stacked-workflows-content.passthru.skillsDir}/stack-fix";
```

Actually, passthru.skillsDir = ./skills (relative path in the source). For
consumers, the derivation store path is better:
```nix
sws-stack-fix = "${contentPkgs.stacked-workflows-content}/skills/stack-fix";
```

- [ ] **Step 3: Replace fragment composition**

Replace `fragments.readCommonFragment`/`readPackageFragment` with package
passthru fragments:

```nix
# Old:
mkComposed = package: profile: fragments.compose {
  fragments = map fragments.readCommonFragment prof.common ++ ...;
};

# New: compose from package passthru
commonFragments = builtins.attrValues contentPkgs.coding-standards.passthru.fragments;
swsFragments = builtins.attrValues contentPkgs.stacked-workflows-content.passthru.fragments;
```

For the dev profile, dev-only fragments are read from `dev/fragments/`:
```nix
devFragment = name: pkg:
  fragments.mkFragment {
    text = builtins.readFile ./dev/fragments/${pkg}/${name}.md;
    description = "dev/${pkg}/${name}";
    priority = 5;
  };
```

- [ ] **Step 4: Update references path in claude.code permissions**

```nix
# Old:
Read.allow = ["references/*"];
# New:
Read.allow = ["dev/references/*"];
```

Or if references are in the package:
```nix
Read.allow = ["${contentPkgs.stacked-workflows-content}/references/*"];
```

- [ ] **Step 5: Format, test, commit**

```bash
treefmt devenv.nix
devenv test
git commit -m "refactor(devenv): consume skills and fragments from packages"
```

---

### Task 6: Update modules/stacked-workflows/ to consume from package

**Files:**
- Modify: `modules/stacked-workflows/default.nix`

The HM module currently has `skillsDir = ../../skills;` and
`referencesDir = ../../references;`. These now come from the package.

- [ ] **Step 1: Replace path references with package**

The module needs access to `pkgs.stacked-workflows-content`. HM modules
receive `pkgs` in their args:

```nix
{config, lib, pkgs, ...}: let
  swsContent = pkgs.stacked-workflows-content;
  # ...
  self = {
    skillsDir = "${swsContent}/skills";
    referencesDir = "${swsContent}/references";
    instructionsClaude = aiCommon.mkClaudeRule "stacked-workflows" composed;
    # ...
  };
```

The `composed` binding uses passthru fragments:
```nix
composed = fragments.compose {
  fragments = builtins.attrValues swsContent.passthru.fragments;
};
```

- [ ] **Step 2: Format, check, commit**

```bash
treefmt modules/stacked-workflows/default.nix
nix flake check --no-build
git commit -m "refactor(stacked-workflows): consume from content package"
```

---

### Task 7: Update apps.generate to consume from packages

**Files:**
- Modify: `flake.nix` (apps section)

Same pattern as devenv.nix — reference package passthru instead of
lib file-reading functions.

- [ ] **Step 1: Replace fragment reads with package passthru**

The generate script needs access to `pkgs.coding-standards` and
`pkgs.stacked-workflows-content` passthru. Since the apps section
already has `pkgs = pkgsFor system`, and the overlay is composed into
default, `pkgs.coding-standards` and `pkgs.stacked-workflows-content`
are available directly.

- [ ] **Step 2: Format, check, commit**

```bash
treefmt flake.nix
nix flake check --no-build
git commit -m "refactor(generate): consume from content packages"
```

---

### Task 8: Update CLAUDE.md, AGENTS.md, checks, cspell

**Files:**
- Modify: `CLAUDE.md` — update Architecture directory tree
- Modify: `.cspell/project-terms.txt` — add new terms if needed
- Modify: checks if any reference old paths
- Modify: `.gitignore` if needed

- [ ] **Step 1: Update CLAUDE.md architecture tree**

Replace:
```
skills/       Consumer-facing stacked workflow skills
references/   Canonical tool reference docs
fragments/    Instruction generation sources (common/ + packages/)
```

With:
```
packages/
  stacked-workflows/  Content package: skills, references, routing-table fragment
  coding-standards/   Content package: reusable coding standard fragments
dev/
  fragments/          Dev-only instruction fragments (not exported)
  references/         Dev-only reference docs (not exported)
```

- [ ] **Step 2: Propagate changes through all docs**

Grep for `skills/`, `references/`, `fragments/` across CLAUDE.md, AGENTS.md,
any check files, and update paths.

- [ ] **Step 3: Format, check, test, commit**

```bash
treefmt CLAUDE.md
nix flake check --no-build
devenv test
git commit -m "docs: update architecture for package-focused content"
```

---

## Scope Notes

- `ecosystems` frontmatter config (packagePaths mapping) needs updating —
  the path scoping for Claude/Kiro frontmatter referenced old directories.
  This moves into lib or into the package passthru.
- The `config-parity.md` reference currently exists in both `fragments/common/`
  AND `references/`. The fragment version goes to coding-standards package.
  The reference version — check if it's published or dev-only.
- `dev/skills/` (index-repo-docs, repo-review) stays where it is — those
  are dev-only skills, not published.
