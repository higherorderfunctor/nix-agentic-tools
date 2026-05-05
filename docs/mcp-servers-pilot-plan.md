# mcp-servers Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a parallel-sandbox `packages/mcp-servers/` that
proves the pythonPackages-style scope pattern works for MCP
servers (self-assembly + multi-output sub-grouping +
`config.update.targets` merge-up) without touching any interface
nixos-config currently consumes.

**Architecture:** New top-level `packages/mcp-servers/` directory.
Internally split into `lib/` (factory copy, NOT walked) and
`packages/` (walked by `lib.filesystem.packagesFromDirectoryRecursive`).
Three stub MCP packages — one at scope root, two under a
`modelcontextprotocol/` sub-scope sharing one `source.nix` — exercise
the scope mechanic, sub-grouping, and shared-source pattern. Each
package contributes via a sibling `update.nix` to test
`config.update.targets` namespace merge-up. Flake exposes
`packages.<system>.mcpServerSandbox.*` and a top-level
`updateTargetsSandbox` attribute. NO existing output is modified.

**Tech Stack:**

- Nix flakes
- `lib.makeScope` + `pkgs.newScope` (nixpkgs scope mechanic)
- `lib.filesystem.packagesFromDirectoryRecursive` (self-assembly walker)
- `lib.filesystem.listFilesRecursive` (update-target walker)
- `lib.evalModules` (merge-up evaluator)
- Existing `mkMcpServer` factory copied from `lib/ai/mcpServer/`
- Stub `pkgs.runCommand` derivations (no real upstream fetches —
  pilot tests composition, not packaging fidelity)

---

## File Structure

| Path                                                                        | Responsibility                                                                                                                                  |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/mcp-servers/default.nix`                                          | Top-level barrel. Exposes `factory`, `scope`, `updateTargets` for flake.nix consumption. NOT picked up by `collectFacet` (no `modules.*` keys). |
| `packages/mcp-servers/lib/mkMcpServer.nix`                                  | Verbatim copy of `lib/ai/mcpServer/mkMcpServer.nix`.                                                                                            |
| `packages/mcp-servers/lib/commonSchema.nix`                                 | Verbatim copy.                                                                                                                                  |
| `packages/mcp-servers/lib/mkServiceModule.nix`                              | Verbatim copy.                                                                                                                                  |
| `packages/mcp-servers/lib/serviceSchema.nix`                                | Verbatim copy.                                                                                                                                  |
| `packages/mcp-servers/lib/update-options.nix`                               | Sandbox-local module declaring `options.update.targets` for merge-up.                                                                           |
| `packages/mcp-servers/packages/everything/default.nix`                      | Stub MCP at scope root. Tests "drop a file, it appears in scope."                                                                               |
| `packages/mcp-servers/packages/everything/update.nix`                       | Contributes `config.update.targets.everything`.                                                                                                 |
| `packages/mcp-servers/packages/modelcontextprotocol/default.nix`            | Sub-scope barrel. Walks own subdirs via `packagesFromDirectoryRecursive`.                                                                       |
| `packages/mcp-servers/packages/modelcontextprotocol/source.nix`             | Shared upstream source pin (stub). Imported by sub-package default.nix files.                                                                   |
| `packages/mcp-servers/packages/modelcontextprotocol/filesystem/default.nix` | Stub MCP. Imports `../source.nix`.                                                                                                              |
| `packages/mcp-servers/packages/modelcontextprotocol/filesystem/update.nix`  | Contributes `config.update.targets.filesystem`.                                                                                                 |
| `packages/mcp-servers/packages/modelcontextprotocol/memory/default.nix`     | Stub MCP. Imports `../source.nix`. Same shape as filesystem.                                                                                    |
| `packages/mcp-servers/packages/modelcontextprotocol/memory/update.nix`      | Contributes `config.update.targets.memory`.                                                                                                     |
| `flake.nix`                                                                 | Modified: add `mcpServerSandbox` to per-system packages, add top-level `updateTargetsSandbox`. NO other changes.                                |
| `docs/name-resolution-gap-analysis.md`                                      | Modified: append "Pilot findings" section as friction surfaces.                                                                                 |

**Naming:** `mcpServerSandbox` (not `mcpServerPackages`) for two
reasons: (1) makes its provisional status obvious, (2) avoids
collision with future production naming after dedupe.

---

## Constraints (apply to every task)

- **Don't break the current interface.** No edits to existing
  packages, overlays, modules, or shared lib. Sandbox is purely
  additive. Verification: `nix eval` for `pkgs.effect-mcp` and
  `homeManagerModules.default` produces byte-identical output
  before and after this branch.
- **No nix-store mutations.** Don't `chmod` or `sed` files under
  `/nix/store/`. (See `.claude/rules/nix-standards.md`.)
- **`git add` new files** before running `nix flake check` — flakes
  only see git-tracked files.
- **Inline hashes only** for any real packaging. (Pilot uses stubs;
  N/A.)
- **`nix flake check` stays green** after each commit.

---

## Phase 0: Sandbox skeleton

### Task 0.1: Create directory skeleton

**Files:**

- Create: `packages/mcp-servers/.gitkeep`
- Create: `packages/mcp-servers/lib/.gitkeep`
- Create: `packages/mcp-servers/packages/.gitkeep`
- Create: `packages/mcp-servers/packages/everything/.gitkeep`
- Create: `packages/mcp-servers/packages/modelcontextprotocol/.gitkeep`
- Create: `packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep`
- Create: `packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep`

- [ ] **Step 1: Create the seven empty directories with .gitkeep**

```bash
mkdir -p packages/mcp-servers/lib \
         packages/mcp-servers/packages/everything \
         packages/mcp-servers/packages/modelcontextprotocol/filesystem \
         packages/mcp-servers/packages/modelcontextprotocol/memory
