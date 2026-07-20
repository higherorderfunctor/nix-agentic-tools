# Claude typed hooks — implementation record (do-it-right, NOT surgical)

> **Status: ✅ COMPLETE + DEPLOYED (2026-07-20d).** Commits C1–C6b on
> `refactor/ai-factory-architecture`, pushed (origin @ `b5f7f74f`); nixos-config
> repinned + activated clean. Committed as the implementation record + handoff
> (operator-requested). Read "Final state & handoff" next.
>
> Supersedes the "surgical devenv hooks fix" framing in
> `docs/plans/typed-hooks-research/handoff-devenv-hooks-bug.md`. Operator decided
> 2026-07-20: **"no surgical fixes, do it right."**
>
> Scope was the **Claude slice ONLY**. The Kiro typed hooks, trigger sidecar, and
> live-firing verification stay with the assessment session
> (`typed-hooks-across-clis-assessment.md` + `typed-hooks-research/`) — its HOLD on
> this slice is now **RELEASED**. §1–§10 are the design + build record; the section
> immediately below is the close-out + adoption guidance.

## 0. Where this sits

- Compose fix is DONE + shipped: `4b463554` on `refactor/ai-factory-architecture`
  (pushed; nixos-config repinned; operator's HITL activation was running at close).
- This plan = the next work unit (the old "commit 2"), now scoped up to
  typed-northbound + ride-southbound per operator philosophy.

## Final state & handoff (assessment / Kiro session: review + adopt)

**Shipped** (all TDD'd RED→GREEN, single `--max-jobs 1`, 15-check sweep green,
pushed `eadaa023..b5f7f74f`):

- `ai.claude.hooks` is a **typed per-event map**; the event key is a soft enum
  sourced from the drift-checked sidecar; a handler `command` accepts a
  **store-backed package** (S1) so its supporting files ride the `/nix/store`
  closure at absolute, cwd-independent paths.
- Script bodies moved to `ai.claude.hookScripts` / `hookScriptsDir` (BREAKING, but
  latent — no consumer uses them).
- **The latent devenv mis-feed is fixed** — one shared `hooksToSettings` helper
  lowers to `settings.json.hooks` on both backends; `claude.code.hooks` records
  dropped entirely (approach B, §9e).
- Drift guards: `checks/claude-code-extracted.nix` (binary hook-event set) +
  `checks/claude-devenv-hooks-real-type.nix` (real devenv module coexistence).
- Commit map in §10; locked decisions in §9; the concat finding that reshaped the
  design in §9e.

**Reusable patterns to ADOPT for the Kiro slice — do not reinvent:**

1. **Soft-enum sidecar + blocking drift check** (§9c). Extend a binary-grep
   extract (`mkClaudeExtract` in `overlays/lib.nix`; anchored, fail-loud,
   `sort -u`). The Kiro analog resolves the **contested-trigger-set 3-way
   conflict from primary source** (binary wins), exactly as the 30-event grep did.
2. **`formats.json` list-CONCAT merge** (§9e, verified empirically). Composed JSON
   hook writers coexist without clobber — the merge model if Kiro hooks compose
   from >1 source.
3. **Real-type golden test importing the REAL module** (§6 harness → realized in
   `checks/claude-devenv-hooks-real-type.nix`). ⚠ `attrsOf anything` stubs do NOT
   concat lists (they throw) — assert compose invariants against real
   `formats.json`, not the stub.
4. **S1 store-backed handler:** `command = coercedTo package (getExe/outPath) str`.
5. **One shared lowering helper** feeding both backends (HM + devenv).

**Remaining work — NOT done; for the assessment / Kiro session to own:**

- **C7:** fold this record's §3.1/§7/§8 into the committed cross-CLI assessment
  (no longer blocked by the Claude slice).
- **Kiro typed hooks:** type `ai.kiro.hooks` per-trigger (mkKiro's own TODO says
  "model it typed like `permissions`"), replacing today's raw JSON passthrough;
  v3 = per-trigger, v2 = deferred stubs.
- **4 open questions needing a live HITL probe** (capture→replay into the Tier-1b
  fixtures; do NOT per-claim fan out — that re-triggers the openmemory-MCP OOM
  that crashed a prior run): (1) does the 2.13 global `~/.kiro/hooks/` scan follow
  store symlinks? (2) which triggers does the 2.13 binary actually implement?
  (3) does pinned Claude fire per-tool hooks in subagents (still `[U]`)? (4) is
  Kiro stdin metadata-only on 2.13?

## 1. Operator philosophy (the rule to build to)

- **Northbound typed is most important.** Our `ai.claude.*` option layer must be
  typed, not a freeform passthrough.
- **Ride existing tooling southbound; reimplement only when we cannot.** Fan out
  to the sub-module capability that exists; hand-write `files.*` only where no
  capability exists (genuine greenfield / technical limitation).

## 2. Root cause of the current bug (the "why" — answered)

It is **(c): a past session rode the right tooling but with the wrong shape, then
stubbed the check away.** Evidence (both Opus 4.7, 2026-04-21):

- `796677db` "translate ai.claude.settings to devenv via hook routing + gap write":
  _"cfg.settings.hooks routes to `claude.code.hooks` (upstream owns that key and
  writes it into settings.json itself)."_ → correctly picked `claude.code.hooks`
  as the devenv settings.json-hooks emitter, but treated it as a **freeform
  passthrough** and fed it the raw event-map.
