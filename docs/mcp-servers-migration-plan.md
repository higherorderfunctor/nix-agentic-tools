# mcp-servers Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking. **Every phase
> ends with a HITL CHECKPOINT — STOP. Do not proceed without
> explicit user approval.**
>
> **Supersedes:** `docs/mcp-servers-pilot-plan.md` (the
> parallel-sandbox approach, abandoned in favor of direct
> migration after grill 2 reframed the constraint).

**Goal:** Migrate the 12 standalone MCP server packages from
flat `packages/<name>-mcp/` into a `packages/mcp-servers/<name>/`
slice with greenfield package shape (`package.nix` callPackage
function + thin barrel with uniform path values), via per-slice
auto-discovery, while preserving every consumer-facing flake
output.

**Architecture:** Each MCP becomes a directory with a
`package.nix` (callPackage-style function preserving the
`ourPkgs` cache-hit-parity pattern) and a thin `default.nix`
barrel of paths. The slice itself owns its auto-discovery via
`packages/mcp-servers/overlay.nix`, which walks child dirs and
returns an attrset of derivations compatible with the existing
manual barrel in `overlays/default.nix`. The manual barrel
shrinks to one entry per slice instead of one entry per package.
Cache-hit parity is preserved at every step (checked by the
existing `checks.cache-hit-parity` flake check). The
`modelcontextprotocol` family preserves its sub-namespace
(`pkgs.ai.mcpServers.modelContextProtocol.*`) via a sub-slice
with shared source.

**Tech Stack:**

- Nix flakes
- `builtins.readDir` + manual filtering for slice auto-discovery
  (more predictable than `lib.filesystem.packagesFromDirectoryRecursive`
  given inter-package deps and namespace shaping)
- Existing `ourPkgs` pattern + `vu.mkVersion` from `overlays/lib.nix`
- Existing `ensureUnfreeCheck` wrapper from `overlays/default.nix`
  (applied at slice boundary, not changed)
- `checks.cache-hit-parity` regression gate

---

## File Structure

| Path                                                          | Responsibility                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `packages/mcp-servers/default.nix`                            | Slice barrel. Literal attrset of paths: `{ overlay = ./overlay.nix; ... }`. Picked up by project-level `packages/default.nix` walker.                                                                                                                                                                        |
| `packages/mcp-servers/overlay.nix`                            | Slice's auto-discovery walker. Function `{inputs, final}: {<name> = ...}`. Reads `./` for child dirs with `package.nix`, imports each as a derivation. Returns flat attrset for `overlays/default.nix:mcpServerDrvs` to consume. Handles `modelcontextprotocol/` sub-namespace via its own sub-slice walker. |
| `packages/mcp-servers/<name>/default.nix`                     | Per-MCP barrel. Literal attrset of paths: `{ package = ./package.nix; }` plus other facets as they migrate (none initially).                                                                                                                                                                                 |
| `packages/mcp-servers/<name>/package.nix`                     | Per-MCP derivation function. **Verbatim port** of `overlays/mcp-servers/<name>.nix` — same `{inputs, final, ...}` signature, same `ourPkgs` pattern, same `vu` import.                                                                                                                                       |
| `packages/mcp-servers/modelContextProtocol/overlay.nix`       | Sub-slice walker. Returns sub-attrset placed at `pkgs.ai.mcpServers.modelContextProtocol.*`.                                                                                                                                                                                                                 |
| `packages/mcp-servers/modelContextProtocol/source.nix`        | Shared upstream source pin (moved from `overlays/mcp-servers/modelcontextprotocol/source.nix` if it exists there; verify during phase 2).                                                                                                                                                                    |
| `packages/mcp-servers/modelContextProtocol/<sub>/package.nix` | Per-sub-package derivation. Imports `../source.nix`.                                                                                                                                                                                                                                                         |
| `overlays/default.nix`                                        | Modified: replaces hand-rolled `mcpServerDrvs = { context7-mcp = ...; ...; }` with `mcpServerDrvs = (import ../packages/mcp-servers/overlay.nix) { inherit inputs final; };`.                                                                                                                                |
| `overlays/mcp-servers/<name>.nix`                             | Deleted as each MCP migrates (per phase). Final state: directory empty (or contains only files we explicitly chose not to migrate).                                                                                                                                                                          |
| `packages/<name>-mcp/`                                        | Deleted/renamed as each MCP migrates. The flat-layout per-MCP barrels (e.g. `packages/effect-mcp/default.nix`) get folded into their new home under `packages/mcp-servers/`.                                                                                                                                 |
| `packages/default.nix`                                        | Modified: removes the old flat `<name>-mcp = import ./<name>-mcp;` lines as each MCP migrates. The slice itself stays referenced via `mcp-servers = import ./mcp-servers;`.                                                                                                                                  |

**Naming policy (Policy A from grill 2):** Preserve flat
`pkgs.<name>` outputs at the flake level via the existing
`removeAttrs pkgs.ai.mcpServers ["modelContextProtocol"]`
flattening (`flake.nix:391`). Consumers reading `pkgs.context7-mcp`
or `pkgs.effect-mcp` see no change. nixos-config impact: zero
unless we explicitly choose to drop flattening later.

