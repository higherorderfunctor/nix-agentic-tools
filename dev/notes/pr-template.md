# PR body template (sentinel-to-main merge)

Reference template for agentic workers creating PRs during the
sentinel-to-main merge (`docs/superpowers/plans/2026-04-08-
sentinel-to-main-merge.md` Phase 3). Copy the fenced block
below verbatim into the `gh pr create --body "..."` argument,
filling in the `<...>` placeholders.

    ## Summary

    <1-2 sentences describing what this chunk introduces to main.>

    ## Scope

    **Files added:**

    - `path/to/file.nix`
    - ...

    **Files modified:**

    - `path/to/other.nix` — what changed and why
    - ...

    **Dependencies:**

    - Depends on previously-merged chunks: <list or "none (first chunk)">
    - Blocks subsequent chunks: <list>

    ## Verification

    - `nix flake check` — green
    - `devenv test` — green
    - Any chunk-specific manual tests (e.g., built a package,
      ran a module-eval check, etc.)

    ## Backlog items (if any)

    - Any Copilot or review feedback deferred to a backlog
      entry in `docs/plan.md`. Link to the item.

    ---

    Part of the sentinel-to-main merge. Chunk N of 17.

    Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