- `27f401fe` "add ai.claude.hooks + merge into devenv hook route": _also_ merged
  `ai.claude.hooks` **script-body strings** into the same option.
- Same work extended the stub (`claude.code = attrsOf anything`) "so the
  options-doc walker evaluates our factory output without errors" — which hid the
  type mismatch. `claude.code.hooks` + its typed shape predate the commit (its
  changelog shows `git-hooks-format→git-hooks-run` on 2026-03-10), so NOT a
  timing gap and NOT an unsupported edge case.

**Consequence:** `mkClaude.nix` devenv (`packages/claude-code/lib/mkClaude.nix`,
current line ~539) `hooks = (cfg.settings.hooks or {}) // cfg.hooks;` feeds two
type-invalid shapes into devenv's real `attrsOf hookSubmodule`. Latent (no live
consumer; passes only via the stub).

## 3. Verified primary-source types (re-verify on bump; do not trust memory)

### devenv `claude.code.hooks` (the type we were mis-feeding)

Path: `${(builtins.getFlake (toString ./.)).inputs.devenv}/src/modules/integrations/claude.nix`.

- `claude.code.hooks : submodule { freeformType = attrsOf hookSubmodule;
options.git-hooks-run = <hookSubmodule default>; }`
- `hookSubmodule = { enable:bool=true; name:str=""; hookType: enum[17]; matcher:str=""; command:str (REQUIRED); }`
- 17-event `hookType` enum (exact): `PreToolUse PostToolUse PostToolUseFailure
Notification UserPromptSubmit SessionStart SessionEnd Stop SubagentStart
SubagentStop PreCompact PermissionRequest WorktreeCreate WorktreeRemove
TeammateIdle TaskCompleted ConfigChange`.
- devenv builds `settings.json.hooks` FROM these (`buildHooks`/`groupedHooks`),
  and `git-hooks-run` is a default entry (`PostToolUse`, enabled when
  `git-hooks.enable`). **So if we ride it, devenv owns settings.json.hooks
  generation AND the git-hooks-run composition — the clobber disappears.**
- **Limitation (the "cannot ride" tail) — RE-VERIFIED 2026-07-20d against devenv
  rev `5f1cf17b` (`hookSubmodule` fields: enable/name/hookType(enum 17)/matcher/
  command):** command-only (no `http`/`prompt`/`agent`/`mcp_tool` handler types)
  and no `timeout` field. **CORRECTION to prior wording:** multiple-hooks-per-
  matcher IS supported — `buildHooks`/`groupedHooks` emit N separate settings.json
  blocks for N records sharing a matcher, and Claude fires every matching block,
  so it is behaviorally equivalent (NOT a limitation). Additional event tail:
  devenv's `hookType` enum has only 17 of the binary's 30 events, so wiring any of
  these **13** on the devenv backend also cannot ride `claude.code.hooks`:
  `CwdChanged Elicitation ElicitationResult FileChanged InstructionsLoaded
MessageDisplay PermissionDenied PostCompact PostToolBatch Setup StopFailure
TaskCreated UserPromptExpansion`.