---

## Constraints (apply to every phase)

- **HITL CHECKPOINT — STOP at every phase boundary.** Wait for
  explicit user approval before moving to next phase. Tests run
  by the user, not assumed.
- **Never update nixos-config without explicit approval.** Even
  trivial path updates require the user to authorize the specific
  diff first. See `feedback_nixos_config_hitl.md`.
- **Cache-hit parity.** `nix build .#checks.x86_64-linux.cache-hit-parity`
  must remain green at every commit. The `ourPkgs` pattern is
  load-bearing; do not introduce `final.X` build inputs in any
  migrated `package.nix`.
- **Three-argument overlay signature.** Per-package files keep
  `{inputs, final, ...}:` shape. The slice walker takes
  `{inputs, final}:` (no third arg — we're constructing an
  attrset, not an overlay layer).
- **`ensureUnfreeCheck` boundary stays.** It's applied in
  `overlays/default.nix` via the `guard` mapAttrs. Don't
  duplicate it inside the slice — keep it at the boundary.
- **No nix-store mutations.** No `chmod`/`sed` on store paths
  (per `.claude/rules/nix-standards.md`).
- **`git add` new files** before any `nix flake check` or
  `.#`-prefixed eval.
- **`nix flake check` stays green** after each commit.
- **One package per commit** during mechanical migrations
  (Phase 3). Each commit independently revertible.

---

## Phase 1: Slice infrastructure + first MCP migration

**Pick:** `effect-mcp` — single overlay file, no platform-specific
sources.json sidecar, no inter-package deps. Cleanest first case.

### Task 1.1: Create the slice scaffold

**Files:**

- Create: `packages/mcp-servers/.gitkeep`

- [ ] **Step 1: Create the slice directory**

```bash
mkdir -p packages/mcp-servers
touch packages/mcp-servers/.gitkeep
```

- [ ] **Step 2: Verify directory exists**

Run: `ls -la packages/mcp-servers/`

Expected: directory exists with one `.gitkeep` file.

- [ ] **Step 3: Commit**

```bash
git add packages/mcp-servers/
git commit -m "chore(mcp-servers): create slice directory"
```

---

### Task 1.2: Migrate effect-mcp's barrel + package.nix

**Files:**

- Create: `packages/mcp-servers/effect-mcp/default.nix`
- Create: `packages/mcp-servers/effect-mcp/package.nix` (verbatim port)
- Delete: `packages/mcp-servers/.gitkeep`

- [ ] **Step 1: Read existing effect-mcp overlay file**

Run: `cat overlays/mcp-servers/effect-mcp.nix`

Confirm the file exists and uses the `ourPkgs` pattern with
`{inputs, final, ...}:` signature. Note its imports (`vu`,
`fetchPnpmDeps`, etc.) for the verbatim copy.

- [ ] **Step 2: Read existing effect-mcp package barrel**

Run: `cat packages/effect-mcp/default.nix`

Confirm shape (literal attrset). Note any non-package-related
facets (docs, fragments, lib helpers) — they need to come along.

- [ ] **Step 3: Create the new barrel**

Create `packages/mcp-servers/effect-mcp/default.nix`:

```nix
# Per-MCP barrel. Literal attrset of paths — uniform value
# semantics. Walker decides how to consume each facet.
{
  package = ./package.nix;
}
```

Note: if Step 2 surfaced non-package facets in the old barrel
(e.g. `docs = ./docs`, `fragments = ./fragments`, `lib...`), add
them to this barrel as paths and copy the directories in a
follow-up step. For effect-mcp specifically, verify the contents
of `packages/effect-mcp/` to determine which facets exist.

Sub-step 3a: enumerate effect-mcp's existing barrel contents.

```bash
ls packages/effect-mcp/
```

Sub-step 3b: for each non-`default.nix` file or directory found,
add a corresponding `<facet> = ./<facet>;` entry to the new
barrel and `cp -r packages/effect-mcp/<facet> packages/mcp-servers/effect-mcp/<facet>`.

- [ ] **Step 4: Copy the overlay file as package.nix (verbatim)**

```bash
cp overlays/mcp-servers/effect-mcp.nix packages/mcp-servers/effect-mcp/package.nix
```

The relative-import path inside `package.nix` for `vu` will need
adjusting. Original references `../lib.nix` (i.e.
`overlays/lib.nix`). The new location needs the same final
target.

- [ ] **Step 5: Adjust the relative `vu` import path**

Open `packages/mcp-servers/effect-mcp/package.nix`. Find this
line (was `vu = import ../lib.nix;` in the original):

```nix
  vu = import ../lib.nix;
```

Replace with (relative path from new location to `overlays/lib.nix`):

```nix
  vu = import ../../../overlays/lib.nix;
```

(From `packages/mcp-servers/effect-mcp/` up three levels to repo
root, then into `overlays/lib.nix`.)

Verify the path resolves:

```bash
ls $(realpath packages/mcp-servers/effect-mcp/../../../overlays/lib.nix)
```

Expected output: `<repo-root>/overlays/lib.nix`

- [ ] **Step 6: Verify the new package.nix evaluates**

