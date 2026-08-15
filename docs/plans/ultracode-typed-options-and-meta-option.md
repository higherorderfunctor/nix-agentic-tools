# Ultracode: typed settings options + "ultracode-on-launch" meta option

> **Status:** ✅ IMPLEMENTED 2026-07-08 on `refactor/ai-factory-architecture`
> and committed as one commit. `nix flake check` green. **Owner:** Christopher
> Aubut. **Started:** 2026-07-07. **Committed 2026-07-08 at user request**
> (normally untracked working context per repo convention — do not commit unless
> explicitly asked).
>
> **Decisions locked (2026-07-07):** option **A1** — thin meta option, **NO
> wrapper**, persisted undocumented `ultracode` key + **required `extraExtract`
> guard**. Persisted key honored at launch (Test A + code trace). Binary
> verified: `claude-code 2.1.197`. **Meta-option name chosen:
> `ultracodeOnLaunch`.** Re-verified against the shipped binary
> `claude-code 2.1.202` at implementation time (a bump landed past 2.1.197; all
> three keys still present with matching describe text).

## 0. TL;DR for the executor

Add **two** persistable typed booleans to the Claude factory `settings`
submodule, plus one thin meta option that writes a **third, undocumented** key.
All are plain settings-key writes — no wrapper, no launch flag.

Exact upstream settings.json key names (must match byte-for-byte — they pass
through the freeform identity-map verbatim):

1. **`enableWorkflows`** — `nullOr bool`, typed option. Master Workflows toggle
   (the `/config` "Dynamic workflows" row). Binary default `true`.
2. **`workflowKeywordTriggerEnabled`** — `nullOr bool`, typed option. Per-turn
   keyword trigger (the `/config` "Ultracode keyword trigger" row). Binary
   default `true`. ⚠ **NOT** `ultracodeKeywordTrigger` — that string is only an
   in-memory UI alias, not a persisted key.

Meta option **`ai.claude.ultracodeOnLaunch`** (name TBD) — when `true`, writes
`settings.ultracode = mkDefault true` (⚠ **undocumented** key — §3) +
`settings.enableWorkflows = mkDefault true`. It does **not** touch `effortLevel`
(ultracode auto-implies xhigh) or the keyword trigger (orthogonal, per-turn).
Documented as **session-setup, not the per-turn keyword.**

> **`ultracode` is deliberately NOT given its own typed option.** It is
> undocumented and Anthropic documents ultracode as session-only (§3); a
> first-class typed `settings.ultracode` option would imply it's a stable
> persistable setting, which it isn't. It's written only by the meta option
> (which carries the caveat) — and remains reachable via freeform passthrough
> for power users who accept the risk.

The two typed keys mirror the `effortLevel`/`model` pattern exactly (typed keys
inside the freeform `settings` submodule, null-filtered before upstream). Config
parity across HM + devenv is **automatic — zero new devenv code** (§5).

