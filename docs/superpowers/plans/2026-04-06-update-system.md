# Update System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded `scripts/update` with Nix-generated
devenv tasks that auto-discover packages, hash types, and source
strategies from `hashes.json` and `generated.json`.

**Architecture:** `dev/update.nix` reads `packages/*/hashes.json` and
`.nvfetcher/generated.json` at Nix eval time, injects discovered
metadata into bash `exec` strings via `${}`. Six DAG-ordered devenv
tasks provide granular control. CI runs the full pipeline via the
devenv GitHub Action.

**Tech Stack:** Nix (devenv tasks, `builtins.fromJSON`,
`builtins.readDir`), Bash (generated exec strings), GitHub Actions

**Spec:**
`docs/superpowers/specs/2026-04-06-update-system-design.md`

---

## File Structure

| File                           | Action | Responsibility                                  |
| ------------------------------ | ------ | ----------------------------------------------- |
| `dev/update.nix`               | Create | Core module: discovery logic + task definitions |
| `devenv.nix`                   | Modify | Import `dev/update.nix`, wire tasks             |
| `.github/workflows/update.yml` | Create | CI: daily update + PR creation                  |
| `scripts/update`               | Delete | Replaced by devenv tasks                        |

---

### Task 1: Create discovery module

**Files:**

- Create: `dev/update.nix`

This task builds the Nix discovery logic that reads `hashes.json` and
`generated.json` to produce structured metadata. No tasks yet — just
the data layer.

- [ ] **Step 1: Create `dev/update.nix` with discovery functions**

```nix
# dev/update.nix — Update task definitions with auto-discovery.
#
# Reads packages/*/hashes.json and .nvfetcher/generated.json at eval
# time. Produces devenv task attrsets with Nix-interpolated exec strings.
# No hardcoded package lists — adding a package to hashes.json is
# sufficient for the update pipeline to discover it.
{
  lib,
  pkgs,
  ...
}: let
  packagesDir = ./../packages;
  nvfetcherDir = ./../.nvfetcher;

  # ── Discovery: overlay groups with hashes ──────────────────────────
  dirs = lib.filterAttrs (_: t: t == "directory") (builtins.readDir packagesDir);

  hashGroups = lib.filterAttrs (_: v: v != null) (lib.mapAttrs (name: _: let
      path = packagesDir + "/${name}/hashes.json";
    in
      if builtins.pathExists path
      then builtins.fromJSON (builtins.readFile path)
      else null)
    dirs);

  # ── Discovery: source metadata from generated.json ────────────────
  generatedJson =
    if builtins.pathExists (nvfetcherDir + "/generated.json")
    then builtins.fromJSON (builtins.readFile (nvfetcherDir + "/generated.json"))
    else {};

  # ── Discovery: lock file directories ───────────────────────────────
  groupsWithLocks = lib.filterAttrs (name: _:
    builtins.pathExists (packagesDir + "/${name}/locks"))
  dirs;

  # ── Derived: packages by hash type ────────────────────────────────
  # Each entry: { group, hashFile, name, ... }
  collectByField = field:
    lib.concatMapAttrs (group: pkgs:
      lib.mapAttrs' (name: _:
        lib.nameValuePair name {
          inherit group name;
          hashFile = toString (packagesDir + "/${group}/hashes.json");
        }) (lib.filterAttrs (_: v: v ? ${field}) pkgs))
    hashGroups;

  npmEntries = collectByField "npmDepsHash";
  srcHashEntries = collectByField "srcHash";
  cargoEntries = collectByField "cargoHash";
  vendorEntries = collectByField "vendorHash";

  # ── Derived: npm packages needing lock file refresh ────────────────
  # Cross-reference npmEntries with generated.json source types
  npmWithSource = lib.mapAttrs (name: entry: let
      src = generatedJson.${name}.src or {};
    in
      entry
      // {
        sourceType = src.type or "unknown";
        sourceUrl = src.url or "";
        sourceRev = src.rev or "";
        lockDir = toString (packagesDir + "/${entry.group}/locks");
      })
  npmEntries;

  # ── Derived: srcHash packages with URLs ────────────────────────────
  srcHashWithUrl = lib.mapAttrs (name: entry: let
      src = generatedJson.${name}.src or {};
    in
      entry // {sourceUrl = src.url or "";})
  srcHashEntries;

  # ── Derived: flake output names for build-hash packages ────────────
  # nvfetcher key usually matches flake output. Override via
  # "flakeOutput" field in hashes.json if they diverge.
  flakeOutput = group: name: let
    pkgAttrs = hashGroups.${group}.${name};
  in
    pkgAttrs.flakeOutput or name;

  # ── Shared bash preamble and helpers ───────────────────────────────
  bashPreamble = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';

  bashHelpers = ''
    log() { echo "==> $*" >&2; }

    inject_hash() {
      local file=$1 key=$2 field=$3 value=$4
      local tmp
      tmp=$(mktemp)
      jq --arg key "$key" --arg field "$field" --arg val "$value" \
        '.[$key][$field] = $val' "$file" >"$tmp" && mv "$tmp" "$file"
    }
  '';
in {
  inherit bashPreamble bashHelpers flakeOutput;
  inherit npmEntries npmWithSource srcHashEntries srcHashWithUrl;
  inherit cargoEntries vendorEntries groupsWithLocks;
}
```

