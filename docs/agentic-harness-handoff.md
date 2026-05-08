# Agentic Harness — Handoff

> **Status:** handoff for a fresh build session (2026-05-08).
> Scoped to sequential prompts with optional writer↔reviewer
> loop steps, `claude -p` only. Open decisions are captured in
> the final section for a follow-up session — don't resolve
> them here.

## Purpose

A small, boring orchestration layer that wraps `claude -p` invocations to give bounded, repeatable, inspectable agent runs. Replaces ad-hoc one-shot bash/python scripts that wrap single prompts.

The harness is permanent infrastructure. Prompts and accept-scripts are disposable artifacts authored against it.

## Core Principles

1. **Runner stays dumb on purpose.** Intelligence lives in prompts (`.md`) and accept-scripts (shell), not in the harness. If the runner starts getting clever, that's a smell — add a verb, don't add reasoning.
2. **External observers with kill authority.** Wall-clock timeout per turn, max-iteration cap per loop. The harness enforces ceilings; it does not judge progress.
3. **Sessions durable, processes disposable.** One claude session persists across invocations on disk; each turn is a fresh process. Killing a process does not destroy the session.
4. **Verdicts are shell predicates.** Loop continuation is decided by an exit code from an accept-script reading the reviewer's log. Agent self-assessment never controls flow. Inter-agent observation (separate writer + reviewer) is the only feedback channel allowed in, and only because the iteration cap keeps it bounded.
5. **Plain files everywhere.** No new file formats invented for the harness.

## Walk Semantics

The harness walks one prompts directory; each top-level entry is one step, processed in lex order.

- `NN-*.md` (file) → one turn against the live session.
- `NN-*-loop/` (subdirectory) → one loop step: writer ↔ reviewer up to `MAX_ITERS`.
- First turn captures `session_id` from claude's JSON output. Subsequent turns invoke with `--resume <id>` so writer sees reviewer's prior feedback and vice versa.
- Each turn (single or loop iteration) is wrapped in `timeout $TIMEOUT_SEC`.
- On any turn timeout, non-zero exit, or loop-cap exhaustion: fire a bounded AAR turn (≤200 words, what was attempted / tried / would do differently), log it, exit non-zero.

**Logs:**

```
harness-logs/$SESSION_NAME/
  turn-01.log
  turn-02-loop/
    iter-01-writer.log
    iter-01-reviewer.log
    iter-02-writer.log
    ...
  turn-03.log
  aar.log
  run.log
```

## Loop Step Shape

A subdirectory in the prompts dir represents one loop step. Required contents:

```
prompts/
  01-design.md           # plain turn
  02-implement-loop/     # loop step
    writer.md            #   "implement X per the design"
    reviewer.md          #   "review the work. end your last line with: VERDICT: APPROVED  or  VERDICT: REVISE"
    accept               #   exec'd after each reviewer turn; exit 0 = approved
  03-finalize.md         # plain turn
```