touch packages/mcp-servers/.gitkeep \
      packages/mcp-servers/lib/.gitkeep \
      packages/mcp-servers/packages/.gitkeep \
      packages/mcp-servers/packages/everything/.gitkeep \
      packages/mcp-servers/packages/modelcontextprotocol/.gitkeep \
      packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep \
      packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep
```

- [ ] **Step 2: Verify the skeleton**

Run: `find packages/mcp-servers -type f -name .gitkeep | sort`

Expected output:

```
packages/mcp-servers/.gitkeep
packages/mcp-servers/lib/.gitkeep
packages/mcp-servers/packages/.gitkeep
packages/mcp-servers/packages/everything/.gitkeep
packages/mcp-servers/packages/modelcontextprotocol/.gitkeep
packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep
packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep
```

- [ ] **Step 3: Verify nothing else changed**

Run: `git status --porcelain | grep -v '^?? packages/mcp-servers'`

Expected output: empty (no other files touched).

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/
git commit -m "chore(mcp-servers): create sandbox skeleton"
```

---

### Task 0.2: Copy factory files into sandbox lib

**Files:**

- Create: `packages/mcp-servers/lib/mkMcpServer.nix` (copy of `lib/ai/mcpServer/mkMcpServer.nix`)
- Create: `packages/mcp-servers/lib/commonSchema.nix` (copy of `lib/ai/mcpServer/commonSchema.nix`)
- Create: `packages/mcp-servers/lib/mkServiceModule.nix` (copy of `lib/ai/mcpServer/mkServiceModule.nix`)
- Create: `packages/mcp-servers/lib/serviceSchema.nix` (copy of `lib/ai/mcpServer/serviceSchema.nix`)
- Delete: `packages/mcp-servers/lib/.gitkeep`

- [ ] **Step 1: Copy the four factory files**

```bash
cp lib/ai/mcpServer/mkMcpServer.nix packages/mcp-servers/lib/
cp lib/ai/mcpServer/commonSchema.nix packages/mcp-servers/lib/
cp lib/ai/mcpServer/mkServiceModule.nix packages/mcp-servers/lib/
cp lib/ai/mcpServer/serviceSchema.nix packages/mcp-servers/lib/
rm packages/mcp-servers/lib/.gitkeep
```

- [ ] **Step 2: Verify byte-identical copies**

Run: `for f in mkMcpServer commonSchema mkServiceModule serviceSchema; do diff -q "lib/ai/mcpServer/${f}.nix" "packages/mcp-servers/lib/${f}.nix"; done`

Expected output: empty (no diffs reported).

- [ ] **Step 3: Verify the original is untouched**

Run: `git diff lib/ai/mcpServer/`

Expected output: empty.

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/lib/
git commit -m "chore(mcp-servers): copy mkMcpServer factory into sandbox lib"
```

---

## Phase 1: Self-assembly scope mechanic

### Task 1.1: Verify the scope output does not yet exist

This is the failing-test step. We assert what we want to build by
verifying it currently fails.

- [ ] **Step 1: Confirm the output is absent**

Run: `nix eval .#packages.x86_64-linux.mcpServerSandbox 2>&1 || echo PASS-EXPECTED`

Expected output: ends with `error: attribute 'mcpServerSandbox' missing` followed by `PASS-EXPECTED`.

(If the command succeeds, the sandbox already exists and Phase 1 is no-op — investigate before proceeding.)

---

### Task 1.2: Wire the sandbox barrel and scope

**Files:**

- Create: `packages/mcp-servers/default.nix`
- Delete: `packages/mcp-servers/.gitkeep` (if it survived past Task 0.1)
- Delete: `packages/mcp-servers/packages/.gitkeep`

- [ ] **Step 1: Write the top-level barrel**

Create `packages/mcp-servers/default.nix`:

```nix
# Sandbox barrel for the mcp-servers pilot. Exposes the locally-copied
# factory and the auto-walked package scope to flake.nix. Does NOT
# contribute to homeManagerModules.default or any other consumer-facing
# output — sandbox is purely additive.
{
  lib,
  pkgs,
}: let
  factory = import ./lib/mkMcpServer.nix {inherit lib;};

  # Scope construction: makeScope so each <name>/default.nix gets a
  # callPackage that knows about siblings and shared inputs (factory,
  # nixpkgs lib, pkgs). packagesFromDirectoryRecursive walks
  # ./packages/ and instantiates every default.nix it finds — that's
  # the self-assembly mechanic.
  scope = lib.makeScope pkgs.newScope (self:
    lib.filesystem.packagesFromDirectoryRecursive {
      callPackage = self.callPackage;
      directory = ./packages;
    }
    // {
      # Factory is a non-package shared input — exposed via the scope so
      # each package can `callPackage` it as `mkMcpServer`.
      mkMcpServer = factory;
    });
in {
  inherit factory scope;
  # `updateTargets` is wired in Phase 3.
}
```

- [ ] **Step 2: Remove now-redundant gitkeeps**

```bash
rm -f packages/mcp-servers/.gitkeep packages/mcp-servers/packages/.gitkeep
```

- [ ] **Step 3: Verify the file evaluates without packages present**

The `packages/` directory is empty of default.nix files at this point, so the scope is empty.

Run: `nix eval --impure --json --expr 'let pkgs = import <nixpkgs> {}; scope = (import ./packages/mcp-servers { inherit (pkgs) lib; inherit pkgs; }).scope; in { hasMkMcpServer = builtins.hasAttr "mkMcpServer" scope; hasCallPackage = builtins.hasAttr "callPackage" scope; hasEverythingPackage = builtins.hasAttr "everything" scope; }'`

Expected output: `{"hasCallPackage":true,"hasEverythingPackage":false,"hasMkMcpServer":true}` — factory exposed, no package children yet because the walker found nothing.

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/default.nix
git rm -f packages/mcp-servers/.gitkeep packages/mcp-servers/packages/.gitkeep || true
git commit -m "feat(mcp-servers): add sandbox barrel + scope wiring"
```

---

### Task 1.3: Wire the sandbox into flake.nix

**Files:**

- Modify: `flake.nix:215-496` (the `packages = forAllSystems (system: ...)` block — add `mcpServerSandbox` to the returned attrset)

- [ ] **Step 1: Read the current `packages` output structure**

Run: `awk '/packages = forAllSystems/,/^    });/' flake.nix | head -40`

Confirm the structure matches what the modification expects: a `let ... in <expr>` whose `<expr>` is an attrset (built via `// { ... }`).