Note on paths: `./../packages` is a relative path from `dev/update.nix`
to `packages/`. This evaluates to the absolute store path at eval time.
Similarly `./../.nvfetcher` reaches the root nvfetcher output.

- [ ] **Step 2: Verify discovery evaluates correctly**

Run:

```bash
nix eval --json --file dev/update.nix \
  --apply 'x: builtins.attrNames x._discovery.npmWithSource' \
  --arg lib 'import <nixpkgs/lib>' \
  --arg pkgs 'import <nixpkgs> {}'
```

This will fail because `dev/update.nix` uses relative paths that need
the flake context. Instead, verify via devenv after wiring in Task 2.
For now, check that the file parses:

```bash
nix-instantiate --parse dev/update.nix > /dev/null && echo "OK: parses"
```

Expected: `OK: parses`

- [ ] **Step 3: Commit**

```bash
git add dev/update.nix
git commit -m "feat(update): add discovery module for auto-discovered update tasks"
```

---

### Task 2: Wire discovery into devenv and add update:flake task

**Files:**

- Modify: `devenv.nix` (lines 334-341, the existing `tasks` block)
- Modify: `dev/update.nix` (add task definitions)

- [ ] **Step 1: Add the update:flake task definition to dev/update.nix**

Add at the bottom of `dev/update.nix`, inside the final returned
attrset (after the `vendorEntries` line), add:

```nix
  tasks = {
    "update:flake" = {
      description = "Update flake inputs";
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Updating flake inputs"
        nix flake update
      '';
      before = ["update"];
    };
  };
```

- [ ] **Step 2: Update devenv.nix to import and wire tasks**

Replace the existing `tasks` block in `devenv.nix` (lines 334-341):

```nix
  # ── Tasks ─────────────────────────────────────────────────────────
  tasks = let
    updateTasks = (import ./dev/update.nix {inherit lib pkgs;}).tasks;
  in
    updateTasks
    // {
      # Meta task: runs entire update pipeline
      "update" = {
        description = "Run full update pipeline";
      };
    };
```

- [ ] **Step 3: Verify devenv evaluates**

```bash
devenv tasks list 2>&1 | grep "update"
```

Expected: `update:flake` and `update` appear in the list.

- [ ] **Step 4: Test the task runs**

```bash
devenv tasks run update:flake 2>&1 | tail -5
```

Expected: `==> Updating flake inputs` followed by flake update output.
This will modify `flake.lock` — that is expected.

- [ ] **Step 5: Restore flake.lock and commit**

```bash
git checkout -- flake.lock
git add dev/update.nix devenv.nix
git commit -m "feat(update): add update:flake devenv task with discovery wiring"
```

---

### Task 3: Add update:nvfetcher task

**Files:**

- Modify: `dev/update.nix`

- [ ] **Step 1: Add the update:nvfetcher task to dev/update.nix**

Add to the `tasks` attrset in `dev/update.nix`:

```nix
    "update:nvfetcher" = {
      description = "Run nvfetcher to refresh source versions";
      after = ["update:flake"];
      before = ["update"];
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Running nvfetcher"
        nvfetcher -c nvfetcher.toml -o .nvfetcher

        log "Formatting generated files"
        treefmt .nvfetcher/generated.nix

        log "Staging nvfetcher output"
        git add .nvfetcher
      '';
    };
```

- [ ] **Step 2: Test the task runs**

```bash
devenv tasks run update:nvfetcher 2>&1 | tail -5
```

Expected: `==> Running nvfetcher` then `Up to date` (if nothing
changed upstream). The `.nvfetcher/` directory is staged.

- [ ] **Step 3: Unstage and commit**

```bash
git reset HEAD .nvfetcher 2>/dev/null || true
git add dev/update.nix
git commit -m "feat(update): add update:nvfetcher devenv task"
```

---

### Task 4: Add update:locks task

**Files:**

- Modify: `dev/update.nix`

The lock file refresh logic needs to know source types (tarball vs git)
and which npm packages have lock files. This is derived from the
discovery data.

- [ ] **Step 1: Add the update:locks task to dev/update.nix**

Add to the `tasks` attrset:

```nix
    "update:locks" = {
      description = "Regenerate npm lock files from upstream sources";
      after = ["update:nvfetcher"];
      before = ["update"];
      exec = let
        # Generate lock refresh commands for each npm package
        lockCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
            refreshCmd =
              if entry.sourceType == "git"
              then ''
                log "Refreshing lock for ${name} (git)"
                tmp=$(mktemp -d)
                git clone --depth 1 "${entry.sourceUrl}" "$tmp/repo" 2>/dev/null
                (cd "$tmp/repo" && npm install --package-lock-only --ignore-scripts --silent 2>/dev/null)
                cp "$tmp/repo/package-lock.json" "${entry.lockDir}/${name}-package-lock.json"
                rm -rf "$tmp"
              ''
              else ''
                log "Refreshing lock for ${name} (tarball)"
                tmp=$(mktemp -d)
                curl -sL "${entry.sourceUrl}" | tar xz -C "$tmp"
                (cd "$tmp/package" && npm install --package-lock-only --ignore-scripts --silent 2>/dev/null)
                cp "$tmp/package/package-lock.json" "${entry.lockDir}/${name}-package-lock.json"
                rm -rf "$tmp"
              '';
          in
            refreshCmd)
          npmWithSource);
      in ''
        ${bashPreamble}
        ${bashHelpers}
        ${lockCommands}
      '';
    };
```

- [ ] **Step 2: Test the task runs**

```bash
devenv tasks run update:locks 2>&1 | head -20
```

Expected: `==> Refreshing lock for claude-code (tarball)` and similar
lines for each npm package. Lock files in `packages/*/locks/` are
updated.

- [ ] **Step 3: Restore lock files and commit**

```bash
git checkout -- packages/*/locks/
git add dev/update.nix
git commit -m "feat(update): add update:locks devenv task"
```

---

### Task 5: Add update:hashes task

**Files:**

- Modify: `dev/update.nix`

This is the most complex task — it generates bash for four hash
strategies (npmDepsHash, srcHash, cargoHash, vendorHash) from
discovered package metadata.

- [ ] **Step 1: Add the update:hashes task to dev/update.nix**

Add to the `tasks` attrset:

```nix
    "update:hashes" = {
      description = "Compute all dependency hashes for discovered packages";
      after = ["update:locks"];
      before = ["update"];
      exec = let
        # ── npmDepsHash commands ──────────────────────────────────────
        npmCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
            log "Prefetching npmDepsHash for ${name}"
            hash=$(prefetch-npm-deps "${entry.lockDir}/${name}-package-lock.json" 2>/dev/null)
            inject_hash "${entry.hashFile}" "${name}" "npmDepsHash" "$hash"
          '')
          npmWithSource);

        # ── srcHash commands ─────────────────────────────────────────
        srcHashCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
            log "Prefetching srcHash for ${name}"
            base32=$(nix-prefetch-url --unpack --type sha256 "${entry.sourceUrl}" 2>/dev/null)
            hash=$(nix hash convert --hash-algo sha256 --to sri "$base32")
            inject_hash "${entry.hashFile}" "${name}" "srcHash" "$hash"
          '')
          srcHashWithUrl);

        # ── cargoHash commands ───────────────────────────────────────
        cargoCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
            output = flakeOutput entry.group name;
          in ''
            old_hash=$(jq -r '."${name}".cargoHash // empty' "${entry.hashFile}")
            if [[ -n "$old_hash" ]] && nix build ".#${output}" --no-link 2>/dev/null; then
              log "cargoHash for ${name} is current, skipping"
            else
              log "Prefetching cargoHash for ${name}"
              inject_hash "${entry.hashFile}" "${name}" "cargoHash" \
                "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              git add "${entry.hashFile}"

              hash=$(
                nix build ".#${output}" 2>&1 |
                  grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' |
                  head -1
              ) || true

              if [[ -n "$hash" ]]; then
                inject_hash "${entry.hashFile}" "${name}" "cargoHash" "$hash"
              else
                log "WARNING: could not determine cargoHash for ${name}"
                inject_hash "${entry.hashFile}" "${name}" "cargoHash" "$old_hash"
              fi
            fi
          '')
          cargoEntries);

        # ── vendorHash commands ──────────────────────────────────────
        vendorCommands = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: let
            output = flakeOutput entry.group name;
          in ''
            old_hash=$(jq -r '."${name}".vendorHash // empty' "${entry.hashFile}")
            if [[ -n "$old_hash" ]] && nix build ".#${output}" --no-link 2>/dev/null; then
              log "vendorHash for ${name} is current, skipping"
            else
              log "Prefetching vendorHash for ${name}"
              inject_hash "${entry.hashFile}" "${name}" "vendorHash" \
                "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
              git add "${entry.hashFile}"

              hash=$(
                nix build ".#${output}" 2>&1 |
                  grep -oP 'got:\s+\Ksha256-[A-Za-z0-9+/=]+' |
                  head -1
              ) || true

              if [[ -n "$hash" ]]; then
                inject_hash "${entry.hashFile}" "${name}" "vendorHash" "$hash"
              else
                log "WARNING: could not determine vendorHash for ${name}"
                inject_hash "${entry.hashFile}" "${name}" "vendorHash" "$old_hash"
              fi
            fi
          '')
          vendorEntries);
      in ''
        ${bashPreamble}
        ${bashHelpers}
        ${npmCommands}
        ${srcHashCommands}
        ${cargoCommands}
        ${vendorCommands}
      '';
    };
```

- [ ] **Step 2: Add flakeOutput override for github-mcp-server**

The nvfetcher key `github-mcp-server` maps to flake output `github-mcp`.
Add the override to `packages/mcp-servers/hashes.json`:

```json
  "github-mcp-server": {
    "flakeOutput": "github-mcp",
    "vendorHash": "sha256-q21hnMnWOzfg7BGDl4KM1I3v0wwS5sSxzLA++L6jO4s="
  }
```

- [ ] **Step 3: Test the task runs**

```bash
devenv tasks run update:hashes 2>&1 | head -30
```

Expected: Lines like `==> Prefetching npmDepsHash for claude-code`,
`==> Prefetching srcHash for claude-code`,
`==> cargoHash for agnix is current, skipping`, etc.

- [ ] **Step 4: Restore hashes and commit**

```bash
git checkout -- packages/*/hashes.json
git add dev/update.nix packages/mcp-servers/hashes.json
git commit -m "feat(update): add update:hashes devenv task with auto-discovery"
```

---

### Task 6: Add update:verify and update meta task

**Files:**

- Modify: `dev/update.nix`
- Modify: `devenv.nix`

- [ ] **Step 1: Add update:verify task to dev/update.nix**

Add to the `tasks` attrset:

```nix
    "update:verify" = {
      description = "Stage changes and verify all packages evaluate";
      after = ["update:hashes"];
      before = ["update"];
      exec = ''
        ${bashPreamble}
        ${bashHelpers}
        log "Staging changes"
        git add -A

        log "Verifying all packages evaluate"
        nix flake check --no-build 2>&1 | tail -3 || true

        log "Done — review changes with: git diff --cached"
      '';
    };
```