Run: `nix eval --impure --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    drv = import ./packages/mcp-servers/effect-mcp/package.nix {
      inherit inputs;
      final = pkgs;
    };
  in drv.name'`

Expected: a string starting with `effect-mcp-`.

If this fails at IFD time (path '/nix/store/...-source.drv' is
not valid), add `--option allow-import-from-derivation true` to
the eval command. The version computation reads from the fetched
source.

- [ ] **Step 7: Remove the .gitkeep**

```bash
rm -f packages/mcp-servers/.gitkeep
```

- [ ] **Step 8: git add and verify**

```bash
git add packages/mcp-servers/effect-mcp/
git status --short
```

Expected: new files staged, nothing else changed yet (the old
overlay file, old package barrel, and overlays/default.nix are
all still on disk and untouched).

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(mcp-servers): migrate effect-mcp to slice (package + barrel)"
```

---

### Task 1.3: Wire the slice walker

**Files:**

- Create: `packages/mcp-servers/overlay.nix`

- [ ] **Step 1: Write the slice walker**

Create `packages/mcp-servers/overlay.nix`:

```nix
# Slice walker for the mcp-servers slice. Auto-discovers child
# directories that contain a `package.nix` and imports each as a
# derivation, returning a flat attrset suitable for consumption
# by overlays/default.nix's mcpServerDrvs composition.
#
# Sub-namespaces (e.g. modelContextProtocol) are handled by
# detecting an `overlay.nix` in a child dir — those are
# sub-slices that contribute a sub-attrset keyed on the
# directory name. Use mixed-case dir names where the namespace
# requires mixed case (e.g. modelContextProtocol/).
#
# The cache-hit-parity contract is enforced one level down — each
# package.nix uses the ourPkgs pattern. This walker is a pure
# attrset builder; it does not introduce any new build inputs.
{
  inputs,
  final,
}: let
  entries = builtins.readDir ./.;

  isDir = name: entries.${name} == "directory";
  childDirs = builtins.filter isDir (builtins.attrNames entries);

  hasFile = dir: file:
    builtins.pathExists (./. + "/${dir}/${file}");

  isLeafPackage = name: hasFile name "package.nix";
  isSubSlice = name: hasFile name "overlay.nix" && !(hasFile name "package.nix");

  leafPackages = builtins.filter isLeafPackage childDirs;
  subSlices = builtins.filter isSubSlice childDirs;

  importLeaf = name: {
    inherit name;
    value = import (./. + "/${name}/package.nix") {
      inherit inputs final;
    };
  };

  importSubSlice = name: {
    inherit name;
    value = import (./. + "/${name}/overlay.nix") {
      inherit inputs final;
    };
  };

  leafAttrs = builtins.listToAttrs (map importLeaf leafPackages);
  subSliceAttrs = builtins.listToAttrs (map importSubSlice subSlices);
in
  leafAttrs // subSliceAttrs
```

- [ ] **Step 2: Verify the walker evaluates with effect-mcp present and nothing else migrated**

Run:

```bash
nix eval --impure --json --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    slice = import ./packages/mcp-servers/overlay.nix {
      inherit inputs;
      final = pkgs;
    };
  in builtins.attrNames slice'
```

Expected output: `["effect-mcp"]`

If this fails with IFD errors, add `--option allow-import-from-derivation true`.

- [ ] **Step 3: Commit**

```bash
git add packages/mcp-servers/overlay.nix
git commit -m "feat(mcp-servers): add slice walker for auto-discovery"
```

---

### Task 1.4: Wire slice walker into overlays/default.nix and remove old effect-mcp wiring

**Files:**

- Modify: `overlays/default.nix`
- Delete: `overlays/mcp-servers/effect-mcp.nix`
- Delete: `packages/effect-mcp/` (if Task 1.2 Step 3b verified all facets were migrated)
- Modify: `packages/default.nix`

- [ ] **Step 1: Read current overlays/default.nix:mcpServerDrvs**

Run: `awk '/mcpServerDrvs = {/,/};/' overlays/default.nix`

Confirm the `effect-mcp` entry exists at the expected location.

- [ ] **Step 2: Add slice walker contribution to mcpServerDrvs incrementally**

**Critical:** Phase 1 only migrates `effect-mcp`. The other 11
MCP entries in `mcpServerDrvs` are still inline-bound and must
stay until each is individually migrated. The slice walker at
this point returns ONLY `{effect-mcp = ...;}`. We **merge** that
into the existing barrel and drop only the `effect-mcp = ...`
inline entry.

In `overlays/default.nix`, locate the `mcpServerDrvs = { ... };`
block (currently at lines 69–100 per repo state at plan-write
time). Modify the block so it:

- Removes the inline `effect-mcp = import ./mcp-servers/effect-mcp.nix {...};` line.
- Adds `// (import ../packages/mcp-servers/overlay.nix) {inherit inputs final;}` to the end.

Result (post-Phase-1 shape):

```nix
  mcpServerDrvs = {
    inherit modelContextProtocol;
    context7-mcp = import ./mcp-servers/context7-mcp.nix {inherit inputs final;};
    # ... all other inline entries EXCEPT effect-mcp ...
    sympy-mcp = import ./mcp-servers/sympy-mcp.nix {inherit inputs final;};
  } // ((import ../packages/mcp-servers/overlay.nix) {inherit inputs final;});
```

