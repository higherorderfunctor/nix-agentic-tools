# Cachix Binary Cache Setup Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up a Cachix binary cache for nix-agentic-tools so
packages are built once, cached, and consumers (nixos-config, CI,
developers) never rebuild from source.

**Architecture:** A single `nix-agentic-tools` Cachix cache receives
pushes from CI after successful builds. Two workflows use it:
`ci.yml` (build matrix + push) and the existing `update.yml` (pull
only). Consumers add the cache as a substituter.

**Tech Stack:** Cachix, GitHub Actions, Nix

---

## File Structure

| File                           | Action | Responsibility             |
| ------------------------------ | ------ | -------------------------- |
| `.github/workflows/ci.yml`     | Create | Build matrix + cachix push |
| `.github/workflows/update.yml` | Modify | Fix cache name             |
| `docs/plan.md`                 | Modify | Mark completed items       |

---

### Task 1: Create Cachix cache (human-in-the-loop)

This task requires manual steps in the Cachix web dashboard.

- [ ] **Step 1: Create the cache**

Go to https://app.cachix.org/cache and create a new binary cache:

- **Name:** `nix-agentic-tools`
- **Type:** Public (consumers can pull without auth)
- **Visibility:** Public

- [ ] **Step 2: Generate a cache-scoped auth token**

Go to the cache's Settings page → Auth Tokens → Generate new token:

- **Scope:** Push access to `nix-agentic-tools` only
- Copy the token value

- [ ] **Step 3: Set the GitHub secret**

```bash
gh secret set CACHIX_AUTH_TOKEN \
  --repo <owner>/nix-agentic-tools \
  --body "<paste-token-here>"
```

- [ ] **Step 4: Verify the secret is set**

```bash
gh secret list --repo <owner>/nix-agentic-tools | grep CACHIX
```

Expected: `CACHIX_AUTH_TOKEN` appears in the list.

---

### Task 2: Fix cache name in update.yml

**Files:**

- Modify: `.github/workflows/update.yml`

The current workflow has `name: nix-agentic-tools # TODO: create
Cachix cache`. Remove the TODO comment now that the cache exists.

- [ ] **Step 1: Update the cache name**

In `.github/workflows/update.yml`, change:

```yaml
name: nix-agentic-tools # TODO: create Cachix cache
```

to:

```yaml
name: nix-agentic-tools
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/update.yml
git commit -m "chore(ci): remove cachix TODO, cache now exists

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Create CI build workflow

**Files:**

- Create: `.github/workflows/ci.yml`

This workflow builds all packages on push/PR, pushes to Cachix on
main, and runs `devenv test`. Uses a 4-arch matrix per the research
in `project_cachix_setup.md`.

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

# TODO: remove once DeterminateSystems/nix-installer-action ships node24
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - system: x86_64-linux
            runner: ubuntu-latest
          - system: aarch64-linux
            runner: ubuntu-24.04-arm
          - system: x86_64-darwin
            runner: macos-13
          - system: aarch64-darwin
            runner: macos-latest
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
          # cachix-action pushes built paths automatically when
          # authToken is set and the push target matches

      - name: Check flake evaluation
        run: nix flake check --no-build

      - name: Build all packages
        run: |
          nix flake show --json \
            | jq -r '.packages."${{ matrix.system }}" // {} | keys[]' \
            | xargs -I{} nix build .#{} --no-link

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v17
        with:
          name: nix-agentic-tools

      - name: Install devenv
        run: nix profile install nixpkgs#devenv

      - name: Run devenv test
        run: devenv test
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add build matrix with cachix push for 4 architectures

Builds all packages on push/PR across x86_64-linux, aarch64-linux,
x86_64-darwin, aarch64-darwin. Pushes to nix-agentic-tools cache
on main. Runs devenv test separately.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Verify end-to-end (human-in-the-loop)

After Tasks 1-3 are committed and pushed:

- [ ] **Step 1: Push branch and create PR**

```bash
git push
gh pr create --title "ci: add cachix binary cache and CI workflow" \
  --body "Adds nix-agentic-tools Cachix cache, 4-arch build matrix, devenv test."
```

- [ ] **Step 2: Verify CI runs**

Check the PR's GitHub Actions tab:

- `ci.yml` should trigger on the PR
- All 4 matrix jobs should start
- x86_64-linux and aarch64-linux should succeed
- Darwin jobs may fail if the repo has Linux-only packages — that is
  expected and can be fixed later with `lib.optionalAttrs`

- [ ] **Step 3: Verify cache population**

After merging to main (or on a push to main):

```bash
cachix use nix-agentic-tools
nix build .#claude-code --no-link 2>&1 | grep "copying path"
```

If it says "copying path from
https://nix-agentic-tools.cachix.org", the cache is working.

---

### Task 5: Document cache for consumers

**Files:**

- Varies — the docs system is being rewritten (see
  `docs/superpowers/specs/2026-04-06-generated-docs-design.md`).
  At execution time, find the right location by searching for where
  consumer setup instructions live.

Consumers need three pieces of information to use the cache:

1. **Cache URL:** `https://nix-agentic-tools.cachix.org`
2. **Public key:** Obtain from `cachix use nix-agentic-tools --mode
nixos 2>&1` or from the cache's Settings page on app.cachix.org
3. **Configuration snippet** for each method:

Nix flake (`nixConfig`):

```nix
nixConfig = {
  extra-substituters = ["https://nix-agentic-tools.cachix.org"];
  extra-trusted-public-keys = ["nix-agentic-tools.cachix.org-1:<pubkey>"];
};
```

NixOS / home-manager:

```nix
nix.settings = {
  substituters = ["https://nix-agentic-tools.cachix.org"];
  trusted-public-keys = ["nix-agentic-tools.cachix.org-1:<pubkey>"];
};
```

- [ ] **Step 1: Find where consumer docs live**

The docs system may have been rewritten by the time this runs.
Search for the current getting-started or installation docs:

```bash
# Check if new docs system is in place
ls dev/docs/getting-started/ 2>/dev/null
# Fall back to old docs
ls docs/src/getting-started/ 2>/dev/null
# Or check README
grep -n "substituter\|binary cache\|Getting Started" README.md
```

- [ ] **Step 2: Get the public key**

```bash
cachix use nix-agentic-tools --mode nixos 2>&1 | grep "public-keys"
```

- [ ] **Step 3: Add cache instructions to consumer docs**

Add a "Binary Cache" section with the URL, public key, and
configuration snippets for flake nixConfig, NixOS, and
home-manager. Place it in the getting-started or installation page.

- [ ] **Step 4: Commit**

```bash
git add <docs-files>
git commit -m "docs: add cachix binary cache setup instructions

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update plan.md

**Files:**

- Modify: `docs/plan.md`

- [ ] **Step 1: Mark completed items**

Mark these items as done in `docs/plan.md`:

- `ci.yml` — devenv test + package build matrix + cachix push
- `update.yml` — daily nvfetcher update pipeline
- Binary cache: cachix setup

- [ ] **Step 2: Commit**

```bash
git add docs/plan.md
git commit -m "docs: mark ci.yml, update.yml, and cachix setup as done

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
