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

## D. Fix CI Platform Failures

Target platforms: **x86_64-linux** and **aarch64-darwin** only.
The flake declares 4 `supportedSystems` but CI only runs these 2.
Narrow `supportedSystems` to match CI reality, then fix packages
that hardcode x86_64-linux binary URLs.

### Task 8: Narrow supportedSystems to 2 platforms

**Files:**

- Modify: `flake.nix`

- [ ] **Step 1: Update supportedSystems**

Change:

```nix
supportedSystems = [
  "aarch64-darwin"
  "aarch64-linux"
  "x86_64-darwin"
  "x86_64-linux"
];
```

To:

```nix
supportedSystems = [
  "aarch64-darwin"
  "x86_64-linux"
];
```

- [ ] **Step 2: Verify**

```bash
nix flake check --no-build
nix flake show --json | jq '.packages | keys'
```

Expected: only `aarch64-darwin` and `x86_64-linux`.

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "fix(flake): narrow supportedSystems to x86_64-linux + aarch64-darwin

Matches CI matrix. Removes unsupported aarch64-linux and x86_64-darwin
which had no CI coverage and caused evaluation failures."
```

### Task 9: Fix copilot-cli for aarch64-darwin

copilot-cli hardcodes `copilot-linux-x64.tar.gz`. GitHub releases
provide `copilot-darwin-arm64.tar.gz` for aarch64-darwin. Only need
2 platform variants.

**Files:**

- Modify: `packages/ai-clis/copilot-cli.nix`
- Modify: `packages/ai-clis/sources.nix`
- Modify: `packages/ai-clis/hashes.json`

- [ ] **Step 1: Update copilot-cli.nix with platform map**

```nix
{
  final,
  prev,
  nv,
}: let
  platformMap = {
    "x86_64-linux" = "linux-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  system = final.stdenv.hostPlatform.system;
  platformSuffix = platformMap.${system}
    or (throw "copilot-cli: unsupported system ${system}");

  src = final.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-${platformSuffix}.tar.gz";
    hash = (nv.platformHashes or {}).${system}
      or (throw "copilot-cli: no hash for ${system}");
  };
in
  prev.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
```

- [ ] **Step 2: Update hashes.json with per-platform hashes**

```json
{
  "claude-code": { ... },
  "github-copilot-cli": {
    "x86_64-linux": "sha256-...",
    "aarch64-darwin": "sha256-..."
  }
}
```

Compute:

```bash
VERSION=$(jq -r '."github-copilot-cli".version' .nvfetcher/generated.json)
for suffix in linux-x64 darwin-arm64; do
  url="https://github.com/github/copilot-cli/releases/download/v${VERSION}/copilot-${suffix}.tar.gz"
  nix-prefetch-url "$url" 2>/dev/null | xargs nix hash convert --to sri --hash-algo sha256
done
```

- [ ] **Step 3: Update sources.nix**

Change `copilot-cli` entry to merge hashes:

```nix
copilot-cli = merge "github-copilot-cli" generated."github-copilot-cli";
```

The `merge` function already exists and adds hashes.json data to
the nvfetcher entry. The copilot-cli.nix will access per-platform
hashes via `nv.platformHashes` (or however the hash structure
maps — adapt to match what `merge` produces).

- [ ] **Step 4: Verify**

```bash
nix build .#github-copilot-cli   # on x86_64-linux
nix flake check --no-build        # both systems evaluate
```

- [ ] **Step 5: Commit**

```bash
git add packages/ai-clis/
git commit -m "fix(copilot-cli): add aarch64-darwin support

