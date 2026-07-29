# Testing & Verification Strategy for Typed Claude/Kiro Hooks (Tiered: hermetic flake-check vs. manual live-fire)

## Bottom line (answers the explicit question)

**No — `nix flake check` cannot cover the hooks that need an authenticated CLI,
and it never will, by construction.** Flake checks are pure, sandboxed
derivations: no network, no auth token, no `~/.claude`/`~/.kiro` credentials, no
way to launch a real `claude`/`kiro-cli` and let it fire an event. So the
verification surface **must split into two tiers**:

- **Tier 1 (hermetic, inside `nix flake check`)** proves two things without a
  CLI or a token: (a) the typed option **emits** the correct `hooks.json` /
  `settings.hooks` JSON (golden-emission, module-eval style), and (b) a
  **generated hook script**, given the **documented** stdin, produces the
  **documented** stdout/exit (contract test, validate-at-stop style, with stub
  tools). This is the large majority of the surface.
- **Tier 2 (manual/live, outside `nix flake check`)** proves the one thing Tier
  1 structurally cannot: that the real CLI **actually fires** the event in the
  relevant mode and **hands the hook the documented stdin**. This burns tokens
  and must be a human-driven harness — a flake app / devenv task / on-demand
  derivation, **never a check**.

The crux the principal must accept: even a perfect Tier-1 contract test only
proves _"given the documented stdin, our script behaves"_. It cannot prove _"the
CLI invokes our script with that stdin"_. That half is irreducibly Tier 2.

---

## The sandbox constraint, precisely

`nix flake check` builds every derivation under `checks.<system>.*` (and
evaluates the other outputs). Each check runs in Nix's build sandbox:
`builtins.currentSystem` isolation, `/nix/store` inputs only, **no network**
(unless a fixed-output/`__noChroot` derivation, which we must not use to smuggle
auth), no `$HOME` secrets, no interactive TTY. The repo already leans on this:
`checks/validate-at-stop.nix:8` uses `runCommandLocal` with
`export HOME="$PWD/home"` (a throwaway) and **stub** tools on `PATH` precisely
so nothing real is contacted.

Consequences for hooks:

- A "live token-using check" **cannot run inside the sandbox at all**. An
  env-gated check that no-ops unless `HOOKS_LIVE_TOKEN` is set (design option
  (d) below) would still fail the moment it tried to reach Anthropic/AWS or read
  a credential — the sandbox has already stripped both. So (d) buys nothing for
  live-fire; it only produces a check that _pretends_ to cover the case (false
  assurance).
- Therefore live hook firing **MUST be a manual harness, not a check.** This is
  not a preference; it is the sandbox contract.

---

## Tier 1 — hermetic (in `nix flake check`, no CLI/auth/token)

Three complementary hermetic techniques already have precedent in this repo. All
belong in `checks/*.nix` (wired at `flake.nix:202-216`) and run under a single
`--max-jobs 1` build, which the repo explicitly blesses.

### 1a. Golden-emission tests — "does the typed option emit the right JSON?"

Pattern: `checks/module-eval.nix` — `evalHm` / `evalDevenv` evaluate the full
HM/devenv module tree against a synthetic `ai.claude.*` / `ai.kiro.*` config and
assert the resulting file/option content. Existing exemplars to copy:

- `checks/module-eval.nix:698-714`
  (`module-claude-devenv-settings-hooks-route-to-upstream`) — asserts
  `ai.claude.settings.hooks.PreToolUse` reaches `claude.code.hooks.PreToolUse`
  and is **excluded** from the gap-written `settings.json`. This is exactly the
  shape a typed-per-event option needs, just richer.
- `checks/module-eval.nix:3009-3069` — `hooksDir` path-form / filter /
  explicit-wins / devenv-parity emission tests.
- `checks/module-eval.nix:1035-1110` — the Kiro auto-memory hook envelope:
  asserts the emitted `.kiro/hooks/kiro-memory.json` contains
  `"trigger":"Stop"`, `"SessionStart"`, `"Manual"`, `"UserPromptSubmit"`,
  `"type":"command"`, the wrapper names, **and** HM↔devenv byte-parity, **and**
  that devenv installs a **real file** (`install -m 0644`, not a symlink — line
  1106).

What a typed hook option must add on top:

- **Per-event, matcher-aware serialization**: feed
  `ai.claude.hooks.PreToolUse = [{ matcher = "Edit|Write"; hooks = [...]; }]`
  and assert the serialized
  `settings.hooks.PreToolUse[0].matcher == "Edit|Write"` and the nested
  `hooks[].command` is an **absolute store path** (nix-standards; a
  `lib.hasInfix "/nix/store/"` assertion catches a bare-command regression).