The merge order matters: the slice walker output is on the right,
so its keys take precedence. As each subsequent migration moves
one MCP into the slice, that MCP's inline entry gets removed (the
slice walker now provides it) — the explicit precedence prevents
silent drift if both ever coexist briefly during a migration.

The `agnixMcp` `let`-binding (currently line 108) and the
output-assembly `{agnix-mcp = agnixMcp;}` merge stay untouched —
agnix-mcp is a multi-binary override of `flatDrvs.agnix` and is
intentionally kept out of the slice (see "Stop conditions" #6).

- [ ] **Step 3: Verify the migrated package still builds**

Run: `nix build .#packages.x86_64-linux.effect-mcp --no-link --print-out-paths`

Expected output: a `/nix/store/...-effect-mcp-*` path, identical
to what it was before this commit (the package.nix was a verbatim
port, so the derivation hash should match).

To verify hash unchanged:

```bash
nix eval --raw .#packages.x86_64-linux.effect-mcp.drvPath
```

Compare against pre-migration value (capture before this phase).

- [ ] **Step 4: Verify cache-hit-parity check still green**

Run: `nix build .#checks.x86_64-linux.cache-hit-parity 2>&1 | tail -5`

Expected: build succeeds. Read `result` for content; should say
no drift detected.

```bash
cat result
```

Expected: a message indicating no drift, OR a list that does NOT
include `effect-mcp` as a regression.

- [ ] **Step 5: Remove the old overlay file**

```bash
rm overlays/mcp-servers/effect-mcp.nix
```

- [ ] **Step 6: Remove the old per-MCP package barrel**

Verify the old `packages/effect-mcp/` has no remaining unique
content (Task 1.2 Step 3b should have caught this):

```bash
ls -la packages/effect-mcp/
```

If only `default.nix` remains and that just exposed paths
already migrated, remove the directory:

```bash
git rm -rf packages/effect-mcp/
```

If non-trivial content remains, STOP and surface it for the user
to review before deletion.

- [ ] **Step 7: Update packages/default.nix to remove effect-mcp entry**

Edit `packages/default.nix`. Find:

```nix
  effect-mcp = import ./effect-mcp;
```

Remove it. The slice itself is referenced via:

```nix
  mcp-servers = import ./mcp-servers;
```

(Add this line if it's not yet present. The slice barrel returns
a literal attrset, so this works with the existing walker.)

- [ ] **Step 8: Verify nothing broke**

Run:

```bash
nix flake check 2>&1 | tail -10
nix eval --raw .#packages.x86_64-linux.effect-mcp.drvPath
```

Expected:

- flake check passes (no new failures versus pre-phase baseline)
- effect-mcp drvPath unchanged from pre-phase value

- [ ] **Step 9: Commit**

```bash
git add overlays/default.nix overlays/mcp-servers/effect-mcp.nix packages/default.nix packages/effect-mcp/
git commit -m "refactor(mcp-servers): wire slice walker; migrate effect-mcp end-to-end"
```

(`git add` may need `-A` or per-file paths since deleted files
need staging. Check `git status` between add and commit.)

---

### HITL CHECKPOINT — Phase 1 — STOP

**Tests for the user to run:**

1. `nix flake check` — should pass with no new failures.
2. `nix build .#packages.x86_64-linux.effect-mcp` — should
   succeed and produce a store path identical to the pre-phase
   value.
3. `nix build .#checks.x86_64-linux.cache-hit-parity` — should
   succeed; `cat result` should report no drift.
4. **In nixos-config:** `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
   (or whatever your local flake check is) — should succeed
   without changes. effect-mcp should still resolve as
   `pkgs.effect-mcp` and produce an unchanged store path.

**nixos-config changes:** None required for Phase 1.

**Do not proceed to Phase 2 without explicit user approval.**

---

## Phase 2: Multi-output (modelcontextprotocol family)

The `modelContextProtocol` sub-namespace already exists at
`overlays/mcp-servers/modelcontextprotocol/`. This phase migrates
it to `packages/mcp-servers/modelContextProtocol/` as a sub-slice.

**Note on directory naming:** The existing overlay dir is
lowercase `modelcontextprotocol/` but the namespace key is
mixed-case `modelContextProtocol` (rebound at
`overlays/default.nix:67`). For the new slice sub-directory, use
mixed-case `modelContextProtocol/` to match the namespace
directly — eliminates the rebind and keeps the slice walker
generic.

### Task 2.1: Survey the existing modelcontextprotocol structure

- [ ] **Step 1: List existing files**

Run:

```bash
ls -laR overlays/mcp-servers/modelcontextprotocol/
```

Capture the structure: shared source file (likely `source.nix` or
similar), per-sub-package `.nix` files, the directory's
`default.nix` that aggregates them.

- [ ] **Step 2: Read the directory's default.nix**

Run: `cat overlays/mcp-servers/modelcontextprotocol/default.nix`

Confirm it returns an attrset of derivations that gets placed at
`pkgs.ai.mcpServers.modelContextProtocol.*`. Note the names of
sub-packages.

- [ ] **Step 3: Read the shared source.nix (or equivalent)**

Run: `cat overlays/mcp-servers/modelcontextprotocol/source.nix`
(or whatever the shared-source file is called).

Note its `{rev, hash, ...}` shape and how sub-package files
import it.

---

### Task 2.2: Create the sub-slice scaffold

**Files:**

- Create: `packages/mcp-servers/modelContextProtocol/overlay.nix`
- Create: `packages/mcp-servers/modelContextProtocol/source.nix` (copy from `overlays/mcp-servers/modelcontextprotocol/source.nix` if it exists, otherwise materialized from existing shared-source pattern)

- [ ] **Step 1: Copy the shared source**

```bash
cp overlays/mcp-servers/modelcontextprotocol/source.nix \
   packages/mcp-servers/modelContextProtocol/source.nix
```

(Substitute the actual filename if it's not `source.nix`. Verify
in Task 2.1 Step 3.)

- [ ] **Step 2: Write the sub-slice walker**

Create `packages/mcp-servers/modelContextProtocol/overlay.nix`:

```nix
# Sub-slice for modelcontextprotocol/servers monorepo packages.
# Same auto-discovery shape as the parent slice walker, scoped to
# this sub-namespace. The shared source.nix is imported by
# sub-package package.nix files directly, NOT walked.
#
# Returns: { <name> = <derivation>; ... } placed at
# pkgs.ai.mcpServers.modelContextProtocol.<name> via the parent
# slice walker.
{
  inputs,
  final,
}: let
  entries = builtins.readDir ./.;

  hasFile = dir: file:
    builtins.pathExists (./. + "/${dir}/${file}");

  isLeafPackage = name: hasFile name "package.nix";

  childDirs =
    builtins.attrNames (lib.filterAttrs (_: t: t == "directory") entries);
  # Use builtins.lib not nixpkgs.lib at this scope — the walker
  # function doesn't bind lib. Inline the filter:
  # (replace the let-binding above with the inline below in the
  # actual file)
in
  builtins.listToAttrs (map (name: {
    inherit name;
    value = import (./. + "/${name}/package.nix") {inherit inputs final;};
  }) (builtins.filter isLeafPackage (
    builtins.attrNames (builtins.foldl' (acc: n:
      if entries.${n} == "directory"
      then acc // {${n} = null;}
      else acc) {} (builtins.attrNames entries))
  )))