### HM `programs.claude-code` (upstream, NOT a flake input here)

Found at `…-source/modules/programs/claude-code.nix` (home-manager; consumer
provides it — cannot import in a check).

- `hooks : attrsOf lines` → **script files** in `~/.claude/hooks/<name>` (plain
  text, NOT executable — re-confirm on our path per assessment §3.1 [C,R]).
- `settings :` freeform → `~/.claude/settings.json` (so `settings.hooks`
  event-map lands verbatim).

### Capability map (northbound concern → backend southbound)

| Concern                                     | HM capability                                | devenv capability                                                       |
| ------------------------------------------- | -------------------------------------------- | ----------------------------------------------------------------------- |
| **event-wiring** (→ settings.json `hooks`)  | `programs.claude-code.settings` (freeform)   | **`claude.code.hooks`** (typed records) + gap-write the un-modeled tail |
| **script files** (→ `.claude/hooks/<name>`) | `programs.claude-code.hooks` (attrsOf lines) | **none** → greenfield `files.".claude/hooks/<name>"`                    |

## 4. Design (per assessment §8.2/§8.3)

### 4a. Typed northbound

- **Event-wiring becomes typed + event-keyed** (mirrors settings.json 1:1):
  `ai.claude.hooks.<Event> = listOf { matcher?; hooks = listOf handler }`,
  `handler` a tagged union over `type ∈ {command,http,prompt,agent,mcp_tool}`
  (model `command` fully; keep a `freeformType = (pkgs.formats.json {}).type`
  tail for the un-modeled handler types), `<Event>` a **soft enum**
  `either (enum knownEvents) str` sourced from an extracted `hook-events.json`
  sidecar — NEVER hard-code the 17 events.
- **Rename (BREAKING):** current `ai.claude.hooks` (`attrsOf lines` script
  bodies) collides with the new event map → move script bodies to
  `ai.claude.hookScripts` (+ `hookScriptsDir`). [OPEN: name — `hookScripts` vs
  `hookFiles`.]
- Keep freeform `ai.claude.settings.hooks` as a **deprecated escape hatch**.

### 4b. Southbound lowering (ride existing; both backends)