Minimal `accept`:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
grep -q '^VERDICT: APPROVED$' "$REVIEWER_LOG"
```

**Iteration:** writer turn → reviewer turn → invoke `accept` with `REVIEWER_LOG` env var pointing at the reviewer log just written. Exit 0 advances; non-zero loops back to writer; `MAX_ITERS` exhaustion fires AAR + fails.

**Why a shell predicate instead of parsing the reviewer's verdict:** the harness shouldn't trust agent output. The reviewer says whatever it says; the accept-script is the deterministic gate. A one-line grep is the boring default; substitute a real check (`nix flake check`, a linter, a type-checker exit code) when one fits.

**Why writer and reviewer as separate turns rather than one self-looping turn:** separate turns give per-iteration logs, an explicit external cap, and a clean separation of voices. Self-looping has only the wall-clock timeout (coarse) and conflates voices in one process (less inspectable).

## Reference Script

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Usage: harness.sh <prompts-dir> [session-name]
#   prompts-dir : directory containing NN-*.md files and/or NN-*-loop/ subdirs (lex-sorted)
#   session-name: optional, defaults to basename(prompts-dir)-<unix-ts>

PROMPTS_DIR="${1:?prompts dir required}"
SESSION_NAME="${2:-$(basename "$PROMPTS_DIR")-$(date +%s)}"

TIMEOUT_SEC="${HARNESS_TIMEOUT:-600}"
AAR_TIMEOUT_SEC="${HARNESS_AAR_TIMEOUT:-60}"
MAX_ITERS="${HARNESS_LOOP_MAX:-5}"
ALLOWED_TOOLS="${HARNESS_TOOLS:-Read,Grep,Glob}"
RESUME_ID="${HARNESS_RESUME_ID:-}"
LOG_DIR="./harness-logs/$SESSION_NAME"
mkdir -p "$LOG_DIR"

SESSION_ID="$RESUME_ID"
LAST_LOG=""

invoke() {
  local prompt_file="$1"
  local turn_log="$2"
  local prompt
  prompt=$(cat "$prompt_file")

  if [[ -z "$SESSION_ID" ]]; then
    timeout "$TIMEOUT_SEC" claude -p \
      --output-format json \
      --allowedTools "$ALLOWED_TOOLS" \
      "$prompt" 2>&1 | tee "$turn_log"
    SESSION_ID=$(jq -r '.session_id' "$turn_log" 2>/dev/null || echo "")
  else
    timeout "$TIMEOUT_SEC" claude -p \
      --resume "$SESSION_ID" \
      --output-format json \
      --allowedTools "$ALLOWED_TOOLS" \
      "$prompt" 2>&1 | tee "$turn_log"
  fi
}

aar() {
  local reason="$1"
  local aar_log="$LOG_DIR/aar.log"
  echo "=== AAR: $reason ===" | tee -a "$aar_log"
  local aar_prompt="The previous step was terminated: $reason. In 200 words or less: what were you attempting, what approaches did you try, what would you do differently?"
  if [[ -n "$SESSION_ID" ]]; then
    timeout "$AAR_TIMEOUT_SEC" claude -p \
      --resume "$SESSION_ID" \
      "$aar_prompt" 2>&1 | tee -a "$aar_log" || true
  fi
}

run_turn() {
  local prompt_file="$1"
  local label="$2"
  local turn_log="$LOG_DIR/$label.log"
  mkdir -p "$(dirname "$turn_log")"
  echo ">>> $label: $(basename "$prompt_file")" | tee -a "$LOG_DIR/run.log"
  if invoke "$prompt_file" "$turn_log"; then
    echo "<<< $label ok" | tee -a "$LOG_DIR/run.log"
    LAST_LOG="$turn_log"
    return 0
  else
    local exit=$?
    echo "!!! $label failed (exit $exit)" | tee -a "$LOG_DIR/run.log"
    aar "$label exit-$exit"
    return "$exit"
  fi
}

run_loop() {
  local dir="$1"
  local label="$2"
  local writer="$dir/writer.md"
  local reviewer="$dir/reviewer.md"
  local accept="$dir/accept"

  for f in "$writer" "$reviewer" "$accept"; do
    [[ -e "$f" ]] || { echo "loop step missing $f" >&2; exit 2; }
  done
  [[ -x "$accept" ]] || chmod +x "$accept"

  for ((i=1; i<=MAX_ITERS; i++)); do
    local iter
    iter=$(printf 'iter-%02d' "$i")
    run_turn "$writer"   "$label/$iter-writer"
    run_turn "$reviewer" "$label/$iter-reviewer"
    if REVIEWER_LOG="$LAST_LOG" "$accept"; then
      echo "=== $label converged after $i iteration(s) ===" | tee -a "$LOG_DIR/run.log"
      return 0
    fi
  done

  echo "!!! $label exhausted $MAX_ITERS iterations without acceptance" | tee -a "$LOG_DIR/run.log"
  aar "$label loop-cap-$MAX_ITERS"
  return 1
}

STEP=0
while IFS= read -r entry; do
  STEP=$((STEP+1))
  LABEL=$(printf 'turn-%02d' "$STEP")
  if [[ -d "$entry" ]]; then
    LABEL="$LABEL-loop"
    run_loop "$entry" "$LABEL" || exit 1
  else
    run_turn "$entry" "$LABEL" || exit 1
  fi
done < <(find "$PROMPTS_DIR" -mindepth 1 -maxdepth 1 \( -name '*.md' -o -type d \) | sort)

echo "=== Done. Session: $SESSION_ID, Logs: $LOG_DIR ==="
```

## Configuration Knobs