- [ ] **Step 2: Verify the meta task works**

The `update` meta task in `devenv.nix` has no `exec` — it exists so
other tasks can list it in their `before`. Running it triggers the
full DAG:

```bash
devenv tasks list 2>&1 | grep "update"
```

Expected: All six tasks appear: `update`, `update:flake`,
`update:nvfetcher`, `update:locks`, `update:hashes`, `update:verify`.

- [ ] **Step 3: Commit**

```bash
git add dev/update.nix
git commit -m "feat(update): add update:verify and meta update task"
```

---

### Task 7: End-to-end test

**Files:**

- None (testing only)

- [ ] **Step 1: Run full pipeline**

```bash
devenv tasks run update 2>&1
```

Expected: All tasks run in DAG order:

1. `update:flake` — `==> Updating flake inputs`
2. `update:nvfetcher` — `==> Running nvfetcher`
3. `update:locks` — `==> Refreshing lock for ...`
4. `update:hashes` — `==> Prefetching npmDepsHash for ...`
5. `update:verify` — `==> Verifying all packages evaluate`

- [ ] **Step 2: Run individual task**

```bash
devenv tasks run update:hashes 2>&1 | head -10
```

Expected: Only the hashes task runs (no flake update, no nvfetcher).

- [ ] **Step 3: Verify build**

```bash
nix build .#claude-code --no-link 2>&1
```

Expected: Build succeeds (hashes are correct after update).

- [ ] **Step 4: Restore all generated changes**

```bash
git checkout -- flake.lock packages/ .nvfetcher/
```

---

### Task 8: Add CI workflow

**Files:**

- Create: `.github/workflows/update.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
name: Update

on:
  push:
    paths:
      - .github/workflows/update.yml
      - dev/update.nix
  schedule:
    - cron: "0 6 * * *" # daily at 06:00 UTC
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

# TODO: remove once DeterminateSystems/nix-installer-action ships node24
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  update:
    runs-on: ubuntu-latest
    env:
      DRY_RUN: ${{ github.ref_name != github.event.repository.default_branch }}
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools # TODO: create Cachix cache
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

      - name: Install devenv
        run: nix profile install nixpkgs#devenv

      - name: Run update
        run: devenv tasks run update

      - name: Dry run summary
        if: env.DRY_RUN == 'true'
        run: |
          echo "::notice::Dry run on branch ${{ github.ref_name }} — skipping PR creation"
          git diff --stat || echo "No changes"

      - name: Create or update PR
        if: env.DRY_RUN == 'false'
        uses: peter-evans/create-pull-request@v8
        with:
          branch: auto/update
          commit-message: "chore: update flake inputs and upstream versions"
          title: "chore: update flake inputs and upstream versions"
          body: |
            Automated update via `devenv tasks run update`:
            - Flake inputs updated
            - nvfetcher sources refreshed
            - Lock files regenerated
            - Hashes prefetched

            Verified with `nix flake check` for all packages.
          labels: automated
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/update.yml
git commit -m "ci: add automated update workflow using devenv tasks"
```

---

### Task 9: Delete scripts/update

**Files:**

- Delete: `scripts/update`

- [ ] **Step 1: Delete the old script**

```bash
git rm scripts/update
```

- [ ] **Step 2: Check if scripts/ directory is now empty**

```bash
ls scripts/ 2>/dev/null || echo "scripts/ is empty or gone"
```

If empty, remove the directory. If other scripts exist, leave it.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(update): remove scripts/update, replaced by devenv tasks"
```

---

### Task 10: Final verification

**Files:**

- None (verification only)

- [ ] **Step 1: Verify flake check passes**

```bash
nix flake check --no-build 2>&1 | tail -5
```

Expected: `all checks passed!`

- [ ] **Step 2: Verify devenv test passes**

```bash
devenv test 2>&1 | tail -5
```

Expected: `All checks passed`

- [ ] **Step 3: Verify no references to scripts/update remain**

```bash
grep -r "scripts/update" . --include="*.nix" --include="*.md" --include="*.yml" \
  | grep -v ".git/" | grep -v "node_modules/" || echo "No stale references"
```

Expected: `No stale references` (or only this plan file, which is fine).