- [ ] **Step 2: Add the sandbox import inside the `let` binding**

In `flake.nix`, inside the `packages = forAllSystems (system: let ... in ...)` block, locate the existing `let` bindings (around line 217). Add this binding:

```nix
      mcpServerSandbox = (import ./packages/mcp-servers {inherit lib pkgs;}).scope;
```

Place it immediately after the `pkgs = pkgsFor system;` line.

- [ ] **Step 3: Add the sandbox to the returned attrset**

The packages output is constructed as `<expr1> // <expr2> // { ... }`. Locate the final `// { ... }` block (starts around line 394 with `// {` after `modelcontextprotocol-all-mcps = ...;`). Add this entry inside that final block, alphabetically between `instructions-kiro` and `modelcontextprotocol-all-mcps`:

```nix
        mcpServerSandbox = mcpServerSandbox;
```

- [ ] **Step 4: Verify the sandbox shows up under packages**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox --apply 'scope: { hasMkMcpServer = builtins.hasAttr "mkMcpServer" scope; hasCallPackage = builtins.hasAttr "callPackage" scope; }'`

Expected output: `{"hasCallPackage":true,"hasMkMcpServer":true}`

- [ ] **Step 5: Verify no existing output broke**

Run: `nix eval .#packages.x86_64-linux.effect-mcp --apply 'p: p.name'`

Expected output: a string starting with `"effect-mcp-"` followed by a version. (The package itself unchanged.)

- [ ] **Step 6: Run flake check**

Run: `nix flake check 2>&1 | tail -5`

Expected: no new failures versus baseline. (Baseline status: capture before this phase via `git stash; nix flake check 2>&1 | tail -5; git stash pop` if not already known.)

- [ ] **Step 7: Commit**

```bash
git add flake.nix
git commit -m "feat(mcp-servers): expose sandbox scope at packages.<system>.mcpServerSandbox"
```

---

### Task 1.4: Add the first MCP package (`everything`) and verify self-assembly

**Files:**

- Create: `packages/mcp-servers/packages/everything/default.nix`
- Delete: `packages/mcp-servers/packages/everything/.gitkeep`

- [ ] **Step 1: Write the failing assertion (no `everything` yet)**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox --apply 'scope: builtins.hasAttr "everything" scope'`

Expected output: `false`

- [ ] **Step 2: Add the everything stub**

Create `packages/mcp-servers/packages/everything/default.nix`:

```nix
# Stub MCP server: tests scope-root self-assembly. Real packaging
# (upstream fetch, build, install) is intentionally out of pilot
# scope — we're proving composition, not packaging fidelity.
{
  lib,
  runCommand,
  mkMcpServer,
}: let
  drv = runCommand "mcp-server-everything-stub" {} ''
    mkdir -p $out/bin
    echo '#!/bin/sh' > $out/bin/everything-stub
    echo 'echo "stub mcp server"' >> $out/bin/everything-stub
    chmod +x $out/bin/everything-stub
  '';

  # Exercise mkMcpServer to prove the factory still works inside the
  # sandbox scope. Returns the typed config attrset.
  config = mkMcpServer {
    name = "everything";
    defaults = {
      package = drv;
      type = "stdio";
    };
  } {};
in
  drv
  // {
    inherit config;
    passthru = drv.passthru or {} // {mcpName = "everything";};
  }
```

- [ ] **Step 3: Remove the gitkeep**

```bash
rm packages/mcp-servers/packages/everything/.gitkeep
```

- [ ] **Step 4: Verify everything appears in the scope without barrel edits**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox --apply 'scope: builtins.hasAttr "everything" scope'`

Expected output: `true`

**This is the first self-assembly milestone.** No edit to `packages/mcp-servers/default.nix` was required — the walker picked it up.

- [ ] **Step 5: Verify it builds**

Run: `nix build .#packages.x86_64-linux.mcpServerSandbox.everything --no-link --print-out-paths`

Expected output: a `/nix/store/...-mcp-server-everything-stub` path.

- [ ] **Step 6: Verify the factory was exercised**

Run: `nix eval .#packages.x86_64-linux.mcpServerSandbox.everything.config.type`

Expected output: `"stdio"`

- [ ] **Step 7: Add to git, run flake check**

```bash
git add packages/mcp-servers/packages/everything/
git rm packages/mcp-servers/packages/everything/.gitkeep || true
nix flake check 2>&1 | tail -5
```

Expected: no new failures.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(mcp-servers): add 'everything' stub — self-assembly milestone"
```

---

## Phase 2: Sub-scope mechanic with shared source

### Task 2.1: Verify the sub-scope does not yet exist

- [ ] **Step 1: Confirm absence**

Run: `nix eval .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol 2>&1 || echo PASS-EXPECTED`

Expected output: ends with `error: attribute 'modelcontextprotocol' missing` followed by `PASS-EXPECTED`.

---

### Task 2.2: Add the sub-scope barrel

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/default.nix`
- Delete: `packages/mcp-servers/packages/modelcontextprotocol/.gitkeep`

- [ ] **Step 1: Write the sub-scope barrel**

Create `packages/mcp-servers/packages/modelcontextprotocol/default.nix`:

```nix
# Sub-scope for upstream modelcontextprotocol/servers monorepo
# packages. Walks own subdirs via packagesFromDirectoryRecursive —
# same self-assembly mechanic as the parent scope, recursively
# applied. The shared `source.nix` is imported by sub-package
# default.nix files directly (not via the scope walker).
{
  lib,
  newScope,
}:
  lib.makeScope newScope (self:
    lib.filesystem.packagesFromDirectoryRecursive {
      callPackage = self.callPackage;
      directory = ./.;
    })
```

