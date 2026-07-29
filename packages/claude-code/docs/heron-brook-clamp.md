## heron_brook Delegation Clamp — the default-on mitigation

> **Last verified:** 2026-07-29 (commit pending — initial version, against
> claude-code 2.1.220). If you change `ai.claude.delegationClamp`, the
> hook script, the injected text, or either tripwire and this fragment
> isn't updated in the same commit, stop and fix it.

Claude Code injects a system-prompt section — registered internally as
`heron_brook` — whose default payload instructs the model not to call the
Agent tool and not to use workflows or deep research "unless the user
requested it".

Three properties make it worth mitigating rather than living with:

- It is gated on a **model capability**, not on user configuration. On by
  default for Opus 5; no settings key, CLI flag, or environment variable
  disables it.
- It **never appears in the transcript**. A session with delegation
  suppressed is indistinguishable from a normal one, so the failure is
  silent by construction.
- It **contradicts `ai.claude.ultracodeOnLaunch`**, which writes
  `ultracode` / `enableWorkflows` asking for the opposite. Two halves of
  the same system prompt negate each other.

Full evidence, reproduction commands, and the list of dead-end
workarounds live in `private/heron-brook-delegation-clamp.md` (untracked).
Do not re-derive them here.

### Why the mitigation is user-side context, not a patch

The clamp carries its own escape clause: _unless the user requested it_.
So the mitigation **satisfies** that clause instead of fighting it — it
supplies the missing request. Nothing is patched, no flag is needed, and
no binary is touched.

That choice dictates the event. `UserPromptSubmit`'s `additionalContext`
is appended to the **user's** message, so it is user-attributed.
`SessionStart`'s is rendered into the conversation prefixed
`system SessionStart hook additional context:` — **system**-attributed,
and therefore incapable of satisfying a clause about what the _user_
asked for. `SessionStart` is the obvious cheaper choice and it is wrong;
that is the single most likely thing for a future session to "simplify"
into a regression.

### Why once per session, not per turn

`additionalContext` is appended to the user message, which **persists in
conversation history**. Per-turn injection is therefore not fixed
overhead that expires — it is cumulative growth, the same paragraph once
per turn for the life of the session.

So the injector fires once, keyed by a marker file at
`${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-delegation-clamp/<session_id>`,
and a `PreCompact` hook deletes that marker. Compaction is the one event
that can erase the original injection, so it is the one event that
re-arms it.

Degraded inputs (malformed stdin, absent `session_id`) fall back to a
**fixed** key, never a varying one. A varying fallback would inject on
every turn and quietly restore exactly the cost this design avoids —
`checks/claude-delegation-clamp.nix` pins that down.

### Exit 0 is a hard contract, so every filesystem call is best-effort

A non-zero `UserPromptSubmit` hook surfaces as an error to the user on
**every turn**, so the script never exits non-zero. Under `set -e` that is
not a comment, it is a constraint on every line: an unguarded `mkdir`,
`touch`, `rm`, `cat`, or `${VAR:?}` guard is a latent per-turn error
dialog. All of them are explicitly guarded.

Marker bookkeeping is best-effort and the injection happens regardless.
The realistic failure is a shared `/tmp` whose `claude-delegation-clamp/`
directory is owned by another user, reachable whenever neither
`XDG_RUNTIME_DIR` nor `TMPDIR` is set. A marker that cannot be written
degrades toward **injecting**, never toward silence: losing the cadence
costs ~75 tokens per turn, while losing the injection costs the
mitigation itself — the exact failure this feature exists to prevent. A
missing payload file is the one case that lapses instead, because there
is then nothing to inject.

### Why the model is not detected

`UserPromptSubmit`'s stdin is `{session_id, prompt_id, cwd,
permission_mode, prompt}` — it carries **no `model`**. Only `SessionStart`
does. Gating on Opus 5 would therefore need a `SessionStart` companion
writing the model to session-keyed state for the injector to read. At
once-per-session cadence the waste on other models is ~75 tokens once,
which is cheaper than that state file and its staleness failure modes.
So there is no gate, deliberately.

### Why it is a definition, not an option default

`mkClaude.nix` emits the hook pair as a **definition** of
`ai.claude.hooks`, not as that option's `default`. An option `default` is
discarded wholesale the moment a consumer defines the option at all — so
a `default` would have silently disabled the mitigation for exactly the
consumers who use hooks most. As a definition it list-merges with
consumer entries on the same event.
`module-claude-delegation-clamp-composes-with-consumer-hook` is the test
that pins this.

Config parity is structural: both backends already lower `ai.claude.hooks`
to `settings.json`, so the same write serves HM and devenv with no new
module axis. Claude-only, no `ai.*` fanout — `heron_brook` is a section of
the Claude Code client's own system prompt, which Kiro and Copilot never
load.

### The injected text is load-bearing

`ai.claude.delegationClamp.text` reads as a first-person standing request
from the user. Four properties, each deliberate:

1. It **satisfies** the escape clause rather than contradicting the
   instruction. A contradiction pits a user-message line against a
   system-prompt line, which resolves toward the system prompt or toward
   hedging.
2. It is **affirmative**, not a negation of something the model cannot
   point at. "Ignore any instruction telling you X" reads as adversarial
   injection and raises suspicion rather than lowering it.
3. It never presents itself as **machine-generated or relayed**. An
   instruction understood to come from an automated parent gets discounted
   as not-a-user-request.
4. It **grants permission** rather than mandating delegation. An
   overreaching instruction invites that same discounting.

Re-derive all four before rewording it.

### The two tripwires

A mitigation for undocumented vendor behavior must not outlive its cause,
so both fire on their own:

- **`checks/claude-heron-brook.nix`** compares
  `overlays/claude-code-sources.json`'s pinned version against
  `config/heron-brook-tripwire.json`'s `verifiedClaudeVersion` and fails
  when they differ. It lives in `nix flake check` because the requirement
  is that the bot's auto-merging `update/*` PR for claude-code goes red —
  a gate in the update job could not do that.
- **A dated step in `ci.yml`'s `test` job** fails once `reviewBy` passes.
  It cannot be a Nix check: reading the current date inside a derivation
  is impure and would be cached. Once past, it reddens a required check on
  every PR, which is the point; it is self-discharging.

Discharging either means re-verifying against the new binary (the
procedure, with its **mandatory positive control**, is in
`private/heron-brook-delegation-clamp.md` § 5), then either recording the
new version / date, or — if upstream fixed it — **deleting the mitigation
and both tripwires**. An expired justification is a finding, not a
formality to bump past.