Platform-specific binary URL via hostPlatform.system. Per-platform
hashes in hashes.json. Fixes CI on aarch64-darwin."
```

### Task 10: Fix kiro-cli for aarch64-darwin

kiro-cli hardcodes the Linux tarball. On Darwin, AWS provides a
universal `.dmg` (`Kiro CLI.dmg`). Add a second nvfetcher entry
for the Darwin source and use platform-aware src in the overlay.

**Files:**

- Modify: `nvfetcher.toml` (add `kiro-cli-darwin` entry)
- Modify: `packages/ai-clis/kiro-cli.nix` (platform-aware src)
- Modify: `packages/ai-clis/sources.nix` (expose Darwin source)
- Modify: `packages/ai-clis/hashes.json` (Darwin hash)

- [ ] **Step 1: Add nvfetcher entry for Darwin .dmg**

In `nvfetcher.toml`, add alongside the existing `kiro-cli`:

```toml
[kiro-cli-darwin]
src.cmd = "curl -s https://desktop-release.q.us-east-1.amazonaws.com/latest/manifest.json | jq -r '.version'"
fetch.url = "https://desktop-release.q.us-east-1.amazonaws.com/$ver/Kiro%20CLI.dmg"
```

Both entries track the same version (same manifest endpoint).
nvfetcher produces separate source entries for each.

Run `nvfetcher` to generate the Darwin source entry.

- [ ] **Step 2: Update sources.nix**

Expose the Darwin source alongside the Linux one:

```nix
kiro-cli = generated."kiro-cli";
kiro-cli-darwin = generated."kiro-cli-darwin";
```

- [ ] **Step 3: Update kiro-cli.nix with platform-aware src**

```nix
{
  final,
  prev,
  nv,
  nv-darwin ? null,
}: let
  system = final.stdenv.hostPlatform.system;
  src =
    if system == "x86_64-linux"
    then nv.src
    else if system == "aarch64-darwin" && nv-darwin != null
    then nv-darwin.src
    else throw "kiro-cli: unsupported system ${system}";
  version = nv.version;
in
  prev.kiro-cli.overrideAttrs (attrs: {
    inherit src version;
    nativeBuildInputs = (attrs.nativeBuildInputs or [])
      ++ [final.makeWrapper]
      ++ final.lib.optionals final.stdenv.isDarwin [final.undmg];
    postFixup = (attrs.postFixup or "") + ''
      wrapProgram $out/bin/kiro-cli --set TERM xterm-256color
      wrapProgram $out/bin/kiro-cli-chat --set TERM xterm-256color
    '';
    meta = prev.kiro-cli.meta // {
      changelog = builtins.replaceStrings
        [prev.kiro-cli.version] [version]
        prev.kiro-cli.meta.changelog;
    };
  })
```

The `nv-darwin` parameter is the Darwin nvfetcher source. Wire it
in from `default.nix` via `callPkg` or pass explicitly.

- [ ] **Step 4: Update default.nix to pass Darwin source**

In `packages/ai-clis/default.nix`, pass the Darwin source to the
kiro-cli builder. Check how `callPkg` pattern works in this overlay
and adapt accordingly.

- [ ] **Step 5: Add Darwin hash to hashes.json if needed**

If the .dmg needs a hash not tracked by nvfetcher's generated.nix,
add it to hashes.json.

- [ ] **Step 6: Verify**

```bash
nix build .#kiro-cli              # on x86_64-linux
nix eval '.#packages.aarch64-darwin.kiro-cli.name' --accept-flake-config
nix flake check --no-build
```

- [ ] **Step 7: Commit**

```bash
git add packages/ai-clis/ nvfetcher.toml .nvfetcher/
git commit -m "fix(kiro-cli): add aarch64-darwin support via .dmg

New nvfetcher entry for Darwin .dmg. Platform-aware src selection
in overlay. Both platforms track same version from AWS manifest."
```

### Task 11: Document target platforms

Add platform support info to dev fragment and consumer docs.

**Files:**

- Create: `dev/fragments/monorepo/platforms.md`
- Modify: `dev/docs/getting-started/choose-your-path.md`
- Modify: `dev/generate.nix` (add to fragment list)

- [ ] **Step 1: Create platform + packaging pattern fragment**

```markdown
## Target Platforms

| System         | CI  | Packages | Notes                |
| -------------- | --- | -------- | -------------------- |
| x86_64-linux   | Yes | All      | Primary dev platform |
| aarch64-darwin | Yes | All      | macOS Apple Silicon  |