- [ ] **Step 2: Remove the gitkeep**

```bash
rm packages/mcp-servers/packages/modelcontextprotocol/.gitkeep
```

- [ ] **Step 3: Verify the sub-scope appears empty (no children yet)**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol --apply 'sub: { hasFilesystem = builtins.hasAttr "filesystem" sub; hasMemory = builtins.hasAttr "memory" sub; hasCallPackage = builtins.hasAttr "callPackage" sub; }'`

Expected output: `{"hasCallPackage":true,"hasFilesystem":false,"hasMemory":false}` — scope plumbing present, package children not yet contributed.

- [ ] **Step 4: Add to git**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/default.nix
git rm packages/mcp-servers/packages/modelcontextprotocol/.gitkeep || true
```

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(mcp-servers): add modelcontextprotocol sub-scope barrel"
```

---

### Task 2.3: Add the shared source pin

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/source.nix`

- [ ] **Step 1: Write source.nix**

Create `packages/mcp-servers/packages/modelcontextprotocol/source.nix`:

```nix
# Shared upstream source for modelcontextprotocol/servers monorepo.
# Sub-packages (filesystem, memory) reference this via `import
# ../source.nix { inherit pkgs; }` so they all derive from the same
# pinned source — the multi-output-from-one-source pattern that
# slice-nav-design.md §3 cites as the legitimate sidecar case.
#
# STUB: pilot uses runCommand to fabricate a fake source tree.
# Real implementation would use fetchFromGitHub with inline rev+hash
# per .claude/rules/nix-standards.md.
{pkgs}:
  pkgs.runCommand "modelcontextprotocol-servers-source-stub" {} ''
    mkdir -p $out/src/{filesystem,memory}
    echo "stub filesystem source" > $out/src/filesystem/README.md
    echo "stub memory source" > $out/src/memory/README.md
  ''
```

- [ ] **Step 2: Verify it imports without error**

Run: `nix eval --impure --expr 'let pkgs = import <nixpkgs> {}; in (import ./packages/mcp-servers/packages/modelcontextprotocol/source.nix {inherit pkgs;}).name'`

Expected output: `"modelcontextprotocol-servers-source-stub"`

- [ ] **Step 3: Verify packagesFromDirectoryRecursive ignores `source.nix`**

The walker only picks up `default.nix` files in subdirectories, not arbitrary `.nix` files at the same level.

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol --apply 'sub: builtins.attrNames sub'`

Expected output: same as Task 2.2 Step 3 — NO `source` attribute.

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/source.nix
git commit -m "feat(mcp-servers): add shared source.nix for modelcontextprotocol family"
```

---

### Task 2.4: Add the `filesystem` sub-package

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/filesystem/default.nix`
- Delete: `packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep`

- [ ] **Step 1: Verify filesystem absent**

Run: `nix eval .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.filesystem 2>&1 || echo PASS-EXPECTED`

Expected output: ends with attribute missing error and `PASS-EXPECTED`.

- [ ] **Step 2: Write the sub-package**

Create `packages/mcp-servers/packages/modelcontextprotocol/filesystem/default.nix`:

```nix
# modelcontextprotocol/filesystem stub. Demonstrates shared-source
# pattern: imports ../source.nix and uses its output as the build
# input. In real packaging, $src/src/filesystem would contain the
# Typescript source; here it's a stub README.
{
  lib,
  pkgs,
  runCommand,
  mkMcpServer,
}: let
  upstream = import ../source.nix {inherit pkgs;};

  drv = runCommand "mcp-server-filesystem-stub" {} ''
    mkdir -p $out/bin $out/share
    cp ${upstream}/src/filesystem/README.md $out/share/
    echo '#!/bin/sh' > $out/bin/filesystem-stub
    echo 'echo "stub filesystem mcp"' >> $out/bin/filesystem-stub
    chmod +x $out/bin/filesystem-stub
  '';

  config = mkMcpServer {
    name = "filesystem";
    defaults = {
      package = drv;
      type = "stdio";
    };
  } {};
in
  drv
  // {
    inherit config;
    passthru = drv.passthru or {} // {
      mcpName = "filesystem";
      sharedSource = upstream;
    };
  }
```

- [ ] **Step 3: Remove gitkeep**

```bash
rm packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep
```

- [ ] **Step 4: Verify it appears in sub-scope**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol --apply 'sub: builtins.hasAttr "filesystem" sub'`

Expected output: `true`

- [ ] **Step 5: Verify it builds**

Run: `nix build .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.filesystem --no-link --print-out-paths`

Expected: a store path.

- [ ] **Step 6: Add and commit**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/filesystem/
git rm packages/mcp-servers/packages/modelcontextprotocol/filesystem/.gitkeep || true
git commit -m "feat(mcp-servers): add modelcontextprotocol/filesystem stub"
```

---

### Task 2.5: Add the `memory` sub-package and verify shared-source identity

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/memory/default.nix`
- Delete: `packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep`

- [ ] **Step 1: Verify memory absent**

Run: `nix eval .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.memory 2>&1 || echo PASS-EXPECTED`

Expected output: attribute missing error followed by `PASS-EXPECTED`.

- [ ] **Step 2: Write the sub-package**

Create `packages/mcp-servers/packages/modelcontextprotocol/memory/default.nix`:

```nix
# modelcontextprotocol/memory stub. Same shape as filesystem to
# stress-test the multi-output-from-one-source pattern: both
# packages reference identical `../source.nix`, so they should
# share the same source store path.
{
  lib,
  pkgs,
  runCommand,
  mkMcpServer,
}: let
  upstream = import ../source.nix {inherit pkgs;};

  drv = runCommand "mcp-server-memory-stub" {} ''
    mkdir -p $out/bin $out/share
    cp ${upstream}/src/memory/README.md $out/share/
    echo '#!/bin/sh' > $out/bin/memory-stub
    echo 'echo "stub memory mcp"' >> $out/bin/memory-stub
    chmod +x $out/bin/memory-stub
  '';

  config = mkMcpServer {
    name = "memory";
    defaults = {
      package = drv;
      type = "stdio";
    };
  } {};