**✅ RISK DECISION — DECIDED (user, 2026-07-07): option A1.** Ship
`ultracodeOnLaunch` writing the **undocumented persisted `ultracode` key**, **no
wrapper**, **with the `extraExtract` guard** (now REQUIRED, not optional) so any
future claude-code bump that drops the key fails the update pipeline loudly.
Rationale: delivers the on-by-default goal, stays wrapper-free, and the guard
converts the undocumented-behavior risk into a loud failure. (A2
wrapper+`--settings` and B don't-default were considered and declined — see §3.)

## 1. Goal & keyword/mode reference

The user runs `effortLevel = "xhigh"` and wants **ultracode** (xhigh + standing
dynamic-workflow orchestration) on by default, declared in nixos-config,
explicit over relying on Claude's built-in defaults.

There are **three distinct `ultracode`-adjacent mechanisms** — keeping them
straight is the whole point (all verified in binary 2.1.197):

| Mechanism                           | What it is                                                                            | Scope           | Settings key                                                                            |
| ----------------------------------- | ------------------------------------------------------------------------------------- | --------------- | --------------------------------------------------------------------------------------- |
| `ultracode` **session mode**        | xhigh + standing workflow orchestration; re-emits "still on" reminders every 10 turns | **per-session** | `ultracode` (bool) — or `/effort ultracode`                                             |
| `ultracode` **keyword** in a prompt | opts THAT prompt into the Workflow tool                                               | **per-turn**    | gated by `workflowKeywordTriggerEnabled` (bool)                                         |
| Workflows **feature** master switch | enables the Workflow tool at all                                                      | account/session | `enableWorkflows` (bool); kill via `disableWorkflows` / `CLAUDE_CODE_DISABLE_WORKFLOWS` |

Not workflows at all (don't conflate):

- **`ultrathink` / the keyword** — a separate per-turn _reasoning-depth_ nudge.
  No settings key (internal GrowthBook flag `tengu_turtle_carbon` only).
  Confirms the user's belief.
- **`ultraplan` / `ultrareview`** — per-turn keyword routes to _cloud_
  (Claude-Code-on-web) planning / code-review, not the local Workflow tool.

Keyword matching facts (binary): exact contiguous word-boundary regex, **no
dash/space normalization** — `ultracode` triggers, `ultra-code` / `ultra code` /
`ultracoder` do NOT; matches inside slash-commands, code spans, and quotes are
excluded. **The literal keyword changed at v2.1.160** (was `workflow`, now
`ultracode`) — the claudefa.st blog is stale on this. Natural-language ("use a
workflow") is a per-turn opt-in in both versions.

Enable-by-default reality: `ultracode` mode cannot ride any _effort_ surface —
`effortLevel:"ultracode"` (enum-rejected), `--effort ultracode` (not a level),
`CLAUDE_CODE_EFFORT_LEVEL=ultracode` (effort only) ALL fail. It rides the
`ultracode` boolean settings key, which **is honored from persisted
`~/.claude/settings.json`, not only `--settings`** — but this persisted path is
**undocumented and officially session-only** (§3), the crux of the risk
decision.

## 2. Confirmed findings (binary 2.1.197 + user live tests)

Real binary: `/nix/store/…-claude-code/bin/.claude-wrapped` (the `bin/claude` on
PATH is the HM plugin wrapper). Verified by a 17-agent adversarial workflow (run
`wf_760c3e82-bc6`); all load-bearing claims returned **SUPPORTED**.

| Fact                                                                                                                                                                 | Status                             |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `effortLevel` persistable enum = `low\|medium\|high\|xhigh`; `max`/`ultracode` NOT valid effort values                                                               | CONFIRMED                          |
| `ultracode` = a real registered `H.boolean()` settings key ("Enable ultracode for the session…")                                                                     | CONFIRMED                          |
| `ultracode` session mode auto-implies **xhigh** (resolver `nFi` returns "xhigh" before consulting effortLevel); precedence `--effort` flag > ultracode > effortLevel | CONFIRMED                          |
| `enableWorkflows` = master Workflows toggle key; `disableWorkflows` = kill switch                                                                                    | CONFIRMED                          |
| Per-turn keyword trigger key = **`workflowKeywordTriggerEnabled`** (default true); `ultracodeKeywordTrigger` is only a UI alias                                      | CONFIRMED (corrects earlier draft) |
| `ultracode` keyword = per-turn; `ultracode` session mode = per-session                                                                                               | CONFIRMED                          |
| `ultrathink` = separate per-turn reasoning nudge, no settings key                                                                                                    | CONFIRMED                          |
| Persisted `{"ultracode":true}` in settings.json starts session in ultracode (no flag)                                                                                | CONFIRMED (Test A + code trace)    |
| `--settings` MERGES (overlay layer `flagSettings`), does not replace                                                                                                 | CONFIRMED (Test B + code trace)    |

## 3. Resolved questions

### Q3 (persistent key) = YES — the pivot

`{"ultracode": true}` in a persisted `settings.json` starts the session in
ultracode with **no `--settings`, no wrapper**. Two independent proofs:

- **Test A (empirical):** user set it in a project `.claude/settings.json`,
  ultracode was on at startup.
- **Code trace (verified):** both launch sites read `Lr()` = the fully-merged
  effective settings (`vPr` folds userSettings/projectSettings/localSettings/
  flagSettings/policySettings with no per-source stripping of `ultracode`);
  `ultracode` is a known schema key so `safeParse` retains it from any file
  source. `H7r(...)` sets `appState.ultracode = Lr().ultracode === true`
  unconditionally; `nFi` returns `"xhigh"`. Identical to the `--settings` path.

> **Conflict resolved:** one investigator echoed the blog's "no persistent
> field; must inject at launch" framing. That was **refuted** — the binary's
> `describe()` says "session-scoped, typically via --settings; interactive
> toggles never persist it," which is _human guidance_, not a code gate.
> "typically" is non-exclusive; "interactive toggles never persist it" only
> means the in-app `/effort` toggle won't auto-**write** the key — a
> hand-written key is still **read**. Test A is ground truth.

### Q2 (merge vs replace) = MERGE

`--settings` is one high-precedence layer (`flagSettings`), folded over the file
layers; Test B's file-level `env` var survived. Moot for the design (no flag
needed) but recorded.

### Q5 (implies xhigh) = YES

`ultracode:true` ⇒ xhigh unconditionally, before `effortLevel` is read. So the
meta option need NOT set `effortLevel`. (A persistent `effortLevel` does not
override ultracode; only an explicit `--effort` flag does.)

### Q4 (gates)

Org effort cap `QUi` can clamp xhigh→lower at launch with a warning; the user's
own test showed xhigh, so their account isn't capped. The workflow-orchestration
half additionally needs `iE()` (plan availability + `enableWorkflows` + not
disabled) — which is why the meta option sets `enableWorkflows = true` too.

### "Hidden vs documented" — SETTLED against official docs (2026-07-07)

The `ultracode` key IS real (it's in Anthropic's binary schema), but as a
**persisted-settings.json default it is UNDOCUMENTED and off-label.** Checked
the authoritative sources directly:

- **code.claude.com/docs/en/workflows** (official): _"Ultracode lasts for the
  current session and resets when you start a new one."_ Documents enabling via
  the `ultracode` keyword, natural language, or `/effort ultracode` — all
  session/turn-scoped. **No persistable enable-by-default is documented.**
- **code.claude.com/docs/en/settings** (official settings reference): lists
  **`disableWorkflows`** as the only workflow settings.json key. **`ultracode`,
  `enableWorkflows`, and `workflowKeywordTriggerEnabled` are ALL absent.**
- **claudefa.st** is **third-party** (not Anthropic) — the only place showing
  `{ "ultracode": true }` — so it does NOT count as documentation. (My earlier
  "it's documented" was wrong for leaning on it.)

Confidence tiers for the three keys we touch:

| Key                             | Officially documented?                                | Risk                                                               |
| ------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------ |
| `disableWorkflows`              | ✅ settings reference                                 | (we don't use it)                                                  |
| `enableWorkflows`               | ⚠ `/config` toggle only; key name not in settings ref | low — mirrors a stable /config toggle                              |
| `workflowKeywordTriggerEnabled` | ⚠ `/config` toggle only; key name not in settings ref | low — mirrors a stable /config toggle                              |
| `ultracode`                     | ❌ nowhere; officially session-only                   | **high — undocumented + contradicts stated session-only behavior** |

**Implication:** using `ultracode: true` in persisted settings relies on
internal behavior Anthropic explicitly frames as session-only. It works today
(Test A + code trace, 2.1.197) but carries no compatibility promise; a future
version could add a source restriction and silently stop honoring it — _without
it counting as a breaking change on their side._

**Guard is now RECOMMENDED (upgraded from optional):** extend
`overlays/claude-code.nix` `extraExtract` to assert `ultracode` (and ideally
`enableWorkflows` / `workflowKeywordTriggerEnabled`) still parse as settings
keys on each claude-code bump — same mechanism that extracts `effortLevels`.
Turns a future silent breakage into a loud update-pipeline failure. Pair with a
`Last verified: <version>` note in the option/meta description.

## 4. Design

### 4A. Two typed settings booleans (parity with `effortLevel`)

Inside the existing `settings` submodule (mkClaude.nix:51-84), alongside
`effortLevel` (:55-64) and `model` (:65-75). Both `nullOr bool`, default `null`
(so `filterNulls` drops them when unset → Claude's own default applies). Sort
alphabetically-within-group per AGENTS.md; update the submodule's outer
description (:79-82, currently "Typed Claude settings (effortLevel, model)…").
`ultracode` is intentionally NOT a typed key here (§0/§3 — undocumented,
officially session-only); it is written only by the meta option (§4B) and
otherwise reachable via freeform passthrough.

```nix
enableWorkflows = lib.mkOption {
  type = lib.types.nullOr lib.types.bool;
  default = null;
  description = "Master Workflows feature toggle (the /config \"Dynamic workflows\" setting). null leaves Claude's default (true).";
};
workflowKeywordTriggerEnabled = lib.mkOption {
  type = lib.types.nullOr lib.types.bool;
  default = null;
  description = "Whether the \"ultracode\" keyword in a prompt opts THAT TURN into the Workflow tool (per-turn). The /config \"Ultracode keyword trigger\" row. null leaves Claude's default (true).";
};
```

Identity-map is preserved (VERIFIED): HM projection
`settings = aiCommon.filterNulls cfg.nativeSettings;` (mkClaude.nix:284;
`filterNulls` at lib/ai/ai-common.nix:247-257) strips nulls so upstream sees
only explicitly-set bools — the same JSON shape settings.json already accepts
via the freeformType. `docs/plan.md:189`'s warning is about replacing the
submodule with a _closed_ typed schema, NOT about adding null-defaulted keys
inside the still-freeform submodule. Proof it works today:
checks/module-eval.nix:384-390.

### 4B. Meta option: ultracode on at launch (thin, no wrapper)

Locked as the thin kind. Follows `unpinLaunchEffort` (mkClaude.nix:85-99): a
top-level `ai.claude.*` option in the shared options block whose config effect
lands elsewhere. Name TBD — recommend **`ultracodeOnLaunch`** (or
`ultracodeAtLaunch`, matching `unpinLaunchEffort`'s "Launch" vocabulary).

```nix
# option (shared options block)
ultracodeOnLaunch = lib.mkEnableOption
  "starting every Claude session in ultracode (xhigh + dynamic workflows)";

# in BOTH hm.config and devenv.config projections:
config = lib.mkIf cfg.ultracodeOnLaunch {
  ai.claude.nativeSettings = {
    ultracode       = lib.mkDefault true;   # ⚠ UNDOCUMENTED key (§3); freeform passthrough
    enableWorkflows = lib.mkDefault true;   # documented-ish (/config); ensures workflow half on
  };
};
```

- The option's `description` MUST carry the §3 caveat: undocumented + officially
  session-only + `verified on claude-code 2.1.197`. This is where the risk is
  disclosed to consumers (only the meta option writes `ultracode`).
- `mkDefault` lets an explicit `ai.claude.nativeSettings.*` win.
- Does NOT set `effortLevel` (ultracode implies xhigh — §3 Q5) or
  `workflowKeywordTriggerEnabled` (orthogonal per-turn concern).
- No `/effort` EACCES risk: HM writes the key statically at build time — there
  is no runtime read-modify-write (contrast `project_claude_effort_pin_state`).
- Precedent that the same fan-out shape is already idiomatic here:
  `agentsDir`/`hooksDir` → `ai.claude.agents`/`.hooks` via `mkDefault`
  (mkClaude.nix:254-266).

## 5. Implementation surface (verified anchors)

- **`packages/claude-code/lib/mkClaude.nix`**
  - three typed keys → settings submodule options block, :51-84 (beside
    effortLevel :55-64, model :65-75); update outer description :79-82
  - meta option → shared options block (model on `unpinLaunchEffort` :85-99);
    config fan-out in hm.config (cfg at :220) and devenv.config (cfg at :363)
  - HM identity-map already routes settings:
    `settings = filterNulls cfg.nativeSettings` at :284 — **no change needed**
- **devenv parity = AUTOMATIC, zero new code (VERIFIED).** The shared settings
  submodule feeds the devenv gap-write:
  `gapSettings = filterNulls (removeAttrs cfg.nativeSettings ["hooks" "mcpServers"])`
  (:392-396) → `files.".claude/settings.json".json = gapSettings` (:423-425).
  The new keys aren't hooks/mcpServers, so they flow straight through — exactly
  where effortLevel/model already land (proof: checks/module-eval.nix:448-461).
- **Tests** — `checks/module-eval.nix`, copy the effortLevel pattern per key:
  - HM null-filter (broaden :384-390 to assert the three keys absent when unset)
  - HM valid-value reaches `programs.claude-code.settings` (mirror :371-381)
  - devenv gap-write lands in `files.".claude/settings.json".json` (mirror
    :448-461)
  - meta-option test: `ultracodeOnLaunch = true` ⇒ settings.ultracode/
    enableWorkflows true; and explicit `settings.ultracode = false` still wins
- **Docs/fragment** — `packages/claude-code/docs/claude-code-wrapper.md`
  (registered dev/generate.nix:197-203; scope globs :116-119). Pure settings-key
  additions do **not** require the wrapper fragment (its gate is "touch the HM
  plugin wrapper integration" — we don't). The option `description` strings are
  the primary doc. Regenerate after edits:
  `devenv tasks run --mode before generate:instructions`.
- **Bonus cleanup (optional, found en route):** dev/generate.nix:116-119 scope
  glob `packages/ai-clis/claude-code.nix` is **stale** — that path doesn't
  exist; the overlay is `overlays/claude-code.nix`. Fix the glob in the same
  area-touch if convenient.

## 6. Config parity checklist (AGENTS.md "Config Parity")

- [x] HM:
      `ai.claude.nativeSettings.{enableWorkflows,ultracode,workflowKeywordTriggerEnabled}` +
      `ai.claude.ultracodeOnLaunch`
- [x] devenv: same — automatic via shared submodule + gap-write (add a test to
      prove it)
- [x] lib/: n/a (no manual helper affected)
- [x] `nix flake check` green (structural + module-eval)

## 7. Tests — DONE (2026-07-07)

- **Test A (Q3, persistent key):** `.claude/settings.json = {"ultracode":true}`
  → **ultracode on at startup.** ✅ No flag needed.
- **Test B (Q2, merge vs replace):** `--settings '{"ultracode":true}'` with
  file-level `env.UC_MERGE_TEST=survived` → **ultracode on AND
  `UC_MERGE_TEST=survived`.** ✅ Merge, not replace.

Isolated temp project dirs; real config untouched. (Optional future runtime
checks for Q4 org-cap and the workflow-half availability are in the workflow's
`testable` output, not blockers.)

## 8. Consumer-facing end result (nixos-config)

**With the meta option (recommended — one flag):**

```nix
# home/<user>/features/cli/code/ai/claude/default.nix
ai.claude = {
  enable = true;
  ultracodeOnLaunch = true;                    # xhigh + workflows at every launch
  settings.workflowKeywordTriggerEnabled = true;  # per-turn keyword; explicit (default true)
};
```

**Without it (set the settings keys directly — power-user form):**

```nix
ai.claude = {
  enable = true;
  settings = {
    ultracode = true;                      # ⚠ UNDOCUMENTED (freeform passthrough); starts every session in ultracode
    enableWorkflows = true;                # typed; master toggle (default true)
    workflowKeywordTriggerEnabled = true;  # typed; per-turn keyword (default true)
    # effortLevel = "xhigh";               # redundant — ultracode implies xhigh
  };
};
```

Both produce the same `~/.claude/settings.json`. Prefer the meta option — it's
where the undocumented-`ultracode` risk is disclosed. No wrapper either way.
**If risk decision = (B) don't default**, drop the `ultracode` line entirely and
keep only `enableWorkflows` + `workflowKeywordTriggerEnabled`, then use
`/effort ultracode` per session.

## 9. Handoff checklist

- [x] Q2 (merge), Q3 (persistent key works), Q5 (implies xhigh) resolved
- [x] Wrapper-flag path DROPPED — plain settings keys (user-confirmed)
- [x] Correct key names locked: `enableWorkflows`,
      `workflowKeywordTriggerEnabled` (NOT `ultracodeKeywordTrigger`),
      `ultracode`
- [x] Keyword/mode behavior mapped (§1) — documented, no rediscovery needed
- [x] Documentation status SETTLED (§3): `ultracode` persisted = undocumented +
      officially session-only; only `disableWorkflows` is in the settings ref
- [x] **RISK DECISION = A1** (user, 2026-07-07): persisted undocumented
      `ultracode` key + required guard, no wrapper (§0/§3)
- [x] Meta-option name chosen: `ultracodeOnLaunch` (user, AskUserQuestion)
- [x] Add **2** typed keys (+ meta option writing `ultracode`) to mkClaude.nix
      (§4)
- [x] `extraExtract` key-parse guard (§3) — REQUIRED (A1) + stale-glob fix (§5).
      Guard lives in `mkClaudeExtract` (DRY: fires in update pipeline AND
      `nix flake check` drift check). Review-fix: uses a PRESENCE check (>=1),
      not exactly-one-distinct — `ultracode` appears TWICE in 2.1.202, so a
      distinct-count guard would false-fail on future re-minification.
- [x] Add module-eval tests (§5); `nix flake check` green
- [x] Regenerate instructions; verify no stray drift
- [x] Journal reviewed by user before any code change (feedback:
      wait-for-review)