| Var                   | Default          | Purpose                                                                                                                                       |
| --------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `HARNESS_AAR_TIMEOUT` | 60               | AAR turn wall-clock seconds.                                                                                                                  |
| `HARNESS_LOOP_MAX`    | 5                | Max writer↔reviewer iterations per loop step.                                                                                                |
| `HARNESS_RESUME_ID`   | unset            | If set, skip first-turn capture and resume an existing session immediately. Enables chunked runs across multiple harness invocations.         |
| `HARNESS_TIMEOUT`     | 600              | Per-turn wall-clock seconds.                                                                                                                  |
| `HARNESS_TOOLS`       | `Read,Grep,Glob` | Comma-separated `--allowedTools` for claude. Widen for authoring (e.g., `Read,Edit,Write,Glob,Grep,Bash`); without it, write/bash are denied. |

Defaults are deliberately narrow. Tasks that need more opt in by env, not by editing the harness.

## Loop-Class Distinction

The harness controls the **outer loop** (sequence of prompts; writer↔reviewer iteration cap). It does NOT control the **agent's internal loop** inside a single `claude -p` invocation.

The internal loop is bounded by the per-turn wall-clock timeout, any tool-call cap the runtime enforces, and a `KNOWN_LIMITATIONS.md` referenced from prompts (failure classes the agent should not attempt to fix). All external observers — no agent self-judgment.

## Runtime Caveats — Claude

- `claude -p --output-format json` returns `session_id`; capture with `jq -r '.session_id'`.
- `claude -p --resume <id> "prompt"` continues a session as a new process. Sessions persist under `~/.claude/`.
- `--allowedTools "<comma-list>"` is required for any tools beyond default read access.
- Verify on a real run that `--allowedTools` and `--resume` compose cleanly — allowed-tools may need to be re-specified per resumed turn.
- Only `claude` is supported. Other CLIs are out of scope.

## When to Use

**Use it when:** you can write down ordered steps in advance; some steps benefit from session continuity; one or more steps need writer↔reviewer convergence against an explicit predicate; or you're about to write a one-shot wrapper script for a single prompt.

**Don't use it for:** exploratory thinking (stay in interactive chat); steps that depend on human judgment between them (chunk the run instead — exit, review, re-invoke with `HARNESS_RESUME_ID`); tasks where "good enough" can't be expressed as a shell predicate (then the human is the reviewer, don't fake it with an agent); fan-out shapes (one prompt across N independent files — out of scope here).

## Discipline Notes

- **Don't co-develop the harness with a use case.** Build it against a known-good reference (refactor an existing one-shot wrapper to use it; validate output equivalence). Apply to novel work only after that.
- **Don't make chat smart about the harness.** Chat drafts the prompts dir + accept script, fires the harness, waits for the digest. If chat is generating clever shell, the harness needs another verb.
- **Promote reusable prompts to a `prompts/` library by hand.** Disposable ones stay in their task directory and get deleted. Don't pre-design the library; let it accrete.
- **Accept-scripts should be one-liners when possible.** Growing accept-scripts are a smell — either tighten the reviewer prompt or replace the verdict with a deterministic check (compiler, linter, type-checker exit code).
- **The runner being unimpressive is the property that makes it adoptable.** Sophistication goes into prompts and accept-scripts (inspectable text + shell), not into the wrapper.

## Open Validation Items

- Confirm `claude -p --output-format json` `session_id` field shape on a real run.
- Confirm `--allowedTools` accepts the expected comma-separated tool name list and composes with `--resume`.
- Pick a known-good reference task (e.g., refactor an existing one-shot script to run through the harness) and validate output equivalence before applying to novel work.
- Smoke-test loop convergence on a trivial example: writer drafts a haiku, reviewer accepts only when the closing word is "moon"; verify it terminates within `MAX_ITERS` and that exhaustion fires AAR.

## Open Decisions (deferred — answer in a follow-up session)

These don't block v0 build but should be settled before the harness has multiple consumers.

- **Where the harness lives.** Repo-local script? `~/.local/bin`? Standalone gist? Affects how prompts directories reference it and whether prompts dirs are portable across machines / repos.
- **Accept as executable vs. plain regex file.** Always-an-executable is uniform but heavy for the common one-line-grep case. A `accept.regex` plain-text fallback (file contents = pattern, harness greps reviewer log against it) would cover ~80% of accept-scripts with no shell. Ship strict (executable only) first; relax once a usage pattern is observed.
- **Loop log compression.** Failed loops can produce many `iter-NN-writer.log` / `iter-NN-reviewer.log` pairs. Whether to keep all, keep last N, or compress on success is a question for after the first real run shows actual disk usage. Premature otherwise.
