# Pre-HITL Next Steps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete all remaining pre-nixos-config work: local cachix wiring, GitHub Pages deployment, CI nix-fast-build adoption, and binary cache consumer docs.

**Architecture:** Small independent tasks that can be executed in any order. Each produces a working commit. No inter-task dependencies except where noted.

**Tech Stack:** Nix flakes, devenv, GitHub Actions, Cachix, peaceiris/actions-gh-pages, nix-fast-build, mdbook

---

## A. Local Cachix Wiring

### Task 1: Add nixConfig to flake.nix

Wire the binary cache so `nix build` pulls pre-built packages locally.

**Files:**

- Modify: `flake.nix`

- [ ] **Step 1: Add nixConfig block**

Add at the top level of flake.nix (before `inputs`):

```nix
nixConfig = {
  extra-substituters = ["https://nix-agentic-tools.cachix.org"];
  extra-trusted-public-keys = ["nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0="];
};
```

- [ ] **Step 2: Verify**

```bash
nix show-config | grep nix-agentic-tools
```

Expected: the cachix URL appears in substituters.

- [ ] **Step 3: Format and commit**

```bash
treefmt flake.nix
git add flake.nix
git commit -m "feat(flake): add cachix binary cache to nixConfig

Local nix build now pulls pre-built packages from
nix-agentic-tools.cachix.org."
```

### Task 2: Add cachix.pull to devenv.nix

Wire cachix for devenv shell users.

**Files:**

- Modify: `devenv.nix`

- [ ] **Step 1: Add cachix.pull**

Add in the top-level config (after `imports` or alongside `treefmt`):

```nix
cachix.pull = ["nix-agentic-tools"];
```

- [ ] **Step 2: Format and commit**

```bash
treefmt devenv.nix
git add devenv.nix
git commit -m "feat(devenv): add cachix.pull for binary cache

devenv shell now pulls pre-built packages from Cachix."
```

---

## B. GitHub Pages Deployment

### Task 3: Fix base paths in docs derivation

The `docs` derivation currently hardcodes `<base href="/options/">` for
NuschtOS. For GitHub Pages, the repo is served at
`/nix-agentic-tools/`, so base paths need the repo prefix.

**Files:**

- Modify: `docs/book.toml`
- Modify: `flake.nix`

- [ ] **Step 1: Add site-url to book.toml**

Add under `[output.html]`:

```toml
site-url = "/nix-agentic-tools/"
```

- [ ] **Step 2: Fix NuschtOS base href in flake.nix**

In the `docs` derivation, change the `sed` command from:

```nix
sed -i 's|<base href="/">|<base href="/options/">|g' \
```

To:

```nix
sed -i 's|<base href="/">|<base href="/nix-agentic-tools/options/">|g' \
```

- [ ] **Step 3: Verify**

```bash
nix build .#docs --print-out-paths
grep 'base href' $(nix build .#docs --no-link --print-out-paths)/options/index.html
```

Expected: `<base href="/nix-agentic-tools/options/">`

- [ ] **Step 4: Format and commit**

```bash
treefmt docs/book.toml flake.nix
git add docs/book.toml flake.nix
git commit -m "fix(docs): set GitHub Pages base paths for site-url and NuschtOS"
```

### Task 4: Create docs.yml workflow

**Files:**

- Create: `.github/workflows/docs.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
name: Docs

on:
  push:
    branches: ["**"]
  delete:

concurrency:
  group: docs-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: write

env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  deploy-main:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            accept-flake-config = true
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools

      - name: Build docs
        run: |
          nix build .#docs
          cp -rL result docs-out
          chmod -R u+w docs-out

      - name: Deploy to root
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs-out
          exclude_assets: "pr/**"

  deploy-preview:
    if: github.event_name == 'push' && github.ref != 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: |
            accept-flake-config = true
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools

      - name: Build docs
        run: |
          nix build .#docs
          cp -rL result docs-out
          chmod -R u+w docs-out

      - name: Fix base paths for preview
        env:
          BRANCH: ${{ github.ref_name }}
        run: |
          BASE="/nix-agentic-tools/pr/${BRANCH}"
          # Fix NuschtOS options browser base href
          sed -i "s|/nix-agentic-tools/options/|${BASE}/options/|g" \
            docs-out/options/index.html \
            docs-out/options/index.csr.html
          # Fix mdbook site-url in generated HTML (404 page, asset paths)
          find docs-out -name '*.html' -exec \
            sed -i "s|/nix-agentic-tools/|${BASE}/|g" {} +

      - name: Deploy preview
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs-out
          destination_dir: pr/${{ github.ref_name }}
          keep_files: false

  cleanup:
    if: github.event_name == 'delete' && github.event.ref_type == 'branch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          ref: gh-pages
          fetch-depth: 1

      - name: Remove preview
        env:
          BRANCH: ${{ github.event.ref }}
        run: |
          PREVIEW_DIR="pr/${BRANCH}"
          if [ -d "$PREVIEW_DIR" ]; then
            git config user.name "github-actions[bot]"
            git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
            git rm -rf "$PREVIEW_DIR"
            git commit -m "chore: remove preview for deleted branch ${BRANCH}"
            git push
          else
            echo "No preview directory found for ${BRANCH}, skipping"
          fi
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/docs.yml
git commit -m "ci: add GitHub Pages deployment with per-branch previews

Deploy main to root, branches to pr/<name>/. Cleanup on branch
delete. Uses peaceiris/actions-gh-pages with nix build."
```

