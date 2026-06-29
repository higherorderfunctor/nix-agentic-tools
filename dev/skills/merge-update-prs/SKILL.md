---
name: merge-update-prs
description: >-
  Use when asked to merge the bot's open dependency-update PRs (the
  `update/*` PRs from nix-agentic-tools-bot). A deterministic devenv
  task does the work — squash-merging only PRs whose CI is fully green.
  Do NOT inspect CI and merge by hand; that is a token burn and the
  whole reason this task exists.
---

# Merge passing dependency-update PRs

The procedure is deterministic and lives in a script — your job is to
run it, not to reconstruct it.

## Run it

```bash
devenv tasks run pr:merge-updates          # merge eligible PRs
MERGE_DRY_RUN=1 devenv tasks run pr:merge-updates   # preview only
```

Equivalent without devenv:

```bash
bash dev/scripts/merge-update-prs.sh [--dry-run] [--base <branch>]
```

Requires an authenticated `gh` (and `jq`). Runs with or without an AI
agent driving it.

## What it does

- Finds open PRs authored by the update bot with head `update/*` into
  the current branch.
- Merges only those whose **every** CI check is green (build linux,
  build darwin, test, gitleaks). It enforces this itself — the feature
  branch is unprotected, so GitHub would otherwise allow a red merge.
- Squash-merges + deletes the branch (matches the repo's UI button;
  squash is the only enabled method).
- Single pass, no polling. Prints a `merged / skipped / blocked`
  summary.

## Expect to re-run

Every update PR edits `flake.lock`, so after the first PR squash-merges
the rest usually report `BLOCKED [conflict]` until the **Update**
workflow (`on: push`) rebases them. That is the intended sequential
behavior — just run the task again once the rebased PRs go green.

## Do not

- Do not hand-check `gh pr checks` and `gh pr merge` PR-by-PR.
- Do not reimplement the eligibility logic in chat.
- Do not change the merge method — squash is intentional and the only
  one enabled.
