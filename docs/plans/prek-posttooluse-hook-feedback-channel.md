# Assessment: prek PostToolUse hook is noisy AND invisible to the agent

> Status: **ASSESSMENT ONLY — not planned, not implemented.** Picked up
> for diagnosis 2026-06-22 on branch `refactor/ai-factory-architecture`
> after seeing repeated `PostToolUse:Edit hook error` lines in the Claude
> Code session. Root cause is fully understood (below). Fix direction is
> NOT decided — several options with real trade-offs are listed; choose in
> a fresh session.
>
> No code was changed during this assessment.

## Symptom

Every tool call in the Claude Code session surfaces a red notice:

```
PostToolUse:Edit hook error
Failed with non-blocking status code: Unstaged changes detected, stashing
unstaged changes to `.devenv/state/prek/patches/<ts>-<n>.patch`
```

Two things are wrong, and they are independent:

1. **It fires constantly and the agent never reacts to it** (the more
   interesting bug — see "Root cause" fact 2 below).
2. **The displayed line is a red herring** — it's prek's stash message,
   not the actual failure.

## Where it lives (it is local to this repo, NOT nixos-config)

- **Source of truth:** `devenv.nix:160-170` →
  `claude.code.hooks.git-hooks-run.command`. This is devenv's built-in
  `claude.code` ↔ `git-hooks` integration. Upstream devenv auto-generates a
  Claude Code `PostToolUse` hook named `git-hooks-run` that runs the
  pre-commit suite after tool use; our block overrides its `command` to use
  an absolute store path (upstream emits the bare `prek` name, which fails
  under Claude Code's stripped PATH) and redirects `stdout → stderr`.
  Upstream reference in the comment:
  <https://github.com/cachix/devenv/blob/main/src/modules/integrations/claude.nix#L249>
- **Materialized form:** project-local `.claude/settings.json` →
  `hooks.PostToolUse[0]`, **matcher `""`** (matches _every_ tool, not just
  Edit), command:
  `cd "$DEVENV_ROOT" && /nix/store/…-prek-0.3.11/bin/prek run 1>&2`.
- **Global `~/.claude/settings.json` (from nixos-config) has NO PostToolUse
  hook** — only a `PreToolUse` Bash hook (`claude-gh-to-mcp-hook`). The
  nixos-config side is not involved; do not go looking there.

## Root cause — three layered facts

### 1. Content: cspell fails on real-but-undictionaried words

`prek run` exits `1` because `cspell` flags in-progress kimchi vocabulary:

| Word        | Location                                                                                                                                                     | Legit? |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| `getkimchi` | `overlays/kimchi.nix:3` (the `getkimchi/kimchi` GitHub org slug)                                                                                             | yes    |
| `repoint`   | `overlays/kimchi.nix:15`, `.github/instructions/ai-clis.instructions.md:37`, `dev/fragments/ai-clis/packaging-guide.md:30` ("repoint the interpreter/rpath") | yes    |

Neither is in `config/cspell/project-terms.txt`. (`kimchi` itself is also
absent but currently un-flagged.) Because these stay flagged, the suite
fails identically on **every** tool call.

### 2. Mechanism: the agent never receives the failure (exit-code contract)

Claude Code routes hook stderr by **exit code**, and the buckets target
different audiences:

| Hook exit code            | Classification         | Who sees stderr                    |
| ------------------------- | ---------------------- | ---------------------------------- |
| `0`                       | success                | user only (transcript / verbose)   |
| `2`                       | **blocking error**     | **fed to Claude (the model)**      |
| `1` or any other non-zero | **non-blocking error** | **user only**; execution continues |

`prek run` exits **`1`** on hook failure (confirmed by repro). Exit `1` ≠
`2`, so Claude Code files it as a **non-blocking error**: the stderr is
rendered into the human transcript (the red `⎿` lines) and is **never
injected into the model's context window**. From the model's side, nothing
happened — there is no token telling it cspell failed. It is not ignoring a
soft gate; it was never in the room.

**Subtle wiring misconception:** the `devenv.nix:166-167` comment says the
`1>&2` redirect exists for "Claude Code, which only surfaces stderr on
non-blocking hook failures." That conflates audiences — `1>&2` makes the
output reach the **user**, but for a non-blocking (exit≠2) failure it never
reaches the **model**. The redirect cannot bridge that gap; the exit code
gates the audience.

**This is structural, not tunable.** prek (like pre-commit) only emits exit
`0`/`1`; it has no concept of "exit `2` to talk to an LLM." So the current
wiring can _never_ feed the model, regardless of redirects.

### 3. Design: matcher `""` runs the whole suite after every tool call

Even with cspell green, the hook runs the _entire_ pre-commit suite
(treefmt, deadnix, statix, cspell, gitleaks, …) after **every** PostToolUse
— including Read / Grep / Bash, where it is pure waste. Any future advisory
hit (a new unknown word, a deadnix/statix nit on staged code) re-spams and
re-churns. The stash churn accumulates patch files in
`.devenv/state/prek/patches/` (49 MB+, oldest from 2026-04-07). Note
`devenv.nix:95-102` already calls cspell/deadnix/statix "TEMPORARY here …
belong in agent steering, not pre-commit."

## Reproduce

```bash
cd "$DEVENV_ROOT"
/nix/store/…-prek-0.3.11/bin/prek run 1>&2; echo "exit=$?"
# exit=1, cspell Failed on getkimchi / repoint; all other hooks pass.
# prek restores the working tree afterward (stash pop), so it is non-destructive.
```

## Fix directions (decide later — NOT planned)

These are largely orthogonal; the eventual fix may combine 1 + one of 2/3.

1. **Content (clears today's noise, smallest):** add `getkimchi`, `kimchi`,
   `repoint` to `config/cspell/project-terms.txt` (sorted insert). These are
   genuine project terms from the kimchi WIP — not masking. Leaves the
   design issues untouched; the next unknown word re-creates the noise.

2. **Feedback channel (make the agent actually react):** wrap prek so its
   failure reaches a model-facing channel instead of dying at exit `1`.
   Options, in rough order of cleanliness:
   - Emit PostToolUse JSON on stdout:
     `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"<prek output>"}}`
     — injects the failure into context **non-blockingly** (agent sees it,
     tool still succeeds). Probably the best fit: advisory, not a hard stop.
   - Or `{"decision":"block","reason":"<prek output>"}` — feeds `reason` to
     the model and marks the tool result as blocked (stronger; may be too
     aggressive for formatting nits).
   - Or translate non-zero prek → `exit 2` so stderr is fed to Claude
     (bluntest; loses the structured-output niceties).
   - **Trade-off / open question:** do we _want_ the agent self-correcting
     formatting/lint on every edit? That is a behavioral choice, not just
     plumbing. Cuts against `devenv.nix`'s "pre-commit stays narrow; this
     belongs in agent steering" stance — arguably this whole concern is the
     future _agent-harness / steering_ surface the comment defers to, not a
     PostToolUse hook at all. Cross-ref memory
     `feedback_validation_entrypoint` (SSOT: `nix flake check` is THE
     validation; devenv is dev-UX; validators → agent steering, future).
   - **Upstream constraint:** the hook command is devenv-generated; any
     wrapper has to live inside the `claude.code.hooks.git-hooks-run.command`
     override (or replace it), and must keep the absolute-store-path fix and
     the stripped-PATH safety from `.claude/rules/nix-standards.md`.

3. **Scope / cost (stop the waste + churn):**
   - Narrow the matcher so the hook only fires on mutating tools
     (Edit/Write/MultiEdit/NotebookEdit), not Read/Grep/Bash. (Check whether
     the devenv integration exposes the matcher, or whether we override the
     emitted settings.)
   - And/or narrow _which_ hooks run per-tool-call (e.g. formatting +
     gitleaks only; keep cspell/deadnix/statix at commit-time + CI), aligning
     with the `devenv.nix:88-115` two-tier comment.
   - Or drop the `git-hooks-run` PostToolUse integration entirely and rely on
     commit-time hooks + CI (`nix flake check`) + future agent steering.

## Decisions needed before this becomes a real plan

- Do we want per-edit lint feedback to reach the agent at all, or is
  commit-time + CI the right gate (and this hook should shrink/disappear)?
- If we keep it: `additionalContext` (advisory) vs `decision:block`
  (enforcing)?
- Matcher scope: every tool, mutating-only, or off?
- Is this the right home, or does it belong in the not-yet-landed agent
  steering / validator-harness surface (`feedback_validation_entrypoint`)?
- Housekeeping: prune `.devenv/state/prek/patches/` (49 MB+); confirm it is
  gitignored (it is under `.devenv/`).

## References

- `devenv.nix:160-170` — `claude.code.hooks.git-hooks-run.command` override.
- `devenv.nix:88-115` — two-tier validation rationale (why validators are
  "TEMPORARY here").
- `devenv.nix:116-157` — `git-hooks.hooks` (the suite prek runs).
- `.claude/settings.json` — materialized PostToolUse hook (matcher `""`).
- `config/cspell/{cspell.json,project-terms.txt}` — dictionary.
- `.claude/rules/nix-standards.md` — absolute-store-path requirement for any
  wrapper script (stripped-PATH failure mode).
- Memory `feedback_validation_entrypoint` — validation SSOT; validators →
  agent steering, future.