```

Actually use the same shape as the parent walker. Inline the
directory-filtering:

```nix
{
  inputs,
  final,
}: let
  entries = builtins.readDir ./.;

  isDir = name: entries.${name} == "directory";
  childDirs = builtins.filter isDir (builtins.attrNames entries);

  hasPackageNix = name:
    builtins.pathExists (./. + "/${name}/package.nix");

  leafPackages = builtins.filter hasPackageNix childDirs;

  importLeaf = name: {
    inherit name;
    value = import (./. + "/${name}/package.nix") {
      inherit inputs final;
    };
  };
in
  builtins.listToAttrs (map importLeaf leafPackages)
```

(Cleaner. Use this version.)

- [ ] **Step 3: Verify the sub-slice evaluates empty**

At this point no sub-packages exist in
`packages/mcp-servers/modelContextProtocol/<name>/`. The walker
should return `{}`.

Run:

```bash
nix eval --impure --json --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    sub = import ./packages/mcp-servers/modelContextProtocol/overlay.nix {
      inherit inputs;
      final = pkgs;
    };
  in builtins.attrNames sub'
```

Expected output: `[]`

- [ ] **Step 4: Commit**

```bash
git add packages/mcp-servers/modelContextProtocol/
git commit -m "feat(mcp-servers): add modelcontextprotocol sub-slice scaffold + shared source"
```

---

### Task 2.3: Migrate each modelcontextprotocol sub-package

For each sub-package `<sub>` in the original
`overlays/mcp-servers/modelcontextprotocol/` (excluding the
directory's `default.nix` and `source.nix`):

- [ ] **Step 1: Create per-sub-package barrel and package.nix**

Substitute `<sub>` with the actual sub-package name. Repeat for
each.

```bash
mkdir -p packages/mcp-servers/modelContextProtocol/<sub>
cp overlays/mcp-servers/modelcontextprotocol/<sub>.nix \
   packages/mcp-servers/modelContextProtocol/<sub>/package.nix
```

Create `packages/mcp-servers/modelContextProtocol/<sub>/default.nix`:

```nix
{
  package = ./package.nix;
}
```

- [ ] **Step 2: Adjust import paths in package.nix**

The original file's `import ../source.nix` becomes
`import ../source.nix` (still one level up — `<sub>/package.nix`
to `../source.nix`).

The original file's `import ../../lib.nix` (vu) becomes
`import ../../../../overlays/lib.nix`. Verify the path:

```bash
ls $(realpath packages/mcp-servers/modelContextProtocol/<sub>/../../../../overlays/lib.nix)
```

Expected: `<repo-root>/overlays/lib.nix`.

Edit `packages/mcp-servers/modelContextProtocol/<sub>/package.nix`:

- Replace `vu = import ../../lib.nix;` (or similar) with
  `vu = import ../../../../overlays/lib.nix;`.
- Verify `import ../source.nix` (or whatever shared-source
  reference) still resolves.

- [ ] **Step 3: Verify package.nix evaluates**

```bash
nix eval --impure --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    drv = import ./packages/mcp-servers/modelContextProtocol/<sub>/package.nix {
      inherit inputs;
      final = pkgs;
    };
  in drv.name'