- **Kiro v3 envelope shape**: assert
  `{version:"v1", hooks:[{name,trigger,matcher?,action:{type,command|prompt},timeout?,enabled?}]}`
  with PascalCase triggers, `builtins.fromJSON` → deep-equal against an expected
  attrset (stronger than `hasInfix`).
- **Composition & precedence** (a stated goal): define the same event at
  multiple layers (e.g. `ai.claude.hooks` + legacy `settings.hooks`
  passthrough + `hooksDir` + a plugin) and assert the merged emission's ordering
  and which entry wins. This is 100% hermetic and is the _only_ correct place to
  prove precedence — do NOT defer precedence to Tier 2.
- **Negative/type tests**: an invalid `trigger` enum or a bare-command hook must
  `throw` at eval (`builtins.tryEval … .success == false`), mirroring
  `module-claude-hm-effort-level-rejects-invalid` (`module-eval.nix:400-416`).

**Coverage: every event on both CLIs is fully emission-testable this way** —
emission is a pure function of the typed option and does not depend on the CLI
ever running.

### 1b. Contract tests — "given the documented stdin, does our hook script behave?"

Pattern: `checks/validate-at-stop.nix:1-85` — the gold standard. It `cp`s the
raw `lib/validate-at-stop.sh` into a scratch dir, puts **stub** `prek` on
`PATH`, builds a `payload()` helper that prints the documented Stop envelope
(`{"cwd":…,"stop_hook_active":…,"hook_event_name":"Stop"}`, line 45), pipes it
to the script, and asserts stdout (`"decision":"block"`) and exit.
`lib/validate-at-stop.sh:11-16` shows the stdin-consumption contract the test
drives (`payload="$(cat)"`, `get()` via `python3 json`).

Apply per generated hook script we own (memory, telemetry, workflow-optimizer,
validators):

- Build a **payload fixture** per event (see Fixtures below), pipe it in, assert
  the documented stdout JSON + exit code.
- Stub every external tool the script shells to (git, openmemory-mem,
  formatters), exactly as validate-at-stop stubs `prek`, so the branch logic is
  deterministic and sandbox-safe.
- Assert the **event-specific output contract**: e.g. PreToolUse
  `hookSpecificOutput.permissionDecision`; UserPromptSubmit `additionalContext`
  / `decision:block`; Stop `decision:block`+`reason`; Kiro command hooks
  exit-2-to-block for PreToolUse/UserPromptSubmit.

**Coverage: contract-testable only for hooks whose action is a _script we
generate_.** It does **not** apply to `action.type:"agent"` (Kiro) or
`type:"prompt"/"agent"` (Claude) hooks — those have no subprocess; the model
executes them, so there is nothing hermetic to drive. Those are emission-only
(1a) at Tier 1.

### 1c. Language-level unit + subprocess tests for hook logic

Pattern: `packages/kiro-cli/memory/distiller.test.ts` (80 bun tests). Pure
functions are unit-tested; the CLI entry is exercised via a **real subprocess
with a synthetic stdin envelope** (`describe("main …")`, lines 907-1052:
`execFileSync("bun", [distiller.ts], { input: JSON.stringify({session_id, cwd}), env: {…} })`
and asserts on-disk effects). The suite runs at **build time** via
`overlays/kiro-memory-distiller.nix:53-57`
(`doCheck=true; checkPhase = bun test`). This is Tier 1 (hermetic — synthetic
stdin, temp dirs) but lives in a **package build**, not a `checks/*.nix`
derivation.

Note for OOM: this suite runs whenever that overlay builds
(`nix build .#kiro-memory-distiller`, a single build = fine). Whether
`nix flake check` itself builds it depends on the Nix version's package-building
behavior — see open questions. Do **not** fan out all package builds in parallel
for CI (the documented OOM trigger); target them.

---

## Tier 2 — manual/live (real authed CLI, burns tokens)

These prove **firing + stdin delivery**, which Tier 1 cannot. What _requires_ a
live CLI:

- **Does the CLI actually emit the event at all, in the mode we ship?** Kiro v3
  hooks fire **only in a trusted TUI** (`dev/scripts/kiro-memory-hitl.sh:53-54`
  verified this on 2.12.0; hooks are workspace-local real files, store
  symlinks + global `~/.kiro/hooks` are skipped). There is (reportedly) **no
  headless hook path** on Kiro and **no `SessionEnd`** — `Stop` fires **per
  turn**. Claude fires most events headlessly (`claude -p`), but `SubagentStop`
  only fires when a `Task`/subagent actually ran, and TUI-vs-headless firing
  differences exist.
