# Hook probes

Mode **F** fixtures: hook documents and the scripts they run, for the
operator-driven runs.

**Lint before every run.** `../scripts/lint-probes.sh` refuses each hazard
below; `../scripts/self-test-lint-probes.sh` proves it does. Exit 0 is clean, 1
is findings, 2 is "could not run" — never read a 2 as a pass.

`../scripts/self-test-hook-probes.sh` checks the other half: it feeds each
script below a synthetic payload and asserts its stdout, stderr and exit code,
which together are the entire contract. It starts no Kiro process.

## Installing

```bash
cp fixtures/kiro-primitives/hooks/*.json "<root>/.kiro/hooks/"
```

Three rules, each of which fails **silently** when broken:

- **Copy, never symlink.** The directory reader types a symlink as its own kind
  and the loader keeps only plain files, so a symlinked hook is skipped with no
  warning, no log line and no error. This repo's declarative delivery produces
  store symlinks, which is exactly the trap — and it has already been mistaken
  once for "global hooks are not supported".
- **The scan is flat.** Only `<root>/.kiro/hooks/*.json` is read. A `.json` in a
  subdirectory is never seen. This is the opposite of the agents loader, which
  recurses.
- **The workspace must be trusted.** Hook execution is gated on workspace trust,
  and an untrusted workspace suppresses every hook at debug level while
  returning an empty list. A probe that "did not fire" may only have found an
  untrusted directory.

## Two environment variables

The hook `command` strings resolve the scripts through `KIRO_PROBE_BIN`, so
nothing needs rewriting at install time — a hook inherits the agent's whole
environment, and the agent inherits yours.

| Variable           | Meaning                                                                           |
| ------------------ | --------------------------------------------------------------------------------- |
| `KIRO_PROBE_BIN`   | **Required.** Absolute path to this directory's `bin/`.                           |
| `KIRO_PROBE_STATE` | Optional. Probe log and one-shot sentinels. Default `${TMPDIR:-/tmp}/kiro-probe`. |

Export both before launching, in the shell that launches:

```bash
export KIRO_PROBE_BIN="$PWD/fixtures/kiro-primitives/hooks/bin"
export KIRO_PROBE_STATE="$(mktemp -d -t kiro-probe-XXXXXX)"
```

Every command is written `"${KIRO_PROBE_BIN:?}/probe-…"`, so an unset variable
makes the shell fail loudly instead of running `/probe-….sh` and producing a
probe that appears not to fire.

**Keep the state directory out of every workspace root, and out of `~/.kiro`.**
Writing the probe log inside a workspace would fire the `PostFileCreate` /
`PostFileSave` triggers that the quiet probes exist to measure — once per
record, unboundedly.

## The probes

| Document                       | Trigger            | Shape             | Observable                                           |
| ------------------------------ | ------------------ | ----------------- | ---------------------------------------------------- |
| `probe-observed-prompt-submit` | `UserPromptSubmit` | injects           | stdout in the conversation, plus an `Exit Code` line |
| `probe-observed-session-start` | `SessionStart`     | injects           | stdout in the conversation                           |
| `probe-observed-stop`          | `Stop`             | injects, one-shot | injected `<HOOK_INSTRUCTION>` and a graph restart    |
| `probe-quiet-post-file-save`   | `PostFileSave`     | never perturbs    | a log record only                                    |
| `probe-quiet-post-tool-use`    | `PostToolUse`      | never perturbs    | a log record only                                    |

The split is by intent, and the trigger choice is what enforces it.

**A probe that must be observed** is a `SessionStart` or `UserPromptSubmit` hook
— those two bypass the decision function and inject on **any** exit code — or a
`Stop` hook exiting 1, which is the loop primitive. **A probe that must never
perturb the turn** is `PostToolUse` or a `PostFile*` hook: those never inject
and never block, so their exit code cannot change the turn.

Both observed shapes read stdin **to EOF**, never a line: the engine terminates
the child's stdin after writing the payload, and a line-oriented read would
truncate any payload that is ever pretty-printed while succeeding today.

`bin/probe-inject.sh` writes **nothing to stderr on any path**. For those two
triggers an empty stdout promotes stderr into the conversation, so a progress
line on stderr becomes model-visible text. An error from bash still reaches
stderr, which is wanted — a broken probe should be loud.

## The Stop probe is one-shot, deliberately

A `Stop` hook exiting 1 takes `stderr.trim() || stdout.trim()` as a reason —
**stderr first**, the opposite of what a "print your reason" instinct suggests —
wraps it in `<HOOK_INSTRUCTION>` tags, appends it as a new human message, and
restarts the graph. Nothing stops a hook that always exits 1 from looping
forever, and these fixtures are run by hand.

So `bin/probe-stop-loop.sh` claims an atomic `mkdir` sentinel and injects
**once** per state directory; later calls exit 0 with empty stdout, which routes
to the stop-decision parser, finds nothing, and lets the turn end. The sentinel
path is printed inside the injected text, so the operator reads how to re-arm it
from the transcript:

```bash
rm -rf "${KIRO_PROBE_STATE:-${TMPDIR:-/tmp}/kiro-probe}/claim-observed-stop"
```

The injected reason is capped at 4000 characters and silently truncated beyond
it, so keep injected text short.

## Two fields to get right

- **Never `timeout: 0`.** It is schema-**valid** and means _no timeout at all_ —
  not "use the default", which is 60. Every probe here sets `timeout: 10`.
- **`matcher` is omitted everywhere.** Absent means match-all. It is a regex
  tested against the tool name for two triggers and the file path for three,
  **ignored for the other six**, and it is unanchored — so `"read"` also matches
  `read_files`. A matcher that does not compile makes the hook **never fire**,
  with only a load-time warning. The linter reports the number of matcher fields
  it saw; for this corpus that number is 0.

Hook documents are read with a **plain JSON parser**: no comments, no trailing
commas. Agent `.json` tolerates comments; these do not.

## Reading the results

```bash
grep -c '^=== ' "${KIRO_PROBE_STATE:-${TMPDIR:-/tmp}/kiro-probe}/probe.log"
```

Each record is a header line naming the marker and a verbatim payload line. The
payload is the entire input contract: three common fields (`session_id`,
`hook_event_name`, `cwd`) plus per-trigger extras. There is **no agent name, no
execution id and no nesting depth** in it — a hook script cannot learn which
agent or which level it is running under, which is why level-scoping is a
profile-level decision rather than a runtime branch.

One known defect worth expecting rather than debugging: a `UserPromptSubmit`
command hook receives `prompt: ""` — always empty, regardless of what was typed.