```

Expected: a string starting with the upstream package's name.

- [ ] **Step 4: Verify it appears in the sub-slice walker**

```bash
nix eval --impure --json --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    sub = import ./packages/mcp-servers/modelContextProtocol/overlay.nix {
      inherit inputs;
      final = pkgs;
    };
  in builtins.attrNames sub'
```

Expected: `["<sub>"]` (or `["<sub-1>", "<sub-2>", ...]` once
multiple are migrated).

- [ ] **Step 5: git add**

```bash
git add packages/mcp-servers/modelContextProtocol/<sub>/
```

- [ ] **Step 6: Commit (one per sub-package)**

```bash
git commit -m "feat(mcp-servers): migrate modelcontextprotocol/<sub>"
```

---

### Task 2.4: Swap the sub-slice into overlays/default.nix and remove the old directory

**Files:**

- Modify: `overlays/default.nix`
- Delete: `overlays/mcp-servers/modelcontextprotocol/`

- [ ] **Step 1: Locate the modelContextProtocol binding in overlays/default.nix**

Run: `grep -n "modelContextProtocol" overlays/default.nix`

Expected: a line `modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};`

- [ ] **Step 2: Update the binding to use the new sub-slice**

Edit `overlays/default.nix`. Find:

```nix
  modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};
```

Replace with:

```nix
  modelContextProtocol = import ../packages/mcp-servers/modelContextProtocol/overlay.nix {inherit inputs final;};
```

- [ ] **Step 3: Verify build of one sub-package preserves drvPath**

Pick one sub-package name (e.g. the first one migrated in Task 2.3,
say `<sub-name>`). Capture its drvPath BEFORE this step (rerun
the migration without Task 2.4 if needed):

```bash
# Pre-migration (revert and capture), then re-apply Task 2.4:
nix eval --raw .#packages.x86_64-linux.modelcontextprotocol-all-mcps.drvPath
```

Compare before/after for the sub-package's actual derivation. If
identical, the verbatim port worked.

If `pkgs.ai.mcpServers.modelContextProtocol.<sub-name>` is not
exposed at the flake level, query directly:

```bash
nix eval --raw --impure --expr '
  (import <nixpkgs> {
    overlays = [(import ./. {}).overlays.default];
  }).ai.mcpServers.modelContextProtocol.<sub-name>.drvPath'
```

- [ ] **Step 4: Run cache-hit-parity check**

```bash
nix build .#checks.x86_64-linux.cache-hit-parity 2>&1 | tail -5
cat result
```

Expected: no drift detected.

- [ ] **Step 5: Remove the old modelcontextprotocol directory**

```bash
git rm -rf overlays/mcp-servers/modelcontextprotocol/
```

- [ ] **Step 6: Verify flake check**

```bash
nix flake check 2>&1 | tail -10
```

Expected: no new failures.

- [ ] **Step 7: Commit**

```bash
git add overlays/default.nix overlays/mcp-servers/modelcontextprotocol/
git commit -m "refactor(mcp-servers): wire modelcontextprotocol sub-slice; remove old overlay dir"
```

---

### HITL CHECKPOINT — Phase 2 — STOP

**Tests for the user to run:**

1. `nix flake check` — pass.
2. `nix build .#modelcontextprotocol-all-mcps` (or whatever the
   top-level flake output is) — succeed with unchanged store
   path.
3. `nix build .#checks.x86_64-linux.cache-hit-parity` — pass.
4. **In nixos-config:** rebuild and verify
   `pkgs.ai.mcpServers.modelContextProtocol.*` resolves and
   produces unchanged store paths.

**nixos-config changes:** None required.

**Do not proceed to Phase 3 without explicit user approval.**

---

## Phase 3: Mechanical migration of remaining standalone MCPs

Same per-MCP shape as Task 1.2 + 1.4. Repeat for each remaining
MCP. One commit per package. Cache-hit parity check after each
group of three migrations.

### Remaining MCPs to migrate (verify list at execution time)

Per `overlays/default.nix:69-100` (subject to the live state at
phase start):

- context7-mcp
- fetch-mcp (if currently in overlays/mcp-servers/)
- git-intel-mcp
- git-mcp (if currently in overlays/mcp-servers/)
- github-mcp
- kagi-mcp
- mcp-language-server
- mcp-proxy
- nixos-mcp
- openmemory-mcp
- sequential-thinking-mcp (if currently in overlays/mcp-servers/)
- serena-mcp
- sympy-mcp

(Some of these may need verification — read the current
`overlays/default.nix:mcpServerDrvs` block at phase start to get
the live list.)

### Task 3.N: Migrate each MCP

For each MCP `<name>` in the list above, run the per-package
migration recipe:

- [ ] **Step 1: Pre-migration capture**

```bash
nix eval --raw .#packages.x86_64-linux.<name>.drvPath > /tmp/<name>-before.drvPath
cat /tmp/<name>-before.drvPath
```

- [ ] **Step 2: Create the per-MCP barrel + verbatim package.nix port**

```bash
mkdir -p packages/mcp-servers/<name>
cp overlays/mcp-servers/<name>.nix packages/mcp-servers/<name>/package.nix
```

Create `packages/mcp-servers/<name>/default.nix`:

```nix
{
  package = ./package.nix;
}
```

If the existing `packages/<name>-mcp/` (or `packages/<name>/`)
has additional facets (docs, fragments, lib helpers), enumerate
and copy them, adding `<facet> = ./<facet>;` paths to the new
barrel.

- [ ] **Step 3: Adjust the vu import path**

In `packages/mcp-servers/<name>/package.nix`, replace
`import ../lib.nix` with `import ../../../overlays/lib.nix`.

If the package imports any other relative paths (e.g.
`./<name>-helpers.nix` co-located in the original
`overlays/mcp-servers/`), ensure those helpers come along too —
either copied into the new dir or referenced by absolute path
through the slice.

- [ ] **Step 4: Verify package.nix evaluates**

```bash
nix eval --impure --expr '
  let
    pkgs = import <nixpkgs> {};
    inputs = { nixpkgs = <nixpkgs>; };
    drv = import ./packages/mcp-servers/<name>/package.nix {
      inherit inputs;
      final = pkgs;
    };
  in drv.name'
```

Expected: a string starting with `<name>-`.

- [ ] **Step 5: Remove the old overlay file**

```bash
git rm overlays/mcp-servers/<name>.nix
```

- [ ] **Step 6: Remove the inline entry from overlays/default.nix:mcpServerDrvs**

Edit `overlays/default.nix`. In the `mcpServerDrvs` block, find:

```nix
    <name> = import ./mcp-servers/<name>.nix {inherit inputs final;};
```

Remove that line. The slice walker (already wired in Phase 1)
now provides this package via auto-discovery from
`packages/mcp-servers/<name>/package.nix`.

- [ ] **Step 7: Remove the old per-package dir if it exists**

If `packages/<name>-mcp/` (or `packages/<name>/`) existed and all
its facets have been migrated, remove it:

```bash
git rm -rf packages/<name>-mcp/
# OR (if directory was named without -mcp suffix):
git rm -rf packages/<name>/
```

If non-trivial content remains, STOP and surface for review.

- [ ] **Step 8: Update packages/default.nix**

Remove the line `<name>-mcp = import ./<name>-mcp;` (or
`<name> = import ./<name>;`) from `packages/default.nix`.

- [ ] **Step 9: Verify drvPath unchanged**

```bash
nix eval --raw .#packages.x86_64-linux.<name>.drvPath > /tmp/<name>-after.drvPath
diff /tmp/<name>-before.drvPath /tmp/<name>-after.drvPath
```

Expected: empty diff (drvPath unchanged → store path unchanged →
cache hit preserved).

If diff is non-empty, STOP. Investigate root cause (likely a
relative-path miss in the verbatim port). Don't paper over.

- [ ] **Step 9: Run cache-hit-parity check**

```bash
nix build .#checks.x86_64-linux.cache-hit-parity 2>&1 | tail -5
```

Expected: pass.

- [ ] **Step 10: Run flake check**

```bash
nix flake check 2>&1 | tail -10
```

Expected: no new failures.

- [ ] **Step 11: Commit**

```bash
git add -A packages/mcp-servers/<name>/ overlays/mcp-servers/<name>.nix packages/<name>-mcp/ packages/default.nix
git commit -m "refactor(mcp-servers): migrate <name> to slice"
```

---

### HITL CHECKPOINT — Phase 3 — STOP

After all remaining MCPs are migrated:

**Tests for the user to run:**

1. `nix flake check` — pass.
2. `nix build .#packages.x86_64-linux.<name>` for each migrated
   package — should produce unchanged store paths.
3. `nix build .#checks.x86_64-linux.cache-hit-parity` — pass.
4. `ls overlays/mcp-servers/` — should be empty (or contain only
   files we explicitly deferred, e.g. `agnix-mcp.nix` which is a
   multi-binary override).
5. **In nixos-config:** rebuild and verify all
   `pkgs.<mcp-name>` and `pkgs.ai.mcpServers.<mcp-name>`
   references resolve to unchanged store paths.

**nixos-config changes:** None required (Policy A preserves flat
outputs).

**Do not proceed to Phase 4 without explicit user approval.**

---

## Phase 4: nixos-config impact review (HITL — user-driven)

This phase is intentionally minimal because Policy A preserves
all consumer-facing flake outputs. It exists to provide a
checkpoint for the user to verify the consumer side and to
record any cleanup that the user chooses to do.

### Task 4.1: Diff consumer interface before/after

- [ ] **Step 1: Capture all migrated package drvPaths**