- **Does the hook receive the documented stdin?** Kiro's stdin is
  **metadata-only** (`{session_id, cwd}`); the documented
  `UserPromptSubmit.prompt`/`user_prompt` is **empty** on Kiro (this is why
  auto-memory seeds recall from `now.md`, not the prompt). Claude's richer
  payloads (`tool_input`, `tool_output`, `last_assistant_message`,
  `effort.level`, `permission_mode`) can only be confirmed against the _actual
  shipped CLI version_, which may differ from the docs.
- **Edge cases that are live-only:** Kiro **does not fire hooks inside
  subagents** (stated; unverified in-repo → must observe live);
  skill-/agent-scoped hooks; `PreTaskExec`/`PostTaskExec` (spec-execution only);
  Claude `SubagentStop` matcher against agent-type; workspace-local discovery
  (v3 reads only `<cwd>/.kiro/hooks/`).
- **Does the block/permission channel actually take effect?** e.g. Claude
  PreToolUse `permissionDecision:"deny"` actually denies; Kiro exit-2 on
  PreToolUse actually blocks. The _script_ side is Tier-1 contract-tested; the
  _enforcement_ side is live-only.

---

## How to express "manual" in Nix — options compared, with a recommendation

| Option                                                                 | What it is                                                                                                                                                                                                   | In `flake check`?                                     | Fit for this repo                                                                                                  | Verdict                                                                                         |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| **(a) flake app** `nix run .#verify-hooks-live`                        | `apps.<sys>.verify-hooks-live` (pattern at `flake.nix:526-541`) building a `writeShellApplication` that assembles the harness + prints the HITL walkthrough                                                  | No (apps aren't built by check)                       | Good for **external consumers** of the module who lack the dev shell                                               | **Adopt as secondary** (consumer entrypoint)                                                    |
| **(b) devenv task** `verify:hooks:live:{claude,kiro}`                  | A `devenv tasks` entry (namespace:name; repo standard `feedback_devenv_tasks`) that builds the harness derivation and drives the spoon-fed HITL                                                              | No (devenv ≠ check; `feedback_validation_entrypoint`) | Best match: discoverable in the dev shell, matches `feedback_hitl_walk_through_live` + `feedback_use_devenv_tasks` | **Adopt as primary**                                                                            |
| **(c) exposed derivation** `packages.hook-live-harness` (non-`checks`) | A builder that assembles a throwaway trusted project with the **real generated hooks** + probe scripts — exactly `dev/scripts/kiro-memory-hitl.nix` generalized. Built on demand, never evaluated as a check | No (packages not in checks; single build = OOM-safe)  | This is the **artifact** both (a) and (b) drive                                                                    | **Adopt as the shared harness core**                                                            |
| **(d) env-gated check** (no-op unless `HOOKS_LIVE_TOKEN` set)          | A `checks/*.nix` that `exit 0`s unless an opt-in var is set                                                                                                                                                  | Yes (but can't actually run live)                     | Sandbox strips network+auth, so the gated branch can never truly fire → **false assurance**                        | **Reject for live-fire.** (An env-gated _derivation outside checks_ is redundant with (b)/(c).) |

**Recommended shape (combines c + b + a):**

1. **Harness core = a non-`checks` derivation (c)**, cloned from
   `dev/scripts/kiro-memory-hitl.nix`: derive the hooks from the **real
   generators** (never a stale hand-written copy), drop them as **real files**
   into a throwaway trusted git project's `.kiro/hooks/` (v3 requirement) or
   `.claude/settings.json`, and add a per-event **probe** script that appends
   `"$(date -Is) <event>"` to a scratch log **and dumps the received stdin** to
   `scratch/<event>.stdin.json`.
2. **Primary runner = a devenv task (b)** `verify:hooks:live` that builds (1)
   and prints the numbered HITL walkthrough (trust the TUI, run N turns,
   `/hooks`, check the log + captured stdin), mirroring `kiro-memory-hitl.sh`.
3. **Secondary runner = a flake app (a)** `nix run .#verify-hooks-live` for
   consumers outside the dev shell.
4. **Do NOT** put any of this under `checks`, and **do NOT** use an env-gated
   check (d) to simulate live coverage.

**High-value bridge — capture-once, replay-forever.** Have the Tier-2 probe
(step 1) **persist each event's real stdin** to fixtures. Feed those captured
envelopes back into the Tier-1 contract tests (1b) as the golden stdin. Then a
hermetic check re-diffs captured-vs-documented schema on every CI run, catching
CLI **schema drift on upgrades without re-burning tokens**. The expensive live
run seeds the cheap check. Recommend building this seam from day one.

---

## Fixtures — what proves each event

Existing fixtures are **script-body** fixtures for the dir-walk tests:
`checks/fixtures/claude-hooks/{pre-edit,post-edit}` are literal shell scripts
consumed by the `hooksDir` emission tests (`module-eval.nix:3009-3069`);
`claude-agents/*`, `claude-skills/*`, `kiro-steering/*` similarly feed dir-walk
tests. **These do not cover event stdin/stdout.** Add three new fixture
families:

1. **Payload (stdin) fixtures, per event** —
   `checks/fixtures/hook-payloads/claude/<event>.json` and
   `.../kiro/<event>.json`. Each is the **documented** envelope: Claude carries
   the full field set (`session_id`, `transcript_path`, `cwd`,
   `hook_event_name`, `permission_mode`, `effort.level`, plus event-specifics
   like `tool_name`/`tool_input`/`tool_output`, `last_assistant_message`,
   `stop_reason`, `source`, `notification_type`); Kiro carries the
   **metadata-only** `{session_id, cwd}` (the real, observed shape). These feed
   1b.
2. **Expected-output fixtures, per contract-tested hook** —
   `checks/fixtures/hook-expected/<hook>/<event>.json` (+ an expected exit
   code). The contract test asserts the script's stdout deep-equals this
   (`fromJSON` compare) and the exit matches.
3. **Emission-golden fixtures** — `checks/fixtures/hook-emission/<case>.json`:
   the expected serialized `settings.hooks` / `.kiro/hooks/<name>.json` for a
   given typed-option input, for `fromJSON` deep-equal in 1a (stronger than the
   current `hasInfix` spot-checks).

**Live HITL harness pattern (cf. `dev/scripts/kiro-memory-hitl.sh` + `.nix`)** —
the proven template: a `.nix` builder derives artifacts from the real generators
(`autoMemory.nix`, the kiro transformer) so it can't go stale; the `.sh` wraps
it: `rm -rf` a scratch project, `git init` a trusted repo, copy the store-built
hooks as **writable real files** (`chmod -R u+w`, since store copies are
read-only), seed a couple of source files, then print a numbered walkthrough
(`kiro-cli chat --tui --v3`; trust; run turns; `/hooks`; inspect scratch).
Generalize it to: (i) install a probe hook for **every** event, (ii) log
firing + capture stdin, (iii) support both Claude (`.claude/settings.json`,
`claude -p` and TUI) and Kiro (`.kiro/hooks/`, trusted TUI).

---

## Per-hook verification matrix

Legend — **T1e** = Tier-1 emission (always possible). **T1c** = Tier-1 contract
(stub-driven script test; only if the hook's action is a script we generate).
**T2** = live-fire needed to prove the CLI fires it + delivers documented stdin.

### Claude Code (canonical, high-confidence events)

| Event              | Matcher                      | T1e possible?                           | T1c possible?                                        | T2 needed? | T2: what only live proves                                                            |
| ------------------ | ---------------------------- | --------------------------------------- | ---------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------ |
| `PreToolUse`       | tool name                    | Yes                                     | Yes (stub tool; assert `permissionDecision`)         | Yes        | fires before tool; `tool_input` shape; `deny` actually blocks                        |
| `PostToolUse`      | tool name                    | Yes                                     | Yes (assert `additionalContext`/`updatedToolOutput`) | Yes        | fires after success; `tool_output`/`tool_use_id` present                             |
| `UserPromptSubmit` | none                         | Yes                                     | Yes (assert `additionalContext`/`decision:block`)    | Yes        | fires pre-processing; `user_prompt` populated; exit-2 erases prompt                  |
| `Stop`             | none                         | Yes (already: `module-eval` route test) | Yes (already: `validate-at-stop.nix`)                | Yes        | `stop_hook_active` loop-guard flips; `decision:block` continues turn                 |
| `SubagentStop`     | agent type                   | Yes                                     | Yes                                                  | Yes        | requires a real `Task` subagent; `agent_id`/`agent_type` delivered; **fires at all** |
| `SessionStart`     | startup/resume/clear/compact | Yes                                     | Yes (assert stdout→context)                          | Yes        | fires per source; `additionalContext` injected; matcher variants                     |
| `SessionEnd`       | reason                       | Yes                                     | Yes                                                  | Yes        | fires on terminate; `reason` value; (non-blocking)                                   |
| `PreCompact`       | manual/auto                  | Yes                                     | Yes                                                  | Yes        | fires around compaction; exit-2 blocks compaction                                    |
| `Notification`     | notif type                   | Yes                                     | Yes                                                  | Yes        | fires per notification_type; message delivered                                       |

### Kiro CLI v3 (PRIMARY; triggers confirmed from `docs/plans/kiro-v3-docs.txt:339-402`)

| Trigger                             | Matcher     | T1e possible?              | T1c possible?                  | T2 needed? | T2: what only live proves                                                  |
| ----------------------------------- | ----------- | -------------------------- | ------------------------------ | ---------- | -------------------------------------------------------------------------- |
| `SessionStart`                      | none        | Yes (already, auto-memory) | Yes                            | Yes        | fires in trusted TUI; stdout→context; **workspace-local real file loaded** |
| `Stop`                              | none        | Yes (already)              | Yes                            | Yes        | fires **per turn** (not session end); metadata-only stdin                  |
| `PreToolUse`                        | tool name   | Yes                        | Yes (assert exit-2 block)      | Yes        | fires; exit-2 actually blocks; **not fired in subagents**                  |
| `PostToolUse`                       | tool name   | Yes                        | Yes                            | Yes        | fires after tool; stdin shape                                              |
| `UserPromptSubmit`                  | prompt text | Yes                        | Yes                            | Yes        | fires; `prompt` field **empty** (confirm); exit-2 blocks                   |
| `PreTaskExec`                       | none        | Yes                        | Yes                            | Yes        | **spec-execution only**; needs a running spec to fire; can block           |
| `PostTaskExec`                      | none        | Yes                        | Yes                            | Yes        | spec-execution only; fires after task                                      |
| `PostFileCreate`                    | file path   | Yes                        | Yes (assert file-path matcher) | Yes        | fires on create; path passed; template var                                 |
| `PostFileSave`                      | file path   | Yes                        | Yes                            | Yes        | fires on save; matcher against path                                        |
| `PostFileDelete`                    | file path   | Yes                        | Yes                            | Yes        | fires on delete                                                            |
| `Manual`                            | none        | Yes (already, `/remember`) | Yes                            | Yes        | user-invokable via `/hooks`; force path                                    |
| `action.type:"agent"` (any trigger) | —           | Yes (emit prompt string)   | **No** (no subprocess)         | Yes        | model appends prompt to context — live-only                                |

**Kiro v2 (DEFER — code stubs only):** emission-only Tier-1 (assert the
embedded-hook JSON serializes); no contract/live tests until v2 is
de-prioritized-off.

### Cross-cutting rows

| Concern                                                   | Tier         | How                                                                          |
| --------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------- |
| Composition & precedence (event defined in ≥2 places)     | T1e          | Multi-layer synthetic config → assert merged ordering/winner (hermetic)      |
| Absolute-store-path in emitted `command`                  | T1e          | `hasInfix "/nix/store/"` + reject bare command (nix-standards)               |
| Kiro v3 emits a **real file**, not a symlink              | T1e          | Already at `module-eval.nix:1106` (`install -m 0644` in devenv `enterShell`) |
| Kiro v3 reads workspace-local file / skips global+symlink | **T2**       | Live TUI in a trusted scratch project                                        |
| Kiro fires no hooks in subagents                          | **T2**       | Live — drive a subagent turn, confirm no probe firing                        |
| TUI-vs-headless firing (both CLIs)                        | **T2**       | Run each mode, diff the probe log                                            |
| Real stdin schema vs documented (drift)                   | T2→T1 bridge | Capture live once → replay as hermetic contract fixture                      |

---

## Recommended structure to implement (summary)

- `checks/hooks-emission.nix` — golden per-event/matcher emission + precedence +
  type-rejection (module-eval style). **In flake check.**
- `checks/hooks-contract.nix` — per-generated-hook stdin→stdout/exit with stub
  tools + the `checks/fixtures/hook-payloads` + `hook-expected` fixtures
  (validate-at-stop style). **In flake check.**
- Per-hook-script language tests via `doCheck`/`checkPhase` where a hook has
  nontrivial logic (distiller precedent). **Build-time (targeted build),
  OOM-safe.**
- `packages/…/hook-live-harness.nix` (non-checks) + devenv task
  `verify:hooks:live` + flake app `verify-hooks-live` — the manual Tier-2
  surface, seeded from `kiro-memory-hitl.{sh,nix}`. **Never a check.**
- The capture-once→replay bridge that turns a live run into hermetic
  drift-detection fixtures.
