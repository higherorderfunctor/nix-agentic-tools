# Fix: claude-code update PR fails `checks.formatting` (sidecar format drift)

**Date:** 2026-06-22 **Branch:** `refactor/ai-factory-architecture` **Trigger:**
PR #253 (`update/claude-code`, head `fa39eb7`) — `test` job fails on
`checks.x86_64-linux.formatting`. `build` (both platforms) and `gitleaks` pass.

## Root cause

The update pipeline's `extraExtract` hook (`overlays/claude-code.nix`)
regenerates `overlays/claude-code-extracted.json` by `cp`-ing the output of
`passthru.extracted`, produced by `jq -n '{...}'` in `mkClaudeExtract`
(`overlays/lib.nix`). jq pretty-prints **every** array multi-line. The repo's
JSON formatter (**biome**, via treefmt) collapses short arrays onto one line.
The `cp` is never followed by a formatter pass, so the committed sidecar drifts
from treefmt-clean and PR CI's `checks.formatting` fails:

```
-  "effortLevels": [ "low", "medium", "high", "xhigh" ]   (jq, multi-line)
+  "effortLevels": ["low", "medium", "high", "xhigh"]      (biome, single-line)
```

### Why it's new, not a regression of the prior fix

Commit `d1be44a` ("extract launch-effort pins + effort levels") ADDED the short
`effortLevels` array. Before that the sidecar held only `launchEffortPins` (long
strings biome keeps multi-line anyway → jq and biome agreed). `effortLevels` is
the first short array where jq and biome diverge. The local test verified
extraction _content_ and auto-staging; the **drift check**
(`checks/claude-code-extracted.nix`) compares parsed JSON (`jq '$a == $b'`),
which is format-agnostic, so the divergence was invisible locally — it only
surfaces in CI's separate `treefmt-check`.

### Why nothing in the pipeline catches it

- `update-pkg.sh` commits the worktree as-is — no `nix fmt` pass. The per-input
  formatter pass exists only in `update-input.sh` (Phase 2.5).
- The `full-format` ninja rule runs on the **base** branch, not the per-package
  `update/claude-code` worktree, so its reformat never reaches the PR.

## Fix (scope: Both — approved)

Defense in depth, two distinct layers:

- **Part A (surgical, source-of-truth):** in `extraExtract`
  (`overlays/claude-code.nix`), run
  `nix fmt -- overlays/claude-code-extracted.json` after the `cp`+`chmod`. The
  hook owns its output's correctness even when invoked outside the pipeline
  (e.g. manual `nix-update --use-update-script`). Matches
  `.claude/rules/nix-standards.md` § "format the working-tree copy after cp".

- **Part B (general safety net):** in `update-pkg.sh`, after a successful
  `nix-update` and gated on a dirty tree, run `run_build nix fmt` before the
  commit. Mirrors `update-input.sh` Phase 2.5, but the trigger is "the
  updateScript regenerated a file" (dirty tree) rather than "the formatter
  moved." Covers any future package whose updateScript emits non-canonical
  files. `nix fmt` exits 0 on successful in-place format (no
  `--fail-on-change`); a non-zero exit is a real formatter error and correctly
  reports HELD BACK.

Both are safe for the drift check (format-agnostic). The two passes are
idempotent (the second is a no-op), so the redundancy is genuine
defense-in-depth, not duplicated logic.

## Unblock PR #253

The code fix lands on the working branch; it does NOT retroactively fix #253's
already-committed file. Options (outward-facing — needs explicit go-ahead):

1. Re-run the Update workflow after merge → force-pushes `update/claude-code`
   with the corrected file.
2. Manually `treefmt` the one file on the `update/claude-code` branch and push.

## Verification

- Build `passthru.extracted`, simulate the cp+format, confirm output ==
  base-branch committed (treefmt-clean) file.
- `treefmt` the edited files.
- Run `checks.claude-code-extracted` (drift) and `checks.formatting`.