in
  drv
  // {
    inherit config;
    passthru = drv.passthru or {} // {
      mcpName = "memory";
      sharedSource = upstream;
    };
  }
```

- [ ] **Step 3: Remove gitkeep**

```bash
rm packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep
```

- [ ] **Step 4: Verify it appears**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol --apply 'sub: { hasFilesystem = builtins.hasAttr "filesystem" sub; hasMemory = builtins.hasAttr "memory" sub; }'`

Expected output: `{"hasFilesystem":true,"hasMemory":true}`

- [ ] **Step 5: Verify shared-source identity (the multi-output check)**

Both sub-packages should reference the _same_ upstream store path via their `passthru.sharedSource` attribute.

Run:

```bash
fs_src=$(nix eval --raw .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.filesystem.passthru.sharedSource)
mem_src=$(nix eval --raw .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.memory.passthru.sharedSource)
[ "$fs_src" = "$mem_src" ] && echo "SHARED OK: $fs_src" || echo "DIVERGED: fs=$fs_src mem=$mem_src"
```

Expected output: `SHARED OK: /nix/store/...-modelcontextprotocol-servers-source-stub`

**This is the multi-output-from-one-source milestone.** Both
sub-packages compose with the same source pin; one source pin
produces two derivations.

- [ ] **Step 6: Build both, run flake check**

```bash
nix build .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.filesystem .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.memory --no-link
nix flake check 2>&1 | tail -5
```

Expected: builds succeed, no new flake-check failures.

- [ ] **Step 7: Add and commit**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/memory/
git rm packages/mcp-servers/packages/modelcontextprotocol/memory/.gitkeep || true
git commit -m "feat(mcp-servers): add modelcontextprotocol/memory stub — multi-output milestone"
```

---

## Phase 3: `config.update.targets` namespace merge-up

### Task 3.1: Declare the merge-up option

**Files:**

- Create: `packages/mcp-servers/lib/update-options.nix`

- [ ] **Step 1: Write the option module**

Create `packages/mcp-servers/lib/update-options.nix`:

```nix
# Declares the `config.update.targets` option that update.nix files
# in this sandbox merge into. Sandbox-local — does NOT pollute
# `lib/ai/sharedOptions.nix` or any other consumer-facing schema.
#
# Each contributor declares one entry: `{ name = { file = ./...; }; }`.
# The merged set is exposed at flake top-level as `updateTargetsSandbox`
# in Phase 3.3.
{lib, ...}: {
  options.update.targets = lib.mkOption {
    description = "Per-package update-pipeline targets contributed via merge-up.";
    type = lib.types.attrsOf (lib.types.submodule {
      options.file = lib.mkOption {
        type = lib.types.path;
        description = "Path to the package's primary .nix file.";
      };
    });
    default = {};
  };
}
```

- [ ] **Step 2: Verify it parses by importing it standalone**

Run: `nix eval --impure --expr 'let lib = (import <nixpkgs> {}).lib; in (lib.evalModules { modules = [./packages/mcp-servers/lib/update-options.nix]; }).config.update.targets'`

Expected output: `{ }`

- [ ] **Step 3: Commit**

```bash
git add packages/mcp-servers/lib/update-options.nix
git commit -m "feat(mcp-servers): declare sandbox-local update.targets option"
```

---

### Task 3.2: Wire the merge-up walker into the sandbox barrel

**Files:**

- Modify: `packages/mcp-servers/default.nix`

- [ ] **Step 1: Read current barrel**

Run: `cat packages/mcp-servers/default.nix`

Confirm it currently exposes `factory` and `scope` only.

- [ ] **Step 2: Add updateTargets walker**

Edit `packages/mcp-servers/default.nix`. Replace the entire file contents with:

```nix
# Sandbox barrel for the mcp-servers pilot. Exposes the locally-copied
# factory, the auto-walked package scope, and the merged
# update-targets attrset to flake.nix. Does NOT contribute to
# homeManagerModules.default — sandbox is purely additive.
{
  lib,
  pkgs,
}: let
  factory = import ./lib/mkMcpServer.nix {inherit lib;};

  scope = lib.makeScope pkgs.newScope (self:
    lib.filesystem.packagesFromDirectoryRecursive {
      callPackage = self.callPackage;
      directory = ./packages;
    }
    // {
      mkMcpServer = factory;
    });

  # Walker: find every update.nix under ./packages and import as a
  # module. evalModules merges them into config.update.targets via
  # the option declared in lib/update-options.nix. Self-assembly:
  # adding a new update.nix under ./packages/<name>/ contributes
  # automatically — no edit to this file required.
  updateModules = let
    allFiles = lib.filesystem.listFilesRecursive ./packages;
    isUpdateModule = p: lib.hasSuffix "/update.nix" (toString p);
  in
    builtins.filter isUpdateModule allFiles;

  updateTargets =
    (lib.evalModules {
      modules = [./lib/update-options.nix] ++ updateModules;
    })
    .config
    .update
    .targets;
in {
  inherit factory scope updateTargets;
}
```

- [ ] **Step 3: Verify barrel still evaluates with no contributors**

Run: `nix eval --impure --expr 'let pkgs = import <nixpkgs> {}; in (import ./packages/mcp-servers { inherit (pkgs) lib; inherit pkgs; }).updateTargets'`

Expected output: `{ }`

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/default.nix
git commit -m "feat(mcp-servers): wire update.targets merge-up walker"
```

---

### Task 3.3: Expose `updateTargetsSandbox` at flake top-level

**Files:**

- Modify: `flake.nix` (add new top-level output)

- [ ] **Step 1: Locate where to add the output**