### Task 5: Enable GitHub Pages (manual)

- [ ] **Step 1: Push all commits**

```bash
git push
```

- [ ] **Step 2: Enable Pages in repo settings**

Go to https://github.com/higherorderfunctor/nix-agentic-tools/settings/pages

- Source: "Deploy from a branch"
- Branch: `gh-pages` / `/ (root)`
- Save

The `gh-pages` branch is created by the first successful deploy.

- [ ] **Step 3: Verify deployment**

Preview URL: `https://higherorderfunctor.github.io/nix-agentic-tools/pr/sentinel-monorepo-plan/`

Check:

- Doc pages render with correct styling
- NuschtOS options browser loads at `/pr/sentinel-monorepo-plan/options/`
- Pagefind search works
- Internal links resolve

---

## C. CI nix-fast-build

### Task 6: Add nix-fast-build to CI build step

Replace sequential `xargs nix build` with parallel
`nix-fast-build`. 2.8x speedup measured locally (34s → 12s).
Native cachix push via `--cachix-cache`.

**Files:**

- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Replace build step**

In the `build` job, replace:

```yaml
- name: Build all packages
  run: |
    nix flake show --json \
      | jq -r '.packages."${{ matrix.system }}" // {} | keys[]' \
      | xargs -I{} nix build .#{} --no-link
```

With:

```yaml
- name: Build all packages
  run: |
    nix-fast-build \
      --flake ".#packages" \
      --systems "${{ matrix.system }}" \
      --skip-cached \
      --cachix-cache nix-agentic-tools \
      --no-nom \
      --no-link
```

Note: keep `nix flake check --no-build` above it for flake schema
validation.

- [ ] **Step 2: Add nix-fast-build to nix profile**

nix-fast-build may not be available by default. Add an install step
before the build:

```yaml
- name: Install nix-fast-build
  run: nix profile install github:Mic92/nix-fast-build
```

Or check if it's available via nixpkgs:

```bash
nix eval nixpkgs#nix-fast-build.name 2>/dev/null
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: replace sequential builds with nix-fast-build

Parallel evaluation + pipelined builds. Native cachix push via
--cachix-cache. --skip-cached avoids downloading cached paths."
```

### Task 7: Add build:all devenv task (optional)

Local convenience task for building all packages.

**Files:**

- Modify: `dev/tasks/generate.nix` (or a new `dev/tasks/build.nix`)

- [ ] **Step 1: Add task**

```nix
"build:all" = {
  description = "Build all packages with nix-fast-build";
  exec = ''
    ${bashPreamble}
    ${log}
    log "Building all packages"
    nix-fast-build --flake ".#packages" --skip-cached --no-link
    log "All packages built"
  '';
};
```

- [ ] **Step 2: Commit**

```bash
git add dev/tasks/generate.nix
git commit -m "feat(devenv): add build:all task using nix-fast-build"
```

---

## D. Cross-Platform Binary Packages

### Task 8: Fix copilot-cli for all platforms

copilot-cli hardcodes `copilot-linux-x64.tar.gz`. GitHub releases
provide tarballs for all 4 platforms. Use a platform map to select
the correct URL at build time.

**Files:**

- Modify: `packages/ai-clis/copilot-cli.nix`
- Modify: `nvfetcher.toml` (nvfetcher only tracks version, not platform-specific URL)
- Modify: `packages/ai-clis/hashes.json` (per-platform hashes)

- [ ] **Step 1: Update copilot-cli.nix with platform map**

nvfetcher tracks the version only. The .nix file constructs the
platform-specific URL using `final.stdenv.hostPlatform.system`:

```nix
# GitHub Copilot CLI — pre-built binary from GitHub releases.
{
  final,
  prev,
  nv,
}: let
  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-linux" = "linux-arm64";
    "x86_64-darwin" = "darwin-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  system = final.stdenv.hostPlatform.system;
  platformSuffix = platformMap.${system}
    or (throw "copilot-cli: unsupported system ${system}");

  src = final.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-${platformSuffix}.tar.gz";
    hash = nv.hashes.${system} or (throw "copilot-cli: no hash for ${system}");
  };
in
  prev.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
```

Note: `nv.hashes` is a per-platform hash map. The `sources.nix`
needs to pass through the hashes from `hashes.json` for copilot-cli.

- [ ] **Step 2: Update hashes.json with per-platform hashes**

Add per-platform hash structure for copilot-cli:

```json
{
  "claude-code": { ... },
  "github-copilot-cli": {
    "x86_64-linux": { "hash": "sha256-..." },
    "aarch64-linux": { "hash": "sha256-..." },
    "x86_64-darwin": { "hash": "sha256-..." },
    "aarch64-darwin": { "hash": "sha256-..." }
  }
}
```

