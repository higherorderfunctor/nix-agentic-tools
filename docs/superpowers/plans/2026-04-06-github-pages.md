# GitHub Pages Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the mdbook doc site to GitHub Pages with per-branch preview URLs and automatic cleanup on branch deletion.

**Architecture:** Single workflow file with three jobs: deploy-main (root), deploy-preview (pr/<branch>/), cleanup (on branch delete). Docs built via `nix build .#docs`. NuschtOS base href post-processed with `sed` for correct subpath. Pagefind auto-detects from relative paths.

**Tech Stack:** GitHub Actions, peaceiris/actions-gh-pages, cachix/install-nix-action, mdbook, Pagefind, NuschtOS/search

---

### Task 1: Fix base paths in docs derivation

The `docs` derivation currently hardcodes `<base href="/options/">` for NuschtOS. For GitHub Pages, the repo is served at `/nix-agentic-tools/`, so the base href must be `/nix-agentic-tools/options/`. Also add `site-url` to book.toml for correct 404 page and asset resolution.

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

- [ ] **Step 3: Verify build**

```bash
nix build .#docs --print-out-paths
grep 'site-url' docs/book.toml
grep 'base href' $(nix build .#docs --no-link --print-out-paths)/options/index.html
```

Expected: `site-url = "/nix-agentic-tools/"` and `<base href="/nix-agentic-tools/options/">`

- [ ] **Step 4: Format and commit**

```bash
treefmt docs/book.toml flake.nix
git add docs/book.toml flake.nix
git commit -m "fix(docs): set GitHub Pages base paths for site-url and NuschtOS"
```

---

### Task 2: Create docs.yml workflow

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

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/docs.yml'))" && echo "YAML valid"
```

If python3/yaml not available:

```bash
nix run nixpkgs#python3 -- -c "import yaml; yaml.safe_load(open('.github/workflows/docs.yml'))" && echo "YAML valid"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/docs.yml
git commit -m "ci: add GitHub Pages deployment with per-branch previews

Deploy main to root, branches to pr/<name>/. Cleanup on branch
delete. Uses peaceiris/actions-gh-pages with nix build."
```

---

### Task 3: Enable GitHub Pages in repo settings

This is a manual step — cannot be automated via workflow.

- [ ] **Step 1: Push the workflow**

```bash
git push
```

- [ ] **Step 2: Enable Pages**

Go to https://github.com/higherorderfunctor/nix-agentic-tools/settings/pages

- Source: "Deploy from a branch"
- Branch: `gh-pages` / `/ (root)`
- Save

Note: The `gh-pages` branch will be created by the first successful
deploy. If Pages settings aren't available yet, push first and wait
for the workflow to create the branch, then configure.

- [ ] **Step 3: Verify deployment**

After the workflow runs (check Actions tab), the preview should be at:
`https://higherorderfunctor.github.io/nix-agentic-tools/pr/sentinel-monorepo-plan/`

Check:

- Main doc pages render
- NuschtOS options browser loads at `/pr/sentinel-monorepo-plan/options/`
- Pagefind search works
- Internal links resolve correctly

---

### Task 4: Update plan and docs references

**Files:**

- Modify: `docs/plan.md`
- Modify: `dev/docs/index.md` (if it has a docs link)

- [ ] **Step 1: Mark GitHub Pages done in plan**

- [ ] **Step 2: Update any "preview locally" references to include the live URL**

- [ ] **Step 3: Commit**

```bash
git add docs/plan.md dev/docs/index.md
git commit -m "docs: add GitHub Pages URL references"
```