Run: `grep -n 'updateMatrix' flake.nix`

Expected output: a line near the start of the flake outputs (around line 126) showing `updateMatrix = import ./config/update-matrix.nix;`.

- [ ] **Step 2: Add `updateTargetsSandbox` immediately after `updateMatrix`**

Edit `flake.nix`. Find the `updateMatrix = import ./config/update-matrix.nix;` line and add this directly after it:

```nix

    # Sandbox-only: merged update.targets from packages/mcp-servers.
    # NOT a consumer interface. Will be folded into a shared namespace
    # if/when the pilot pattern is promoted out of sandbox.
    updateTargetsSandbox = (import ./packages/mcp-servers {
      inherit lib;
      pkgs = pkgsFor "x86_64-linux";
    }).updateTargets;
```

- [ ] **Step 3: Verify the output shows up**

Run: `nix eval --json .#updateTargetsSandbox`

Expected output: `{}` (empty, no contributors yet — that's Task 3.4).

- [ ] **Step 4: Verify no existing output broke**

Run: `nix eval --raw .#packages.x86_64-linux.effect-mcp.name`

Expected output: a string starting with `effect-mcp-`. (Existing flat package untouched.)

- [ ] **Step 5: Commit**

```bash
git add flake.nix
git commit -m "feat(mcp-servers): expose updateTargetsSandbox top-level output"
```

---

### Task 3.4: Contribute the first update.nix (everything)

**Files:**

- Create: `packages/mcp-servers/packages/everything/update.nix`

- [ ] **Step 1: Verify everything not yet in updateTargets**

Run: `nix eval --json .#updateTargetsSandbox --apply 'builtins.attrNames'`

Expected output: `[]`

- [ ] **Step 2: Write the contribution**

Create `packages/mcp-servers/packages/everything/update.nix`:

```nix
# Contributes everything's update target via merge-up.
# config.update.targets.everything is gathered into .#updateTargetsSandbox
# at flake top-level. Self-assembly: this file appearing on disk is
# enough — no barrel/registry edit needed.
{
  config.update.targets.everything = {
    file = ./default.nix;
  };
}
```

- [ ] **Step 3: Verify it appears WITHOUT editing the barrel**

Run: `nix eval --json .#updateTargetsSandbox --apply 'builtins.attrNames'`

Expected output: `["everything"]`

**This is the namespace merge-up self-assembly milestone.** No edit
to any barrel, registry, or list — just creating the file.

- [ ] **Step 4: Verify the file path resolves correctly**

Run: `nix eval --raw .#updateTargetsSandbox.everything.file`

Expected output: `/nix/store/...-source/packages/mcp-servers/packages/everything/default.nix` (or similar — the important assertion is the suffix `packages/everything/default.nix`).

- [ ] **Step 5: git add (so flake sees the file), then commit**

```bash
git add packages/mcp-servers/packages/everything/update.nix
git commit -m "feat(mcp-servers): contribute everything to update.targets merge-up"
```

---

### Task 3.5: Contribute filesystem and memory update.nix files

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/filesystem/update.nix`
- Create: `packages/mcp-servers/packages/modelcontextprotocol/memory/update.nix`

- [ ] **Step 1: Write filesystem contribution**

Create `packages/mcp-servers/packages/modelcontextprotocol/filesystem/update.nix`:

```nix
{
  config.update.targets.filesystem = {
    file = ./default.nix;
  };
}
```

- [ ] **Step 2: Write memory contribution**

Create `packages/mcp-servers/packages/modelcontextprotocol/memory/update.nix`:

```nix
{
  config.update.targets.memory = {
    file = ./default.nix;
  };
}
```

- [ ] **Step 3: git add (required for flake to see them)**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/filesystem/update.nix \
        packages/mcp-servers/packages/modelcontextprotocol/memory/update.nix
```

- [ ] **Step 4: Verify all three appear**

Run: `nix eval --json .#updateTargetsSandbox --apply 'targets: builtins.sort builtins.lessThan (builtins.attrNames targets)'`

Expected output: `["everything","filesystem","memory"]`

- [ ] **Step 5: Verify each path resolves to the right file**

```bash
for name in everything filesystem memory; do
  path=$(nix eval --raw .#updateTargetsSandbox.${name}.file)
  echo "${name}: ${path}"
done
```

Expected output: three lines, each ending with the matching package's `default.nix` path (e.g. `everything: /nix/store/...-source/packages/mcp-servers/packages/everything/default.nix`).

- [ ] **Step 6: Run flake check**

Run: `nix flake check 2>&1 | tail -5`

Expected: no new failures.

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(mcp-servers): contribute modelcontextprotocol/{filesystem,memory} to update.targets"
```

---

## Phase 4: Self-assembly stress test

This phase validates the (D) feasibility test: adding a NEW
package after all wiring is done should require ZERO edits to any
barrel, registry, scope, or walker — just dropping files in place.

### Task 4.1: Add `time` as a fourth package

**Files:**

- Create: `packages/mcp-servers/packages/modelcontextprotocol/time/default.nix`
- Create: `packages/mcp-servers/packages/modelcontextprotocol/time/update.nix`

- [ ] **Step 1: Verify `time` does not exist anywhere**

```bash
nix eval .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.time 2>&1 | head -1 || true
nix eval .#updateTargetsSandbox.time 2>&1 | head -1 || true
```

Expected output: both lines contain `attribute 'time' missing` errors.

- [ ] **Step 2: Update source.nix to include a `time` subdirectory**

Edit `packages/mcp-servers/packages/modelcontextprotocol/source.nix`. Modify the runCommand body to add a third subdirectory. Replace the existing builder script line that creates `filesystem` and `memory` with one that also creates `time`:

```nix
  pkgs.runCommand "modelcontextprotocol-servers-source-stub" {} ''
    mkdir -p $out/src/{filesystem,memory,time}
    echo "stub filesystem source" > $out/src/filesystem/README.md
    echo "stub memory source" > $out/src/memory/README.md
    echo "stub time source" > $out/src/time/README.md
  ''
```

(This is the ONE allowed edit during stress test — the source pin itself needs to know about the new sub-output. If the real implementation moves to `fetchFromGitHub`, this edit becomes unnecessary because the upstream tree already contains all sub-packages.)

- [ ] **Step 3: Write the time package**

Create `packages/mcp-servers/packages/modelcontextprotocol/time/default.nix`:

```nix
{
  lib,
  pkgs,
  runCommand,
  mkMcpServer,
}: let
  upstream = import ../source.nix {inherit pkgs;};

  drv = runCommand "mcp-server-time-stub" {} ''
    mkdir -p $out/bin $out/share
    cp ${upstream}/src/time/README.md $out/share/
    echo '#!/bin/sh' > $out/bin/time-stub
    echo 'echo "stub time mcp"' >> $out/bin/time-stub
    chmod +x $out/bin/time-stub
  '';

  config = mkMcpServer {
    name = "time";
    defaults = {
      package = drv;
      type = "stdio";
    };
  } {};
in
  drv
  // {
    inherit config;
    passthru = drv.passthru or {} // {
      mcpName = "time";
      sharedSource = upstream;
    };
  }