```bash
for name in effect-mcp context7-mcp git-intel-mcp github-mcp kagi-mcp mcp-language-server mcp-proxy nixos-mcp openmemory-mcp serena-mcp sympy-mcp; do
  echo -n "$name: "
  nix eval --raw .#packages.x86_64-linux.$name.drvPath 2>/dev/null || echo "NOT FOUND"
done
```

Save output. (Run on a non-migration-WIP commit to capture
post-migration baseline.)

- [ ] **Step 2: Capture homeManagerModules.default invariance**

```bash
nix eval --json .#homeManagerModules.default.imports --apply 'builtins.length'
```

Expected: same length as pre-migration baseline (sandbox didn't
add any imports; migration shouldn't either).

- [ ] **Step 3: Inventory remaining `overlays/` content**

```bash
ls overlays/mcp-servers/ overlays/git-tools/ overlays/lsp-servers/
```

Document what's left after this phase. Files NOT migrated:

- `overlays/mcp-servers/agnix-mcp.nix` — multi-binary override of
  flatDrvs.agnix; out of scope for this migration.
- (anything else left)

This becomes input for a future "agnix slice" migration if/when
the user decides to migrate that area.

---

### Task 4.2: HITL — record consumer-side adjustments (if any)

- [ ] **Step 1: Pause and ask the user**

If everything in Phase 4 Task 4.1 came back clean, no nixos-config
changes are needed. The migration is complete on the
nix-agentic-tools side.

If anything looks off (drvPath drift, missing output, etc.),
surface to the user with a specific diff and proposed fix. Do
NOT make the fix without explicit approval.

---

### HITL CHECKPOINT — Phase 4 — STOP

**Tests for the user to run:**

1. Full nixos-config rebuild (`nixos-rebuild build` or whatever
   the local flake check is).
2. Verify any specific MCP server they actively use boots
   correctly when invoked.

**nixos-config changes:** None expected. If the user wants any,
they author them; agent does not edit nixos-config without
explicit approval per `feedback_nixos_config_hitl.md`.

**Phase 4 ends the migration. Phase 5 is optional cleanup.**

---

## Phase 5 (OPTIONAL): walker simplification

After all MCPs are migrated, `overlays/default.nix:mcpServerDrvs`
is a one-line call to the slice walker. The manual barrel for
the OTHER groups (`flatDrvs`, `gitToolDrvs`) is unchanged.

### Decision point

If the user wants to extend the per-slice pattern to
`flatDrvs` (claude-code, kiro-cli, copilot-cli, etc.) and
`gitToolDrvs` (git-absorb, git-branchless, git-revise), that's
analogous slice migrations: each becomes a `packages/<slice>/`
with its own `overlay.nix`.

If the user wants to leave `flatDrvs` and `gitToolDrvs` as manual
barrels (they're stable and small), this phase is skipped.

The slice walker pattern in `overlays/default.nix` becomes:

```nix
mcpServerDrvs = (import ../packages/mcp-servers/overlay.nix) {inherit inputs final;};
# Future, if user opts in:
# flatDrvs = (import ../packages/ai-clis/overlay.nix) {inherit inputs final;};
# gitToolDrvs = (import ../packages/git-tools/overlay.nix) {inherit inputs final;};
```

No code change in this plan — this is just the optionality
record.

---

## Verification checklist (run before declaring complete)

When all phases are executed, ALL of these must hold:

- [ ] `nix flake check` passes.
- [ ] `nix build .#checks.x86_64-linux.cache-hit-parity` passes;
      `cat result` reports no drift.
- [ ] Every migrated package's drvPath is identical to its
      pre-migration value.
- [ ] `homeManagerModules.default.imports` length unchanged.
- [ ] `ls overlays/mcp-servers/` contains only files we
      explicitly deferred (e.g. `agnix-mcp.nix`).
- [ ] `packages/<name>-mcp/` and `packages/<name>/` (for
      migrated MCPs) no longer exist.
- [ ] `packages/mcp-servers/<name>/` exists for each migrated
      MCP with `default.nix` + `package.nix`.
- [ ] `packages/mcp-servers/modelContextProtocol/<sub>/` exists
      for each modelcontextprotocol sub-package.
- [ ] `packages/default.nix` has `mcp-servers = import ./mcp-servers;`
      and no per-MCP entries for migrated packages.
- [ ] User has run a nixos-config rebuild and confirmed no
      breakage.

---

## Stop conditions (escalate, do not power through)

If any of these surface during execution, STOP and surface for
the user before continuing:

1. A migrated package's drvPath differs from pre-migration —
   verbatim port wasn't truly verbatim. Investigate root cause.
2. `cache-hit-parity` check goes red — `ourPkgs` pattern broke.
3. A package has non-trivial facets (docs, fragments, lib
   helpers) in its existing `packages/<name>/` barrel that don't
   have a clear destination in the new slice shape.
4. `overlays/lib.nix` (the `vu` helpers) needs modification to
   support the new layout — that's a wider refactor than this
   plan covers.
5. The slice walker discovers a package directory that has
   neither `package.nix` nor `overlay.nix` (malformed during
   migration).
6. Inter-package dependencies surface (like the existing
   `agnix-mcp = override(flatDrvs.agnix)` pattern) for an MCP
   we're migrating — needs explicit handling.