- **devenv event-wiring** → translate typed northbound into
  `claude.code.hooks.<genName> = { hookType=<Event>; matcher; command; }`
  records; devenv emits + composes settings.json (incl. git-hooks-run). The
  un-modeled handler tail → gap-write `files.".claude/settings.json".json.hooks`
  [OPEN: gap-write the tail vs assert-loud that it's unrepresentable].
- **devenv script files** → greenfield `files.".claude/hooks/<name>".text`
  (mirror HM path; non-executable to match).
- **HM event-wiring** → generate settings.json hooks JSON →
  `programs.claude-code.settings` [OPEN: lower typed→JSON here, or keep the raw
  `settings.hooks` passthrough on HM since it's already correct/verbatim].
- **HM script files** → `programs.claude-code.hooks` (already correct).
- **Shared `mkHookScript` helper** — bakes an inline body with the mandatory
  strict-mode header (`set -euETo pipefail; shopt -s inherit_errexit`) to an
  absolute store path (hook env replaces PATH). Generalizes autoMemory's wrappers.

## 5. Sequenced plan (~5–7 commits; single `--max-jobs 1` evals/builds only)

1. **Extract `hook-events.json` sidecar + drift check.** Pattern:
   `overlays/claude-code-extracted.json` (eval-pure `readFile`) +
   `checks/model-staleness-claude.nix` (advisory) / `claude-code-extracted.nix`
   (blocking). New sidecar for the 17 hook events, extracted from the binary.
2. **Typed `ai.claude.hooks` event option + rename script-bodies→`hookScripts`.**
   Northbound only; no emission change yet.
3. **devenv lowering** → `claude.code.hooks` records + gap-tail + `files` for
   scripts. **This is where the latent bug is fixed** (stop the `//` mis-feed).
4. **HM lowering** → settings + `programs.claude-code.hooks` (per §4b OPEN).
5. **De-stub + real-type golden tests.** Replace `claude.code = attrsOf anything`
   for this path with the real module (see §6); assert devenv conformance +
   HM↔devenv byte-parity + git-hooks-run composition (both present). Rewrite the
   2 stub-only devenv hook tests: `module-claude-devenv-settings-hooks-route-to-upstream`
   (checks/module-eval.nix ~line 928, sets `settings.hooks.PreToolUse=[…]`) and
   the `ai.claude.hooks`+`settings.hooks` collision test (~line 2806).
6. **nixos-config lockstep (HITL)** for the rename + options-doc regen. Check
   whether nixos-config sets `ai.claude.hooks` (grep it first).
7. **Fold assessment §3.1/§7/§8 into a committed plan** (coordinate with the
   other session — it's holding on this; do not commit until they're ready).

## 6. Real-type golden-test harness (STEP-1 repro → STEP-3 test)

The reusable pattern: import the REAL devenv `claude.code` module (via
`inputs.devenv`) + stubs, and assert coercion. Seed lives at
`<scratchpad>/repro-devenv-hooks.nix` (may not survive; recreate from this):

```nix
let
  fl = builtins.getFlake (toString ./.);
  pkgs = fl.inputs.nixpkgs.legacyPackages.x86_64-linux; lib = pkgs.lib;
  realClaude = "${fl.inputs.devenv}/src/modules/integrations/claude.nix";
  evalWith = hooksValue: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ (import realClaude) {
      options.git-hooks.enable = lib.mkOption { type = lib.types.bool; default = false; };
      options.git-hooks.package = lib.mkOption { type = lib.types.package; default = pkgs.hello; };
      options.devenv.root = lib.mkOption { type = lib.types.str; default = "/tmp/x"; };
      options.changelogs = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      options.infoSections = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      options.files = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      config.claude.code.enable = true;
      config.claude.code.hooks = hooksValue;
    } ];
  };
  forces = v: (builtins.tryEval (builtins.deepSeq (evalWith v).config.claude.code.hooks true)).success;
in {
  eventMap = forces { PreToolUse = [{matcher="Bash";}]; };            # false (bug repro)
  scriptString = forces { "pre-edit" = "#!/usr/bin/env bash\n"; };    # false (bug repro)
  wellFormed = forces { h = {hookType="PostToolUse"; command="true";}; }; # true (control)
}
```

STEP-3 flips this: feed OUR lowered output and assert it CONFORMS (all true),
plus grep the emitted settings.json for both our hook AND git-hooks-run.
NOTE: HM's `programs.claude-code` is NOT a flake input → cannot import in a
check; assert HM behavior from the documented type instead.

## 7. Open sub-decisions — ✅ ALL RESOLVED 2026-07-20d (see §9)

Kept for the record; every one is now locked in §9 (and §9e supersedes #2/#3).

- Script-bodies rename target: `ai.claude.hookScripts` vs `hookFiles`.
  → **`hookScripts`** (§9b#1).
- devenv un-modeled handler tail: gap-write the tail, or assert-loud (never drop).
  → **moot** — the `formats.json` concat finding folded the tail into the uniform
  JSON helper; no records/partition (§9e).
- HM event-wiring: lower typed→settings.json JSON, or keep the raw
  `settings.hooks` verbatim passthrough (already correct on HM).
  → **lower typed→JSON via the shared helper**, legacy passthrough kept as a
  composing escape hatch (§9b#3, §9e).
- nixos-config consumer impact for the rename (grep before assuming latent).
  → **NONE** — neither repo uses the options; rename is latent (§9d).

## 8. Guardrails (carry every session)

- OOM: never parallel `nix flake check` / nix-fast-build / subagent fan-out;
  single `--max-jobs 1` evals/builds only.
- nixos-config + live switches = HITL (explicit approval, spoon-fed).
- Working/plan docs stay untracked unless asked — this doc was **committed
  2026-07-20d at operator request** as the implementation record + handoff.
- Do NOT modify/move/clean `docs/plans/typed-hooks-across-clis-assessment.md` or
  `docs/plans/typed-hooks-research/` — the assessment session owns them (its hold
  on this slice is released, but the files are still theirs to edit).
- TDD: failing real-type test FIRST; watch it flip.

## 10. BUILD STATUS (2026-07-20d) — Commits 1–6 PUSHED (origin/refactor @ b5f7f74f)

- ✅ **C1 `2f62468b`** feat: hookEvents (30) extracted into drift-checked sidecar.
- ✅ **C2 `11c3f04c`** feat: typed `ai.claude.hooks` event map + rename bodies→`hookScripts`.
- ✅ **C3 `924bb9a1`** fix: devenv lowering (approach B) — THE BUG FIX (mis-feed gone).
- ✅ **C4 `78aa05b5`** feat: HM lowering → `programs.claude-code.settings.hooks`.
- ✅ **C5 `11ed09ef`** test: real-type devenv drift guard (git-hooks-run coexistence).
- ✅ **C6a `b5f7f74f`** docs: `hooksDir`→`hookScriptsDir` in the layered-fanout
  fragment + regen'd `.github/instructions/ai-module.instructions.md`.
- 15-check sequential sweep GREEN (single `--max-jobs 1`). **PUSHED** (operator
  "push is fine"): clean FF `eadaa023..b5f7f74f` (rode d964ae1c oxlint docs along).
- ✅ **C6b nixos-config (HITL):** operator repinned + **activated 2026-07-20d,
  clean** — no consumer uses the renamed options, so activation validates the new
  schema in REAL home-manager (not the stub) with zero regression. SLICE COMPLETE.
- **C7 HELD:** fold assessment (other session owns typed-hooks-research/).
- Compose-fix (4b463554) HITL activation: operator confirmed WORKED (2026-07-20d)
  — the stub-gap is benign, no follow-up.

## 9. LOCKED (2026-07-20d) — operator "lock it"; supersedes §7 open items

All four §7 sub-decisions resolved + an additional-files design chosen. This
section is authoritative where it differs from §4/§7 above.

### 9a. Additional-files model = S1 (store-backed package)

A hook IS a Nix package. The `command` handler field accepts a **derivation**
(coerced via `getExe`) OR a string; supporting files ride the store closure at
absolute paths (cwd-independent — Claude runs hooks with `cwd = project root`, so
relative companion paths are unsafe; store paths are absolute by construction and
identical across HM/devenv). Rationale: no new on-disk `.d` convention to invent;
matches the repo "absolute store paths in wrappers" rule for free. Plain
`ai.claude.hookScripts.<name>` (attrsOf lines) stays ONLY for trivial inline
single-file hooks with no companions. A `mkHookScript` helper turns an inline body
(+ mandatory strict-mode header) into a package for the `command` field.

### 9b. The four locked decisions

1. **Name:** script-bodies → `ai.claude.hookScripts` (+ `hookScriptsDir`). Frees
   `ai.claude.hooks` for the typed event map.
2. **devenv tail = gap-write, never drop, per-event partitioned.** Command
   handlers whose event ∈ devenv-17 AND no `timeout` → ride `claude.code.hooks`
   (keeps devenv's git-hooks-run composition = the clobber fix). Any event ∈ the
   13-event tail, any `timeout`, or any exotic handler type → gap-write that whole
   event's `hooks` array into `files.".claude/settings.json".json.hooks` and
   EXCLUDE it from `claude.code.hooks` (avoids the two-writer array collision).
   For a gap-written `PostToolUse` event, re-inject the git-hooks-run entry
   ourselves. Fallback: if a specific case can't be made merge-safe in TDD,
   assert-loud on THAT case (still never silently drops).
3. **HM lowering = typed→JSON on both backends via ONE shared helper.** HM →
   `programs.claude-code.settings.hooks`; devenv → `claude.code.hooks` records +
   gap tail. Both expose the typed option. Legacy `ai.claude.settings.hooks` kept
   as a deprecated verbatim escape hatch (compose, don't clobber, if both set).
4. **Sidecar = extend `overlays/claude-code-extracted.json` with a `hookEvents`
   key.** Reuses the existing grep (`mkClaudeExtract`) + blocking drift check
   (`checks/claude-code-extracted.nix`) + update-regen + treefmt. No new file.

### 9c. Verified extraction (Commit 1) — deterministic, reorder-robust

Binary `claude-code-2.1.215`. Grep every flat array containing `"PreToolUse"`,
union the CamelCase string tokens, `sort -u` → the **30-event** superset (EXACT
match to the master enum; contains the two observed subsets). Fail loud on zero
matches (anchor gone = upstream schema shape change), mirroring the effortLevel
guard.

```sh
events=$("$grep" -aoE '\[[^][]*"PreToolUse"[^][]*\]' "${bin}" \
  | "$grep" -aoE '"[A-Za-z][A-Za-z0-9]*"' | tr -d '"' | "$sort" -u)
# require >=1; emit hookEvents: [sorted...] into extracted.json
```

The 30 events (northbound soft-enum `knownEvents`; `either (enum knownEvents) str`
so unknowns warn, never fail): PreToolUse PostToolUse PostToolUseFailure
PostToolBatch Notification UserPromptSubmit UserPromptExpansion SessionStart
SessionEnd Stop StopFailure SubagentStart SubagentStop PreCompact PostCompact
PermissionRequest PermissionDenied Setup TeammateIdle TaskCreated TaskCompleted
Elicitation ElicitationResult ConfigChange WorktreeCreate WorktreeRemove
InstructionsLoaded CwdChanged FileChanged MessageDisplay.

### 9e. SUPERSEDES §9b#2/#3 — approach (B), one uniform JSON helper (operator 2026-07-20d)

EMPIRICAL FINDING: `(pkgs.formats.json {}).type` **concatenates** same-key list
definitions across module writers (verified: two writers of
`files."settings.json".json.hooks.PostToolUse` → both entries in the merged
list). So devenv's default `git-hooks-run` (a `claude.code.hooks` entry that
devenv emits into settings.json.hooks) coexists with our gap-writes automatically
— no per-event partition, no git-hooks-run re-injection, no need to mint
`claude.code.hooks` records at all.

**Chosen design (B):** a single shared helper `hooksToSettings : (typed event
map) → settings.json hooks JSON`, defined in mkClaude.nix's `let` (used by both
projections). Lowering:

- **devenv:** gap-write `files.".claude/settings.json".json.hooks = hooksToSettings
cfg.hooks` (composed with the legacy `cfg.settings.hooks` escape hatch; both
  concat with devenv's git-hooks-run). REMOVE the buggy
  `claude.code.hooks = (settings.hooks) // cfg.hookScripts` line (THE FIX). Add
  greenfield `files.".claude/hooks/<name>".text = cfg.hookScripts.<name>`.
- **HM:** write `hooksToSettings cfg.hooks` into
  `programs.claude-code.settings.hooks`; `hookScripts` → `programs.claude-code.hooks`
  (already wired).

Handles all 30 events + timeout + exotic handler types uniformly (no devenv-17
enum ceiling). The 13-event tail / handler-type tail cease to be special cases —
they are just more keys in the same JSON. `hooksToSettings` per handler:
`filterAttrs (v: v != null)` (drops null command/timeout, keeps type + freeform
tail); per block: omit null matcher. De-stub value drops (we no longer feed
`claude.code.hooks`); Commit 5 reassesses.

### 9d. nixos-config consumer impact = NONE (grepped both repos)

Neither `~/Documents/projects/nixos-config` nor `nixos-config2` references
`ai.claude.hooks`/`hooksDir`/`ai.hooks`. The `ai.claude.hooks` rename is LATENT —
breaks no live consumer. HITL lockstep collapses to a repin + switch (no
nixos-config code edit), still gated on operator approval (Commit 6).