Compute hashes for each platform:

```bash
for suffix in linux-x64 linux-arm64 darwin-x64 darwin-arm64; do
  url="https://github.com/github/copilot-cli/releases/download/v${VERSION}/copilot-${suffix}.tar.gz"
  echo "$suffix: $(nix-prefetch-url "$url" 2>/dev/null | xargs nix hash convert --to sri --hash-algo sha256)"
done
```

- [ ] **Step 3: Update sources.nix**

Ensure copilot-cli entry passes the hashes through. Currently:

```nix
copilot-cli = generated."github-copilot-cli";
```

Change to include hashes:

```nix
copilot-cli = merge "github-copilot-cli" generated."github-copilot-cli";
```

- [ ] **Step 4: Update nvfetcher.toml**

nvfetcher only needs to track the version (it already does). The
URL in nvfetcher.toml is only used for version checking — the actual
fetch URL is constructed in the .nix file. However, nvfetcher
currently fetches the tarball too. Change it to version-only:

Check if nvfetcher can track version without fetching the tarball.
If not, keep the x86_64-linux URL for version tracking (it still
works for determining the latest version).

- [ ] **Step 5: Update the update script/tasks**

The `update:hashes` devenv task needs to compute per-platform hashes
for copilot-cli. Update `dev/update.nix` to handle the new hash
structure.

- [ ] **Step 6: Verify**

```bash
nix build .#github-copilot-cli  # on current system
nix flake check --no-build       # all systems evaluate
```

- [ ] **Step 7: Commit**

```bash
git add packages/ai-clis/ nvfetcher.toml
git commit -m "fix(copilot-cli): support all 4 platforms

Platform-specific binary URL selection via hostPlatform.system.
Per-platform hashes in hashes.json. Fixes CI on aarch64-darwin."
```

### Task 9: Fix kiro-cli platform support

kiro-cli hardcodes `kirocli-x86_64-linux.tar.gz`. AWS provides
Linux tarballs for x86_64 and aarch64. No headless CLI for Darwin
(only .dmg). Restrict to Linux platforms.

**Files:**

- Modify: `packages/ai-clis/kiro-cli.nix`
- Modify: `packages/ai-clis/hashes.json` (per-platform hashes if needed)

- [ ] **Step 1: Update kiro-cli.nix with platform map + meta.platforms**

```nix
# Kiro CLI — pre-built binary from AWS release channel.
{
  final,
  prev,
  nv,
}: let
  platformMap = {
    "x86_64-linux" = "x86_64-linux";
    "aarch64-linux" = "aarch64-linux";
  };
  system = final.stdenv.hostPlatform.system;
  platformSuffix = platformMap.${system}
    or (throw "kiro-cli: unsupported system ${system} (Linux-only)");

  src = final.fetchurl {
    url = "https://desktop-release.q.us-east-1.amazonaws.com/${nv.version}/kirocli-${platformSuffix}.tar.gz";
    hash = nv.hashes.${system} or nv.src.outputHash;
  };
in
  prev.kiro-cli.overrideAttrs (attrs: {
    inherit src;
    inherit (nv) version;

    nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [final.makeWrapper];

    postFixup =
      (attrs.postFixup or "")
      + ''
        wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
        wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
      '';

    meta =
      prev.kiro-cli.meta
      // {
        changelog = builtins.replaceStrings [prev.kiro-cli.version] [nv.version] prev.kiro-cli.meta.changelog;
        platforms = ["x86_64-linux" "aarch64-linux"];
      };
  })
```

- [ ] **Step 2: Handle meta.platforms in flake package export**

The flake `packages` output is per-system. If `kiro-cli` sets
`meta.platforms` to Linux-only, the aarch64-darwin and x86_64-darwin
package sets should exclude it. Check how this interacts with
`nix flake show` and `nix-fast-build`.

If nixpkgs `overrideAttrs` respects `meta.platforms` in the overlay
context, packages excluded by platform simply fail to build on
unsupported systems — which is correct. The CI matrix builds per-system
so this should work.

- [ ] **Step 3: Verify**

```bash
nix build .#kiro-cli             # on Linux
nix flake check --no-build       # all systems evaluate
```

- [ ] **Step 4: Commit**

```bash
git add packages/ai-clis/
git commit -m "fix(kiro-cli): add aarch64-linux support, restrict to Linux

Platform-specific binary URL via hostPlatform.system. Darwin excluded
(no headless CLI tarball available). Fixes CI platform compatibility."
```

---

## E. Documentation Updates

### Task 10: Mark completed items in plan.md

**Files:**

- Modify: `docs/plan.md`

- [ ] **Step 1: Mark done**

- [x] GitHub Pages deploy workflow
- [x] Document binary cache for consumers
- [x] Local cachix wiring (nixConfig + cachix.pull)
- [x] Cross-platform binary packages (copilot-cli, kiro-cli)
- [x] nix-fast-build CI adoption

- [ ] **Step 2: Commit**

```bash
git add docs/plan.md
git commit -m "docs(plan): mark pre-HITL items done"
```