### Nightly Packaging Pattern

All binary packages are tracked via nvfetcher for nightly/latest
versions. Never defer to nixpkgs upstream — always override `src`
and `version` from nvfetcher.

When a package provides different artifacts per platform (e.g.,
`.tar.gz` on Linux, `.dmg` on Darwin):

1. Add separate nvfetcher entries per platform (e.g., `kiro-cli` +
   `kiro-cli-darwin`) tracking the same version but different URLs
2. Select the correct source in the `.nix` overlay via
   `final.stdenv.hostPlatform.system`
3. Store per-platform hashes in `hashes.json` keyed by system

Examples:

- `kiro-cli`: Linux tarball + Darwin `.dmg` (via `undmg`)
- `copilot-cli`: per-platform tarballs from GitHub releases
```

- [ ] **Step 2: Add to dev/generate.nix fragment list**

Add `"platforms"` to monorepo fragments (alphabetically).

- [ ] **Step 3: Add to consumer docs**

In `dev/docs/getting-started/choose-your-path.md`, note supported
platforms near the top.

- [ ] **Step 4: Commit**

```bash
git add dev/fragments/ dev/docs/ dev/generate.nix
git commit -m "docs: document target platforms (x86_64-linux + aarch64-darwin)"
```

---

## E. Quick Wins from Backlog

### Task 12: Fix docs favicon

**Files:**

- Modify: `docs/book.toml`

- [ ] **Step 1: Add favicon to book.toml**

Add under `[output.html]`:

```toml
favicon = "assets/favicon.png"
```

The file already exists at `dev/docs/assets/favicon.png` and gets
copied to `docs/src/assets/favicon.png` by the prose generation.

- [ ] **Step 2: Verify**

```bash
nix build .#docs --print-out-paths
ls $(nix build .#docs --no-link --print-out-paths)/assets/favicon.png
```

- [ ] **Step 3: Commit**

```bash
git add docs/book.toml
git commit -m "fix(docs): add favicon to book.toml"
```

### Task 13: Add shell linters to git hooks

**Files:**

- Modify: `devenv.nix`

- [ ] **Step 1: Add shellcheck and shfmt hooks**

In `devenv.nix` under `git-hooks.hooks`, add (alphabetically):

```nix
shellcheck.enable = true;
shfmt.enable = true;
```

- [ ] **Step 2: Verify**

```bash
devenv test
```

- [ ] **Step 3: Commit**

```bash
git add devenv.nix
git commit -m "feat(devenv): add shellcheck and shfmt git hooks"
```

### Task 14: Fix stack-plan missing git restack

**Files:**

- Modify: `packages/stacked-workflows/skills/stack-plan/SKILL.md`

- [ ] **Step 1: Find the autosquash fixup pattern**

Search for `autosquash` in the skill file and add `git restack`
after the `git rebase -i --autosquash` command. Without restack,
descendants become abandoned.

- [ ] **Step 2: Commit**

```bash
git add packages/stacked-workflows/skills/stack-plan/SKILL.md
git commit -m "fix(stack-plan): add git restack after autosquash fixup

Descendants become abandoned without restack after
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash."
```

---

## F. Documentation Updates

### Task 15: Mark completed items in plan.md

**Files:**

- Modify: `docs/plan.md`

- [ ] **Step 1: Mark done**

- [x] GitHub Pages deploy workflow
- [x] Document binary cache for consumers
- [x] Local cachix wiring (nixConfig + cachix.pull)
- [x] Cross-platform binary packages (copilot-cli, kiro-cli)
- [x] nix-fast-build CI adoption
- [x] Docs favicon
- [x] Shell linters (shellcheck, shfmt)
- [x] stack-plan git restack fix
- [x] Target platform documentation

- [ ] **Step 2: Commit**

```bash
git add docs/plan.md
git commit -m "docs(plan): mark pre-HITL items done"
```