```

- [ ] **Step 4: Write the time update.nix**

Create `packages/mcp-servers/packages/modelcontextprotocol/time/update.nix`:

```nix
{
  config.update.targets.time = {
    file = ./default.nix;
  };
}
```

- [ ] **Step 5: git add the new files**

```bash
git add packages/mcp-servers/packages/modelcontextprotocol/source.nix \
        packages/mcp-servers/packages/modelcontextprotocol/time/
```

- [ ] **Step 6: Verify time appears in scope WITHOUT barrel edits**

Run: `nix eval --json .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol --apply 'sub: { hasFilesystem = builtins.hasAttr "filesystem" sub; hasMemory = builtins.hasAttr "memory" sub; hasTime = builtins.hasAttr "time" sub; }'`

Expected output: `{"hasFilesystem":true,"hasMemory":true,"hasTime":true}`

- [ ] **Step 7: Verify time appears in update.targets WITHOUT walker edits**

Run: `nix eval --json .#updateTargetsSandbox --apply 'targets: builtins.sort builtins.lessThan (builtins.attrNames targets)'`

Expected output: `["everything","filesystem","memory","time"]`

- [ ] **Step 8: Verify the time derivation builds**

Run: `nix build .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.time --no-link --print-out-paths`

Expected output: a store path.

- [ ] **Step 9: Verify shared-source identity holds across all three**

```bash
fs_src=$(nix eval --raw .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.filesystem.passthru.sharedSource)
mem_src=$(nix eval --raw .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.memory.passthru.sharedSource)
time_src=$(nix eval --raw .#packages.x86_64-linux.mcpServerSandbox.modelcontextprotocol.time.passthru.sharedSource)
[ "$fs_src" = "$mem_src" ] && [ "$mem_src" = "$time_src" ] && echo "ALL SHARED: $fs_src" || echo "DIVERGED"
```

Expected output: `ALL SHARED: /nix/store/...-modelcontextprotocol-servers-source-stub`

- [ ] **Step 10: Commit**

```bash
git commit -m "feat(mcp-servers): stress-test self-assembly with time package"
```

---

### Task 4.2: Document any forced/awkward parts encountered

**Files:**

- Modify: `docs/name-resolution-gap-analysis.md` (append findings section)

- [ ] **Step 1: Identify friction**

Review the work in Phases 0–4. For each instance where the
composition felt forced, hand-wired, or required a workaround,
write a one-paragraph entry. Examples of legitimate findings:

- "Source.nix had to be edited when adding a new sub-package." (If
  this surfaced — fetchFromGitHub vs fabricated stub trade-off.)
- "packagesFromDirectoryRecursive picked up `lib/`-style dirs and
  required filtering." (If the structure had to be split.)
- "Update-target walker needed manual filter for `update.nix`
  suffix; nixpkgs has no built-in primitive."
- "evalModules required explicit `_module.args.pkgs` injection for
  contributing files to be importable as modules." (If this came
  up.)

If nothing felt forced, write that explicitly: "Pilot composed
without forced wiring. Self-assembly mechanism per nixpkgs
`packagesFromDirectoryRecursive` + `lib.filesystem.listFilesRecursive`

- `evalModules` is sufficient. Multi-output via shared `source.nix`
  imported by sub-packages requires no special API."

* [ ] **Step 2: Append the section**

Open `docs/name-resolution-gap-analysis.md` and append at the end:

```markdown
## mcp-servers pilot findings (YYYY-MM-DD)

[One paragraph per finding from Step 1, OR the explicit "no friction" statement.]
```

Replace `YYYY-MM-DD` with today's date.

- [ ] **Step 3: Commit**

```bash
git add docs/name-resolution-gap-analysis.md
git commit -m "docs(mcp-servers): capture pilot findings"
```

---

## Phase 5: Consumer-interface invariance check

### Task 5.1: Verify nixos-config interface unchanged

This phase confirms the load-bearing constraint: nothing the
nixos-config consumer reads has changed.

- [ ] **Step 1: Capture sample of pre-existing flake outputs**

Run:

```bash
echo "=== effect-mcp ==="
nix eval --raw .#packages.x86_64-linux.effect-mcp.name
echo
echo "=== homeManagerModules.default attribute count ==="
nix eval --json .#homeManagerModules.default.imports --apply 'builtins.length'
echo
echo "=== devenvModules.nix-agentic-tools ==="
nix eval --json .#devenvModules.nix-agentic-tools.imports --apply 'builtins.length'
echo
echo "=== lib.ai keys ==="
nix eval --json .#lib.ai --apply 'l: builtins.sort builtins.lessThan (builtins.attrNames l)'
```

- [ ] **Step 2: Compare to baseline**

If a pre-pilot baseline was captured (recommended: capture on `main` or before Phase 0), diff. Otherwise, manual review:

- `effect-mcp.name` — should be `effect-mcp-<version>`, no `-sandbox` or `-pilot` suffix.
- Module import counts should match what they were before Phase 0 (sandbox is NOT imported into either module).
- `lib.ai` keys should be unchanged — no new keys added.

- [ ] **Step 3: Run the cache-hit-parity check**

The repo's existing `checks.cache-hit-parity` validates that overlay packages produce byte-identical store paths across two different nixpkgs pins. If sandbox additions accidentally pulled into the overlay, this would fail.

Run: `nix flake check --keep-going 2>&1 | grep -E 'cache-hit-parity|FAIL'`

Expected: no new failures involving cache-hit-parity.

- [ ] **Step 4: Run the full flake check one more time**

Run: `nix flake check 2>&1 | tail -10`

Expected: no new failures versus pre-pilot baseline.

- [ ] **Step 5: Verify treefmt is clean**

Run: `treefmt --no-cache`

Expected: exit 0, no files reformatted.

If treefmt reformatted files, commit the formatting.

```bash
git diff --stat
git add -A && git commit -m "chore(mcp-servers): treefmt sandbox files" || true
```

- [ ] **Step 6: Final commit if anything is outstanding**

```bash
git status
```

Expected: clean working tree.

---

## Phase 6: Findings handoff and next steps

### Task 6.1: Write the pilot summary

**Files:**

- Create: `docs/mcp-servers-pilot-results.md`

- [ ] **Step 1: Write the summary**

Create `docs/mcp-servers-pilot-results.md`:

```markdown
# mcp-servers Pilot Results

Implementation reference: `docs/mcp-servers-pilot-plan.md`.
Findings reference: `docs/name-resolution-gap-analysis.md`
"mcp-servers pilot findings" section.

## Outcome

[Pass / Fail / Partial — per the pilot success criteria.]

## Self-assembly verification

- [ ] Adding a new package directory at
      `packages/mcp-servers/packages/<name>/default.nix` makes it
      appear at `pkgs.mcpServerSandbox.<name>` without barrel edits.
- [ ] Adding a sibling `update.nix` makes it appear at
      `updateTargetsSandbox.<name>` without walker edits.
- [ ] Sub-scope (`modelcontextprotocol/`) follows the same pattern
      recursively.

## Multi-output verification

- [ ] Two+ sub-packages share one `source.nix` via
      `import ../source.nix`.
- [ ] `passthru.sharedSource` is byte-identical across siblings.
- [ ] Adding a third sibling reuses the same shared source.

## (D) feasibility verdict

[1-2 paragraphs: did the composition feel pipe-natural, or did
specific points require hand-wiring? If hand-wiring was needed,
which points and why?]

## Next steps

If pass: scope dedupe (move/replace `lib/ai/mcpServer/` with the
sandbox copy), then begin migrating real packages from `packages/<name>-mcp/`
to `packages/mcp-servers/<name>/` per the slice-nav stay-green
discipline.

If partial/fail: revise the pattern based on findings; do NOT
proceed with migration.
```

- [ ] **Step 2: Fill in the verdict and checkboxes from actual run results**

Edit the file in place. Replace `[Pass / Fail / Partial]`,
checkbox states, and the (D) feasibility paragraph with the
actual outcomes from Phases 1–4.

- [ ] **Step 3: Commit**

```bash
git add docs/mcp-servers-pilot-results.md
git commit -m "docs(mcp-servers): pilot results and (D) feasibility verdict"
```

---

## Verification checklist

When the plan is fully executed, ALL of these must hold:

- [ ] `nix flake check` passes.
- [ ] `nix build .#packages.x86_64-linux.effect-mcp` produces an unchanged store path versus pre-pilot baseline.
- [ ] `nix eval .#homeManagerModules.default.imports` length matches pre-pilot baseline.
- [ ] `nix eval --json .#packages.x86_64-linux.mcpServerSandbox --apply 'scope: { hasEverything = builtins.hasAttr "everything" scope; hasMkMcpServer = builtins.hasAttr "mkMcpServer" scope; hasModelContextProtocol = builtins.hasAttr "modelcontextprotocol" scope; }'` returns all three booleans `true`.
- [ ] `nix eval --json .#updateTargetsSandbox --apply 'builtins.attrNames'` returns `["everything","filesystem","memory","time"]`.
- [ ] All four sandbox derivations build (`mcpServerSandbox.everything`, `.modelcontextprotocol.{filesystem,memory,time}`).
- [ ] `passthru.sharedSource` byte-identical across all three modelcontextprotocol sub-packages.
- [ ] No edits to `lib/ai/mcpServer/`, `lib/ai/sharedOptions.nix`, `packages/<existing-name>/`, `homeManagerModules.default`, `devenvModules.nix-agentic-tools`, or `services.mcp-servers.*`.
- [ ] `docs/name-resolution-gap-analysis.md` has a "mcp-servers pilot findings" section.
- [ ] `docs/mcp-servers-pilot-results.md` exists with verdict.

---

## Stop conditions (the (D) test branch)

If during execution any of the following surface, **stop and ask
for review** rather than power through:

1. `packagesFromDirectoryRecursive` requires a workaround that
   isn't a simple filter — e.g., custom recursion, manual attr
   construction, special-case handling for sub-scopes.
2. `evalModules` rejects the `update.nix` files for any reason
   other than missing options or syntax errors.
3. The merge-up walker double-counts files, includes non-update
   files, or requires post-hoc filtering of its output.
4. Adding a new package requires ANY edit outside its own
   directory (other than the `source.nix` edit explicitly allowed
   in Task 4.1 Step 2 for the multi-output stub).
5. The factory in `packages/mcp-servers/lib/mkMcpServer.nix`
   needs modification to work in the sandbox scope (the copy
   should be byte-identical).

Each of these is a (D) finding — document in
`docs/name-resolution-gap-analysis.md` and pause before
proceeding.
