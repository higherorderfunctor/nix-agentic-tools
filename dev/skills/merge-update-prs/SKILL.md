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
devenv tasks run pr:merge-updates                    # merge eligible PRs
MERGE_DRY_RUN=1 devenv tasks run pr:merge-updates    # preview only
```

Equivalent without devenv:

```bash
bash dev/scripts/merge-update-prs.sh [--dry-run] [--base <branch>]
```

Requires an authenticated `gh` (and `jq`). Runs with or without an AI
agent driving it. `--help` on the script prints the eligibility rules
and every env knob; each run prints a `merged / skipped / blocked`
summary.

The green-CI gate is enforced by the script itself, not by GitHub.
Required status checks gate the **base** branch, and these PRs target
whatever branch you run from — normally a long-lived `refactor/*`
branch, which carries no protection (only `main` does). Nothing on the
GitHub side would stop a red PR from merging there.

## Single pass by design

The script never polls or loops. Every update PR edits `flake.lock`, so
once the first one squash-merges, the rest usually report
`BLOCKED [conflict]` until the **Update** workflow (`on: push`) rebases
them. That is the intended sequential behavior — run the task again
after the rebased PRs go green.

## Do not

- Do not hand-check `gh pr checks` and `gh pr merge` PR-by-PR.
- Do not reimplement the eligibility logic in chat.
- Do not change the merge method — squash is intentional and the only
  one enabled.
