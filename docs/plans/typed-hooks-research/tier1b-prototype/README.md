# Tier-1b contract-test scaffolding — PROTOTYPE

Working prototype of the **hermetic hook contract-test** tier from
`../../typed-hooks-across-clis-assessment.md` §9 (Tier-1b). It generalises the existing
`checks/validate-at-stop.nix` pattern — _feed a documented stdin payload to a generated hook script,
assert its stdout + exit code, with stub tools and no network/auth_ — to **every PoC event's documented
I/O contract**, across both CLIs.

> **Status:** prototype, **deliberately NOT wired into `checks/` or `flake.nix`.** It runs standalone and
> as a `runCommandLocal` (proven building green: `11 passed, 0 failed`). Promote to
> `checks/hook-contract-tests.nix` only after Phase 1 (see [Graduation](#graduation)).

## What it demonstrates

The whole Tier-1b loop end-to-end on real, primary-sourced contracts — **the deterministic wrapper logic
of a hook is fully testable without a live CLI**:

- **Claude JSON decision-control path** — `PreToolUse` deny via `hookSpecificOutput.permissionDecision`
  (not a top-level `decision`), `SessionStart` context injection, `Stop` `decision:"block"` + the
  `stop_hook_active` loop-guard (the validate-at-stop contract).
- **Claude exit-code path** — `PreToolUse` block via `exit 2` (+ stderr→Claude), mirroring the anthropics
  reference impl; and the trap that **exit 1 does not block**.
- **Kiro path** — `Stop` `{"decision":"block"}` JSON channel driven off a **cwd side-channel** because
  Kiro stdin is metadata-only (the exact constraint autoMemory hit; §12 Q4).

## Layout

```
tier1b-prototype/
├── run-contract-tests.sh        # the harness: fixture -> hook -> assert stdout/exit. Standalone-runnable.
├── contract-test.nix            # runCommandLocal wrapper (the checks/ graduation target). NOT in flake.
├── hooks-under-test/            # PROTOTYPE hooks — stand-ins for the typed factory's mkHookScript output
│   ├── claude-pretooluse-bash-guard.sh    # JSON permissionDecision:deny
│   ├── claude-pretooluse-exit2-guard.sh   # exit-2 block (anthropics-ref style)
│   ├── claude-sessionstart-context.sh     # additionalContext injection
│   ├── claude-stop-guard.sh               # decision:block + stop_hook_active loop-guard
│   └── kiro-stop-guard.sh                 # Kiro decision:block, metadata-only stdin
└── fixtures/                    # capture->replay fixtures (see below)
    ├── claude/{PreToolUse,SessionStart,Stop}/*.json
    └── kiro/Stop/*.json
```

## Run

```bash
# standalone (needs bash + jq + coreutils on PATH — a devenv shell has them)
bash run-contract-tests.sh        # summary only
bash run-contract-tests.sh -v     # + PASS lines

# hermetic, as nix flake check would run it (single derivation, no fan-out)
nix-build --max-jobs 1 contract-test.nix
```

The harness is self-checking: a deliberately-wrong `expect` block is reported as `FAIL` and the suite
exits non-zero (verified against 3 injected corruptions during authoring).

## Fixture format (capture→replay)

Each fixture is one JSON file = **a documented stdin payload + its expected assertions**. This is the
`capture→replay` layout from §9: today the `stdin` blocks are **hand-authored from the hashed docs
snapshot** (`../primary-source-hardening.md`); the **Tier-2 live probe replaces each `stdin` with a real
captured payload** (`v3-<Trigger>-stdin.json` style), and the same fixtures then guard against CLI
stdin-schema drift on upgrade — which would have caught the Kiro empty-`prompt` regression.

```jsonc
{
  "description": "...",
  "provenance": "documented (docs snapshot 2026-07-20 sha …); REPLACE with Tier-2 capture@<ver>",
  "hook": "claude-pretooluse-bash-guard.sh", // a file in hooks-under-test/
  "setup": { "cwdFiles": [".needs-tests"] }, // optional: temp cwd seeded with marker files,
  //           spliced into stdin.cwd (for side-channel hooks)
  "stdin": {
    /* the JSON payload piped to the hook */
  },
  "expect": {
    "exit": 0, // required exit code
    "stdoutEmpty": true, // optional: assert stdout is empty
    "stderrContains": "ripgrep", // optional: substring in stderr
    "jsonAsserts": [
      // optional: parse stdout as JSON and assert paths
      { "path": ".hookSpecificOutput.permissionDecision", "eq": "deny" },
      { "path": ".permissionDecisionReason", "present": true },
      { "path": ".decision", "absent": true },
    ],
  },
}
```

Assertion kinds: `exit`, `stdoutEmpty`, `stderrContains`, and per-path `eq` / `present` / `absent`.
This is intentionally enough to express every PoC event's contract without a bespoke assertion DSL.

## Where this sits in the three tiers (§9)

| Tier             | What                                                                                 | This prototype                                       |
| ---------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| **T1 emission**  | typed option → correct `settings.json.hooks` / envelope JSON (HM+devenv byte-parity) | out of scope here — extends `checks/module-eval.nix` |
| **T1b contract** | documented stdin → generated hook → assert stdout/exit (hermetic)                    | **this dir**                                         |
| **T2 live**      | real CLI fires the hook, observe real stdin (token-burning → NOT a check)            | HITL probe seeds the fixtures here                   |

**Coverage boundary (§9):** T1b covers `command`-action wrapper _logic_ only. It **cannot** exercise Kiro
`action:agent` or Claude `prompt`/`agent` handlers (no subprocess — emission-only), nor prove a hook
actually _fires_ (that is T2, and for Kiro v3 it is TUI-only). The prototype therefore tests the four
`command`-style example hooks; the typed factory's real emitted scripts slot in unchanged.

## Graduation

Promote to `checks/hook-contract-tests.nix` (unioned at `flake.nix:216`) when **all** hold:

1. The typed `ai.claude.hooks.*` / `ai.kiro.hooks.*` factory emits real hook scripts → replace the
   `hooks-under-test/` stand-ins with the factory output (or generate them in-derivation).
2. The Tier-2 probe has run once → replace each fixture's documented `stdin` with a captured payload and
   flip its `provenance` to `captured@<cli ver>`.
3. `git add` the tree (flake `src` only sees tracked files).

Until then it lives here, runnable but unwired, so a `nix flake check` never depends on prototype hooks or
un-captured fixtures.
