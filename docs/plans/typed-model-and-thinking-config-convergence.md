# Handoff — Typed model + thinking config, Claude effort-pin reconciliation, and per-CLI model staleness checks (CONVERGED)

> **Status:** Design **fully resolved**, forensic-validated, IFD-reviewed,
> **not yet implemented.** This is a handoff for a fresh session to draft the
> **implementation plan** (writing-plans). Every design choice below is
> _decided_ — there are deliberately **no open `OR` forks**. Where something is
> genuinely deferred, it is marked **DEFERRED** with a reason, not left
> ambiguous.
>
> **Origin session:** 2026-06-01. Active versions while diagnosing:
> claude-code **2.1.159**, kiro-cli **2.5.0**, copilot-cli **1.0.56**. Repo
> `nix-agentic-tools`, branch `refactor/ai-factory-architecture`.
>
> **nixos-config is OUT OF SCOPE** and must keep working unchanged
> (`ai.claude.settings.effortLevel = "xhigh"` is already set there).
>
> **This doc SUPERSEDES and merges two prior handoffs** (kept for history,
> marked superseded at their tops):
>
> - `docs/plans/claude-effort-pin-and-mutable-state-reconciliation.md`
> - `docs/plans/per-cli-model-and-thinking-config.md`
>
> **Canonical fact-store:** memory `project_claude_effort_pin_state`.

---

## 0. START HERE

The user asked to converge two work streams into one buildable design with
**all unknowns and design choices solved**. Five sub-agents did binary forensics
plus code/infra mapping; the user made the product decisions. Read §1 (the
reframe) and §2 (locked decisions) once, then the design is §3–§8 organized as
**five workstreams** (WS1–WS5). §9 maps every prior open question to its
resolution. §10 is the file:line build index. Nothing below needs re-deriving.

The single most important takeaway: **"infer models AND thinking level from the
derivation" splits in two.** Thinking level is cleanly derivation-extractable
and becomes a real typed enum. **Models are NOT safely extractable from any of
the three derivations** — they become hand-curated soft-enum hints validated by
a live staleness check. This is forced by hard evidence (§1.2), not preference.

---

## 1. The convergence reframe (so you never re-derive it)

### 1.1 The user's goals, mapped to outcomes

| User goal (verbatim intent)                                                                                     | Outcome                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "allow claude when a new model comes out to bypass the first-time downgrade of thinking level"                  | **WS1** — auto-expanding launch-pin extraction + per-key `unpinLaunchEffort` + HM activation merge into `~/.claude.json`.                                 |
| "infer models and thinking level from derivation without IFD issues into typed options for claude and kiro"     | **Split:** thinking level YES (WS1, binary-extracted enum); models NO-from-derivation (WS2 hand-curated soft-enum + WS3 staleness check).                 |
| "typed claude models and thinking level; thinking level is set in the state; extracted during eval if possible" | Typed `effortLevel` enum whose **valid set** is extracted at update → committed → read at eval; the **chosen value** persists in `settings.json` (state). |
| "type kiro models similar to claude, but no thinking"                                                           | Kiro `defaultModel` becomes the same soft-enum shape; `enableThinking` stays `bool` (no level — none exists, §1.2).                                       |
| "ci update script friendly"                                                                                     | Effort/pin extraction rides the existing `mkUpdateScript` atomically (WS1); Claude model staleness can auto-fire on update (WS3).                         |
| "no fan out model if it's there now, and update the normalized docs since ecosystems may have different models" | No model fanout exists in code (it's a docs phantom) → **WS5** scrubs the docs only.                                                                      |
| "make sure well-rounded failure checks"                                                                         | **§6** — extraction assertions, drift checks, stub-guards, null-filtering, loud activation logging, cold-eval IFD guard.                                  |

### 1.2 Forensic verdicts (the evidence base — five sub-agents, built binaries)

**Extractability of each target from its derivation, IFD-safely:**

| Target                         | CLI     | Verdict                   | Evidence                                                                                                                                                                                                                                                                                                                               |
| ------------------------------ | ------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **effort/thinking-level enum** | Claude  | ✅ **CLEAN**              | The binary's _own_ persisted-setting validator: `effortLevel:y.enum(["low","medium","high","xhigh"])` — single unique fixed-string match, zero false positives. `max` is session-only (separate `oN=[…,"max"]`).                                                                                                                       |
| **launch-pin keys**            | Claude  | ✅ **CLEAN, auto-expand** | `grep -aoE 'unpin[A-Za-z0-9]+LaunchEffort' \| sort -u` → exactly `unpinOpus47LaunchEffort`, `unpinOpus48LaunchEffort`. No other gating. A future `…49…` greps automatically.                                                                                                                                                           |
| **model enum**                 | Claude  | ❌ **MESSY / unsafe**     | Clean signal = `firstParty:"claude-…"` registry (13 ids) but includes **deprecated** models + inconsistent shapes (`claude-3-5-haiku-20241022` vs bare `claude-opus-4-8`); the real `/model` picker emits runtime aliases (`opus`, `sonnet`, `…[1m]`) via auth/provider predicates. A closed enum would reject ids the binary accepts. |
| **model enum**                 | Kiro    | ❌ **backend-driven**     | Fetched at runtime via AWS `ListAvailableModels`; in-binary is only a word-jammed display table (subset, drifts server-side). `src ≠ binary` (tarball) so grepping needs a 258 MB build.                                                                                                                                               |
| **thinking level**             | Kiro    | ❌ boolean only           | `chat.enableThinking` is a pure `bool`. A per-model `output_config.effort` exists but is backend-scoped, not statically enumerable, and **not currently exposed** by the repo.                                                                                                                                                         |
| **model enum / thinking**      | Copilot | ❌ both infeasible/absent | App is a V8 code-cache SEA blob → **zero** greppable model strings (`gpt-`/`claude-`/`model` all return nothing). No reasoning/effort concept at all.                                                                                                                                                                                  |

**Resolver delta to record:** the 2.1.159 effort resolver now has a **two-tier
capability clamp** — `max→high` (`GD$`) **and** `xhigh→high` (`ecH`). Pin
semantics (`opus-4-7`/`opus-4-8` only), env precedence
(`CLAUDE_CODE_EFFORT_LEVEL` beats all, hard-locks `/effort`), and the
`unpin…LaunchEffort` gate are otherwise exactly as the superseded effort-pin doc
§1.3 documents.

**Live list-models reality (probe):**

| CLI     | list-models command                   | auth?                | network? | sandbox-runnable?                                | offline alternative                          |
| ------- | ------------------------------------- | -------------------- | -------- | ------------------------------------------------ | -------------------------------------------- |
| Kiro    | `kiro-cli chat --list-models -f json` | likely yes (AWS SSO) | **yes**  | **no** (degrades to misleading `auto`-only stub) | none reliable                                |
| Claude  | _none_ (`/model` is interactive only) | n/a                  | n/a      | **yes** (grep)                                   | **`firstParty:` binary grep — sandbox-safe** |
| Copilot | _none_ (only `--model <id>` setter)   | yes (GitHub)         | yes      | **no**                                           | **none** (bytecode)                          |

Kiro's authed catalog (probe-confirmed): `auto`, `claude-opus-4.8/4.7/4.6/4.5`,
`claude-sonnet-4.6/4.5/4`, `claude-haiku-4.5`. **`claude-opus-4.8` IS available
in Kiro** (dot-notation id) — answers the prior doc's "is Opus 4.8 a valid Kiro
default" question: yes.

### 1.3 Repo-reality corrections (assumptions that were wrong)

- **`apps/check-drift` / `apps/check-health` do not exist** — they are unchecked
  TODOs in `docs/plan.md:500-501`. Real validation runs as **devenv tasks**
  (`dev/tasks/generate.nix`, wired `devenv.nix:301-304`). The only real flake
  `apps.*` entry is `generate-update-ninja` (`flake.nix:523-537`).
- **`mkSettingsActivationScript` (`lib/ai/hm-helpers.nix:142-161`) is DEAD CODE**
  — defined, never called. Copilot (`mkCopilot.nix:318`) and Kiro
  (`mkKiro.nix:373`) each **inline their own** near-identical `jq -s '.[0]*.[1]'`
  merge. The prior doc's claim that they "use" the helper is wrong.
- **`claude-code.nix` uses the attrset `mkDerivation` form** (not
  `mkDerivation (finalAttrs: …)`). A self-referencing `passthru` extractor that
  greps its own `$out/bin/claude` needs a **`finalAttrs` conversion** (precedent:
  6 mcp/git overlays) or a `let drv = …; in drv // { passthru = … }` wrap.
- **`ai.settings.model` cross-CLI fanout is a pure docs phantom** — 0 `.nix`
  implementations. `lib/ai/sharedOptions.nix` declares 11 normalized options
  (`context`, `mcpServers`, `instructions`, `rules`, `rulesDir`, `lspServers`,
  `agents`, `agentsDir`, `environmentVariables`, `skills`, `skillsDir`) and **no
  `settings`/`model`**. Transformers and `ai-common.nix` touch no model/effort.
- **Claude's HM side delegates settings to upstream** (`mkClaude.nix:237` raw
  `inherit (cfg) settings`), so the reconciler will be the **first** Claude-side
  HM activation script, and typed nullable settings keys (default `null`) **must
  be null-filtered** before reaching upstream (Kiro already does this).
- **devenv never touches `$HOME`** — only repo-local `.claude/` via static
  `files.*`. So global-state reconciliation is HM-only by construction (§7).

---

## 2. Locked decisions

**User decisions (this session):**

1. **Model surface = soft-enum hint.** `lib.types.either (lib.types.enum
knownModels) lib.types.str` (github-mcp `mcp-server.nix:66-67` precedent).
   Non-enforcing: the `str` branch accepts any value; the `enum` provides
   autocomplete/doc value. Applies to **Claude** and **Kiro**. Copilot stays
   freeform `str` (no reliable hint source).
2. **Effort enum = STRICT 4-value.** `lib.types.enum ["low" "medium" "high"
"xhigh"]` — exactly the binary's persisted validator. `max` excluded
   (session-only via `/effort max`; persisting it is clamped to `high`).
3. **`unpinLaunchEffort` = per-key `attrsOf bool`,** default `lib.genAttrs
launchPinKeys (_: true)`. Set a key `false` to deliberately keep one model
   pinned.
4. **Full DRY restore.** Route the new Claude reconciler **and** refactor
   Copilot + Kiro through the shared `mkSettingsActivationScript`.
5. **Models = hand-curated committed lists + a per-CLI staleness check** that
   invokes the CLI's own live list-models, generalized across ecosystems
   (replaces any model binary-extraction). See WS3.

**Forced-by-constraint decisions (documented, not optional):**

6. **Deliver typed `effortLevel` + `model` by converting Claude's `settings`
   from `attrsOf anything` → a typed submodule + `freeformType`** (mirrors
   Kiro `mkKiro.nix:68-113`). Keeps the existing `ai.claude.settings.effortLevel`
   path so **nixos-config keeps working**; a new top-level option would break it.
7. **`unpinLaunchEffort` is a top-level `ai.claude.*` option** (it controls
   `~/.claude.json` reconciliation, not a `settings.json` key).
8. **Effort + pin data → one combined sidecar** `overlays/claude-code-extracted.json
= { launchEffortPins: [...], effortLevels: [...] }` (DRY: one grep pair, one
   drift check, one `git add`, one eval read).
9. **Reconciliation is HM-only;** devenv is a **documented category exception**
   (§7), not a parity bug.
10. **Staleness-check homes:** Claude → pure `checks/` flake check (offline
    grep, sandbox-safe, rides update); Kiro + Copilot → local authed devenv task
    `check:model-staleness` (need net+auth, can't run in CI sandbox).

---

## 3. WS1 — Claude effort-pin reconciliation + typed effort level

**Purpose:** make `settings.effortLevel` actually honored (defeat the
launch-pin), and type it. This is the original effort-pin design, now with the
typed-submodule conversion folded in.

### 3.1 The mechanism being defeated (one-paragraph recap)

On first launch of a newly-shipped model, Claude **pins** effort to that model's
launch default (`high` for Opus 4.8), ignoring `settings.effortLevel`, until
`unpinOpus<NN>LaunchEffort == true` in mutable `~/.claude.json`. `/effort` would
set that flag, but it does a read-modify-WRITE of the whole `settings.json`
**and** the flag in one transaction — and `settings.json` is a `0444` store
symlink, so the write `EACCES`es, the transaction aborts, and the flag is never
written → pinned forever. Fix: reconcile the flag declaratively at activation.
(Full forensic detail: superseded effort-pin doc §1; memory
`project_claude_effort_pin_state`.)

### 3.2 The five pieces

1. **Extractor (pure `runCommand`)** — `passthru.launchEffortPins` (or a single
   `passthru.extracted`) on the claude-code derivation in `overlays/claude-code.nix`
   (~:55, beside `passthru.updateScript`). Requires the **`finalAttrs`
   conversion** (§1.3) to reference `$out/bin/claude`. Greps:
   - pin keys: `grep -aoE 'unpin[A-Za-z0-9]+LaunchEffort' | sort -u`
   - effort enum: `grep -aoF 'effortLevel:y.enum(["low","medium","high","xhigh"])'`
     then extract the array (the 4-value form, **not** the 5-value `oN`).
     Use absolute `${ourPkgs.gnugrep}/bin/grep`, `${ourPkgs.coreutils}`,
     `${ourPkgs.jq}`. **Output is `nix build`-only — never eval-read it** (§5.1).
2. **Generator (rides `mkUpdateScript`)** — extend `vu.mkUpdateScript`
   (`overlays/lib.nix:106-146`). It already prefetches the binary
   (`nix-prefetch-url`) and writes `claude-code-sources.json`. `mkUpdateScript`
   is **generic across all three CLIs** — add the grep step behind an **optional
   param** (e.g. `extraExtract ? ""` shell snippet, default empty) so kiro/copilot
   are untouched. Insertion point: after the `mv "$tmp" "${sourcesFile}"`
   (~`overlays/lib.nix:144-145`), where the linux binary is already prefetched
   (claude's `src` IS the binary — `dontUnpack`). Grep it, `jq`-assemble, write
   `overlays/claude-code-extracted.json`. Both sidecars then land **atomically in
   the same `update/claude-code` PR** → no intra-PR drift.
3. **Committed SSOT** — `overlays/claude-code-extracted.json`:
   `{ "launchEffortPins": ["unpinOpus47LaunchEffort","unpinOpus48LaunchEffort"],
"effortLevels": ["low","medium","high","xhigh"] }`. **`git add` it**
   (flake checks can't see untracked files). Read at eval **only** via
   `builtins.fromJSON (builtins.readFile ./…)`.
4. **Drift check (pure)** — `checks/claude-code-extracted.nix`, registered in
   `flake.nix:202-213` (pass `self`). Template: `checks/cache-hit-parity.nix:172-195`.
   A `pkgs.runCommand` that, **at build time**, re-greps
   `${self.packages.${system}.claude-code}/bin/claude` (or consumes
   `passthru.launchEffortPins` as a build input) and `diff`s against
   `${../overlays/claude-code-extracted.json}` (the **source path** passed as a
   build input — never eval-read). Loud `exit 1` on mismatch. **Failure
   hardening (§6):** assert each grep is **non-empty** AND the effort match
   **count == 1**, so an upstream rename fails loudly instead of silently
   extracting nothing.
5. **Activation consumer (HM)** — in the Claude HM projection
   (`mkClaude.nix:199-284`), via the shared `mkSettingsActivationScript` (WS4).
   Write `cfg.unpinLaunchEffort` (the bool map) to a `pkgs.writeText`/
   `formats.json` file and `jq -s '.[0]*.[1]'`-merge it into `~/.claude.json`
   (Nix values win). Constraints: absolute store paths; **never `exit`** in an
   activation block (memory `feedback_hm_activation_exit`); atomic temp+mv;
   handle `~/.claude.json` absent (`{}`); idempotent; **log how many keys it
   applied** (an "applied 0" must be visible if the SSOT ever empties).

### 3.3 Typed settings submodule (delivers the typed effort level + Claude model)

Convert `mkClaude.nix:44-51` `settings` from `attrsOf anything` to a typed
submodule + `freeformType`, mirroring Kiro:

```nix
# packages/claude-code/lib/mkClaude.nix
let
  # eval-pure: committed SOURCE files, not derivation outputs (no IFD).
  extracted = builtins.fromJSON
    (builtins.readFile ../../../overlays/claude-code-extracted.json);
  knownClaudeModels = builtins.fromJSON
    (builtins.readFile ../models.json);     # hand-curated, WS2; path per final layout
in {
  settings = lib.mkOption {
    type = lib.types.submodule {
      freeformType = (pkgs.formats.json {}).type;   # all other keys pass through
      options = {
        effortLevel = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum extracted.effortLevels);
          default = null;
          description = "Persisted Claude effort level (low/medium/high/xhigh). 'max' is session-only via /effort.";
        };
        model = lib.mkOption {
          type = lib.types.nullOr
            (lib.types.either (lib.types.enum knownClaudeModels) lib.types.str);
          default = null;
          description = "Claude model id. Known ids autocomplete; any string accepted (non-enforcing).";
        };
      };
    };
    default = {};
    description = "Typed Claude settings (effortLevel, model) + freeform passthrough → ~/.claude/settings.json.";
  };

  unpinLaunchEffort = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = lib.genAttrs extracted.launchEffortPins (_: true);
    description = ''
      Per-model "acknowledge launch-default effort" flags merged into
      ~/.claude.json so settings.effortLevel is honored instead of the model's
      launch-default pin. Keys auto-derived from the packaged binary; set a key
      false to leave that model pinned.
    '';
  };
}
```

**Null-filter requirement:** because the typed keys default to `null`, the HM
projection must stop using raw `inherit (cfg) settings` and instead pass
`aiCommon.filterNulls cfg.settings` (or the Kiro `filteredSettings` pattern) into
`programs.claude-code.settings`, so upstream never receives `effortLevel = null`
/ `model = null`. Verify `filterNulls` handles the submodule (recurse if needed).

**Why a submodule, not a top-level option:** keeps the
`ai.claude.settings.effortLevel` path → nixos-config (out of scope) keeps
working and now validates `xhigh` against the enum.

### 3.4 Verification (WS1)

- [ ] `nix flake check` passes **on a cold eval** (no IFD regression).
- [ ] Drift check fails loudly when the committed JSON omits a key the binary has
      (delete a key to simulate) and when a grep returns empty.
- [ ] After activation, `jq '.unpinOpus48LaunchEffort' ~/.claude.json` → `true`.
- [ ] Fresh `claude` (clear both flags first) shows `xhigh`; `/effort max` still
      works for a session.
- [ ] An invalid `settings.effortLevel` (e.g. `"ultra"`) throws at eval
      (`builtins.tryEval` test).
- [ ] An `update/claude-code` PR regenerates **both** sidecars together.

---

## 4. WS2 — Typed model soft-enum hints (Claude + Kiro)

**Purpose:** deliver "typed models" within the forensic constraint that no closed
enum is safe.

- **Source = hand-curated committed JSON per CLI.** Suggested layout (co-located
  with the consumer per content-separation, memory `feedback_content_separation`):
  `packages/claude-code/models.json`, `packages/kiro-cli/models.json`. Each a
  JSON array of ids, e.g. Claude `["claude-opus-4-8","claude-sonnet-4-6",
"claude-haiku-4-5"]`, Kiro `["claude-opus-4.8","claude-sonnet-4.6",
"claude-haiku-4.5"]` (**note Kiro's dot-notation**, Claude's dash). Curate to
  the **current, non-deprecated** set the user actually selects.
- **Type** = `lib.types.nullOr (lib.types.either (lib.types.enum knownModels)
lib.types.str)`. Read via `fromJSON (readFile ./models.json)` at eval
  (IFD-free, §5.1).
- **Claude** `settings.model` (the submodule key, §3.3). **Kiro**
  `chat.defaultModel` (`mkKiro.nix:76-80`) — change its type from `nullOr str`
  to the soft-enum; keep `default = null`.
- **Copilot** stays freeform `str` (no reliable hint source; §1.2).
- **`git add`** the model JSONs.

---

## 5. WS3 — Model staleness checks (generalized, per-CLI homes)

**Purpose:** the hand-curated lists (WS2) drift as backends change. A staleness
check flags drift by comparing the committed list against the tool's live
reality. Generalized "apply to all ecosystems," but with **per-CLI homes**
because only Claude can run offline.

### 5.1 The IFD rule (governs Claude's check)

> **Eval reads ONLY committed source JSON.** Never let any eval-time expression
> (`readFile`/`fromJSON`/`import`) touch a **derivation/`runCommand` output**
> (e.g. `"${pkgs.claude-code.passthru.launchEffortPins}"`). That forces a build
> during eval = IFD = the cold-CI `path '…-source.drv' is not valid` failure
> class eliminated in commit `f277053`. `fromJSON (readFile ./committed.json)` on
> a **git-tracked source file** is pure and IFD-free (the repo relies on it in
> `overlays/{claude-code,kiro-cli,copilot-cli}.nix` + `config/generate-update-ninja.nix`).
> Build-vs-eval split: CI `build` = `nix-fast-build .#packages`; CI `test` =
> `nix flake check` (eval-only). A new IFD breaks `test` on a cold runner.

### 5.2 Claude — pure `checks/` flake check (sandbox-safe)

- `checks/model-staleness-claude.nix`, registered like WS1's check (pass `self`).
- **Build-time** (inside the `runCommand`, never eval): grep
  `${self.packages.${system}.claude-code}/bin/claude` for `firstParty:"claude-…"`,
  normalize, and **diff against** the committed `packages/claude-code/models.json`
  (source path as build input).
- **Advisory, not blocking on supersets:** the curated list is intentionally a
  _subset_ (no deprecated ids). So the check should flag only **models present in
  the binary but missing from the committed list that look current** (i.e. new
  models to consider adding) — or, simplest: warn-and-pass on any difference,
  printing the delta, rather than `exit 1`. (Decide blocking vs advisory at plan
  time; lean **advisory/warn** — a new model shouldn't fail CI, it should nudge a
  curation PR.) This is distinct from WS1's drift check, which **must** block
  (pins/levels must stay exact).
- Can auto-fire on update (extend `mkUpdateScript` to print a reminder when the
  binary hash changed), but the authoritative gate is the flake check.

### 5.3 Kiro + Copilot — local authed devenv task

- New devenv task `check:model-staleness` in `dev/tasks/` (registered like the
  `generate:*` tasks, `dev/tasks/generate.nix` + `devenv.nix:301-304`). Runs on
  the user's machine (network + creds available).
- **Kiro:** `kiro-cli chat --list-models -f json`, parse `.models[].model_id`,
  diff against `packages/kiro-cli/models.json`. **Stub-guard (§6):** if the
  result is exactly the offline `auto`-only payload
  (`{"models":[{"model_name":"auto",…}],"default_model":"auto"}`), treat as
  "not authed / no network" → **skip with a clear message**, do **not** report
  drift (a sandbox/offline run otherwise produces a false positive).
- **Copilot (weakest leg):** no list command exists. Options at plan time:
  (a) leave Copilot's list **manually curated only**, no automated staleness
  check; or (b) best-effort: for each committed id, `copilot -p … --model <id>`
  and flag ids the backend rejects (needs GitHub auth, slow). **Lean (a)** with a
  doc note; **DEFERRED** decision, low value.
- Output a single report (per-CLI: OK / drift-with-delta / skipped-not-authed).

### 5.4 Honesty note for the handoff

The user's mental model — "a check that runs when the binary is updated" — holds
**fully only for Claude** (offline, CI/update-time). Kiro/Copilot staleness
**cannot** run in the CI update PR (no net/creds); it is a **local** task the
user runs (the update PR can _remind_ via a printed note, but cannot execute the
live query). Capture this asymmetry plainly; don't imply CI checks Kiro/Copilot
model drift.

---

## 6. Failure-check design (the "well-rounded failure checks" goal)

| Check                                       | Where                              | Behavior                                                                                                 |
| ------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------- |
| pin/effort extraction **non-empty**         | WS1 drift check (build)            | `exit 1` loud if either grep yields nothing (catches an Anthropic rename of the mechanism).              |
| effort match **count == 1**                 | WS1 drift check (build)            | `exit 1` if the fixed-string anchor matches ≠1 times (catches reorder/format change).                    |
| committed-vs-binary **drift** (pins+levels) | WS1 drift check (build)            | `exit 1` with delta — **blocking** (pins/levels must be exact for correctness).                          |
| Claude **model** drift                      | WS3 flake check (build)            | **Advisory/warn** with delta — new models nudge a curation PR, don't fail CI.                            |
| Kiro **model** drift                        | WS3 devenv task (local)            | Report drift; **skip** on the `auto`-only stub (no false positive offline).                              |
| **cold-eval IFD** regression                | `nix flake check` on a cold runner | The whole point of the IFD rule (§5.1) — verify in CI matrix.                                            |
| **null-filter** correctness                 | `checks/module-eval.nix` (eval)    | Assert `programs.claude-code.settings` has no `effortLevel = null`/`model = null` when unset.            |
| typed-enum **rejection**                    | `checks/module-eval.nix` (eval)    | `tryEval` an invalid `effortLevel` → must fail; a valid one → reaches upstream (HM) + gap file (devenv). |
| activation **applied-count** log            | runtime activation                 | Print "applied N unpin keys"; N=0 is a visible signal the SSOT emptied.                                  |
| `git add` visibility                        | pre-commit / flake check           | New committed JSONs must be tracked or checks silently mis-pass (`.claude/rules/nix-standards.md`).      |

---

## 7. Parity decisions (HM vs devenv)

- **The effort _setting_** already has parity: `settings.effortLevel` reaches
  `~/.claude/settings.json` on both HM (upstream) and devenv (gap write,
  `mkClaude.nix:353-355`). The typed submodule (§3.3) preserves this on both.
- **The `~/.claude.json` reconciliation is HM-only.** devenv **never** touches
  `$HOME` (only repo-local `.claude/`); mutating global user state from a
  project shell would violate the devenv model — and the precedent is already
  set (Kiro/Claude devenv blocks deliberately drop HM activation merges,
  `mkKiro.nix:549-552`). **This is a documented category exception, not a parity
  bug** (CLAUDE.md "Config Parity" is satisfied: the _settings file write_ exists
  in both; global-home mutation is structurally out of scope for devenv).
- **Model soft-enum (WS2)** is pure typing → parity on both backends for free.
- **Staleness homes (WS3)** are intentionally asymmetric (§5.3) by capability,
  not by ecosystem preference.

---

## 8. WS4 (DRY restore) + WS5 (docs scrub)

### 8.1 WS4 — full DRY restore of the activation merger

- Generalize `mkSettingsActivationScript` (`lib/ai/hm-helpers.nix:142-161`) so a
  caller passes a **"values to merge" JSON file** (`nixSettingsPath`) + a target
  `configFile`. It already does cp-on-missing + `jq -s '.[0]*.[1]'` + chmod 644
  - atomic temp/mv + no `exit`.
- **Route all three through it:** Copilot (`~/.copilot/settings.json`,
  `mkCopilot.nix:318`), Kiro (`~/.kiro/settings/cli.json`, `mkKiro.nix:373`),
  **and** the new Claude reconciler (`~/.claude.json`, WS1 #5). Preserve each
  call site's gating (`lib.mkIf (filteredSettings != {})`) and `configDir`.
- Add `checks/module-eval.nix` activation-text assertions for all three (pattern:
  `module-copilot-hm-writes-settings-json-activation` at `:475-487`).
- **Doc nit to fix while here:** Copilot's `settings` option description and
  `outputPath` say `~/.config/github-copilot/`, but the **HM** real path is
  `~/.copilot/` (`configDir` default `.copilot`, `mkCopilot.nix:112-116`); devenv
  uses `.config/github-copilot`. Correct the stale description.

### 8.2 WS5 — scrub the phantom `ai.settings` from docs (no code changes)

`ai.settings` / `ai.settings.model` / `ai.settings.telemetry` is documented in
**9 doc locations + 2 more found this session**, implemented in **0** `.nix`
files. Scrub (one commit, `docs(ai): drop unimplemented normalized ai.settings; models are per-CLI`):

| File:line                                           | Action                                                                                      |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `devshell/docs-site/pages/ai-mapping.md:64`         | Replace `ai.settings.model` example with per-CLI (`ai.kiro.settings.chat.defaultModel`).    |
| `devshell/docs-site/pages/home-manager-footer.md:8` | Same.                                                                                       |
| `devshell/docs-site/default.nix:38`                 | Remove the `settings.model` fanout table row (found this session).                          |
| `dev/fragments/ai-module/ai-module-fanout.md:84`    | Remove `ai.settings.{model,telemetry}` from normalized list, then regenerate.               |
| `dev/fragments/hm-modules/module-conventions.md:30` | Remove `ai.settings` from top-level options list, then regenerate.                          |
| `dev/references/config-parity.md:29,69,71,74`       | Delete the "Normalized Settings (ai.settings)" section + row; **keep** per-CLI rows.        |
| `dev/docs/concepts/config-parity.md:24`             | Fix settings row.                                                                           |
| `dev/docs/concepts/unified-ai-module.md:55,63`      | Rewrite model example as per-CLI.                                                           |
| `dev/docs/getting-started/home-manager.md:168`      | Rewrite model example as per-CLI.                                                           |
| `.claude/rules/ai-module.md` (+ Copilot/Kiro twins) | **Generated** — fixed by regenerating after the fragment edits, **not** hand-edited.        |
| `dev/notes/ai-transformer-design.md:23,241,1459`    | **Leave** (design archive); optionally annotate "rejected — models are ecosystem-specific". |

Regenerate via `devenv tasks run --mode before generate:instructions` (memory
`feedback_use_devenv_tasks` — never hand-edit generated files). `treefmt` every
changed file. Final `RIPGREP_CONFIG_PATH=/dev/null rg --no-config "ai\.settings"`
sweep to confirm zero stragglers before commit.

---

## 9. Every prior open question → resolution

| Prior open question (source doc)                                             | Resolution                                                                                                                                                                                             |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| HM-vs-devenv parity for the reconciliation (effort-pin §3.4)                 | **HM-only**, devenv documented category exception (§7). Forensics: devenv never touches `$HOME`.                                                                                                       |
| Master-toggle vs per-key `attrsOf bool` for `unpinLaunchEffort` (effort-pin) | **Per-key `attrsOf bool`** (locked decision #3).                                                                                                                                                       |
| Track B: one generalized abstraction vs per-CLI fixes (effort-pin §4)        | **Collapses** — only Claude has the launch-pin shadow + EACCES; Kiro/Copilot use writable-644 merges, no shadow flags. The real cross-CLI work is the DRY restore (WS4) + the staleness pattern (WS3). |
| Kiro model auto-detect feasibility (per-cli §5)                              | **Infeasible from derivation** (backend-driven, src≠binary). → hand-curated + live staleness check (WS2/WS3).                                                                                          |
| Should `defaultModel` get value validation (per-cli §5)                      | **Soft-enum hint** (`either (enum known) str`), non-enforcing (locked decision #1).                                                                                                                    |
| Confirm Opus 4.8 is a valid Kiro default + its id string (per-cli §5)        | **Yes**, id `claude-opus-4.8` (dot notation), probe-confirmed in the authed catalog.                                                                                                                   |
| Scrub vs implement `ai.settings` (per-cli §2)                                | **Scrub** — it's a docs phantom (WS5). Models are ecosystem-specific.                                                                                                                                  |
| 4- vs 5-value effort enum                                                    | **4-value strict** (`max` is session-only) (locked decision #2).                                                                                                                                       |
| Combined vs separate extraction sidecar                                      | **Combined** `claude-code-extracted.json` (locked decision #8).                                                                                                                                        |
| Where the typed effort/model options live                                    | **Typed submodule conversion** of `settings` (forced #6); `unpinLaunchEffort` top-level (#7).                                                                                                          |
| Where staleness checks run                                                   | Claude → flake check; Kiro/Copilot → local devenv task (#10, §5).                                                                                                                                      |

**Genuinely DEFERRED (with reason):** Copilot model staleness automation
(no list command; low value — §5.3). A per-model Kiro effort surface
(`output_config.effort`; backend-scoped, not currently exposed — out of scope
for this convergence).

---

## 10. File:line build index (all confirmed against live code)

**Extraction + generation:**

- `overlays/claude-code.nix` — `:31` `fromJSON+readFile` (the pure idiom to copy);
  `~:42-52` installs `$out/bin/claude` (`dontUnpack`, src==binary); `~:55`
  `passthru.updateScript` (add extractor neighbor; needs `finalAttrs` conversion).
- `overlays/lib.nix:106-146` — generic `vu.mkUpdateScript` (prefetches binary;
  writes sidecar at `~:144-145`; add **gated** grep step). `:27` version helper.
- `overlays/claude-code-sources.json` — sidecar shape `{version, <system>:{url,hash}}`.
- `config/update-matrix.nix:78` — `claude-code = {flags = "--use-update-script";}`.

**Checks + registration:**

- `checks/cache-hit-parity.nix:172-195` — drift-check template (eval-computes the
  delta, string-interpolates into a `runCommand`; loud `exit 1`).
- `flake.nix:202-213` — checks registration (`import ./checks/X.nix {inherit lib
pkgs self;}` then `// X`). `flake.nix:523-537` — `apps.*` (only
  `generate-update-ninja`).
- `checks/module-eval.nix` — `:328-344` HM effortLevel test; `:389-403` devenv
  gap-write test; `:475-487` copilot activation-text test; `:721-737` kiro
  defaultModel activation test. Harness: `mkTest`, `evalHm`/`evalDevenv`.

**Options + projections:**

- `packages/claude-code/lib/mkClaude.nix` — options `:22-167` (`settings`
  `:44-51` → convert to submodule); HM projection `:199-284` (`inherit settings`
  `:237` → null-filter; add reconciler); devenv `:287-396` (gap write `:353-355`).
- `packages/kiro-cli/lib/mkKiro.nix` — settings submodule `:68-113`
  (`freeformType` `:70`, `defaultModel` `:76-80` → soft-enum, `enableThinking`
  `:81-85` unchanged); `kiroSettingsMerge` `:373-393`; devenv write `:553-556`.
- `packages/copilot-cli/lib/mkCopilot.nix` — `settings` freeform `:59-63`;
  `copilotSettingsMerge` `:318-337`; HM `configDir` `.copilot` `:112-116`.
- `lib/ai/sharedOptions.nix:15-170` — 11 normalized options, **no** settings/model.
- `lib/ai/hm-helpers.nix:142-161` — `mkSettingsActivationScript` (dead; generalize
  - adopt). `lib/ai/ai-common.nix:228` `flattenDotKeys`, `:247` `filterNulls`.

**Staleness:**

- `dev/tasks/generate.nix` + `devenv.nix:301-304` — devenv task registration
  (add `check:model-staleness`).
- Kiro: `kiro-cli chat --list-models -f json` (net+auth; `auto`-only = stub).
- Claude offline source: `grep -aoE 'firstParty:"claude-[a-z0-9-]+"' $BIN | sort -u`.

**IFD canon:** `.claude/rules/overlays.md` § IFD Patterns;
`dev/fragments/overlays/ifd-patterns.md`; commit `f277053`;
`.claude/rules/nix-standards.md` § Flake Source Visibility (`git add` rule).

---

## 11. Suggested commit decomposition (for the plan session)

Atomic, each independently `nix flake check`-green:

1. `docs(ai): drop unimplemented normalized ai.settings; models are per-CLI` (WS5).
2. `refactor(ai): route copilot+kiro settings merge through shared helper` (WS4).
3. `feat(claude-code): extract launch-effort pins + effort levels to committed sidecar` (WS1 #1-4: extractor, mkUpdateScript, committed JSON, drift check).
4. `feat(claude-code): typed effortLevel + model settings submodule` (WS1 #3 / WS2 Claude; null-filter).
5. `feat(claude-code): reconcile unpinLaunchEffort into ~/.claude.json at activation` (WS1 #5, via shared helper).
6. `feat(kiro-cli): soft-enum model hint for defaultModel` (WS2 Kiro).
7. `feat(checks): claude model staleness flake check + check:model-staleness devenv task` (WS3).

(Use the repo's stack skills — `/stack-plan` etc. — per AGENTS.md "Skill
Routing"; do not hand-run git-branchless.)

---

## 12. Appendix — re-runnable forensics

```bash
BIN=$(nix build .#claude-code --no-link --print-out-paths)/bin/claude
grep -aoE 'unpin[A-Za-z0-9]+LaunchEffort' "$BIN" | sort -u          # pin keys (auto-expanding)
grep -aoF 'effortLevel:y.enum(["low","medium","high","xhigh"])' "$BIN"  # the 4-value validator (count must == 1)
grep -aoE 'firstParty:"claude-[a-z0-9-]+"' "$BIN" | sort -u         # Claude model registry (staleness source; noisy/deprecated)
# Kiro (needs AWS auth+network; auto-only output == offline stub, skip):
kiro-cli chat --list-models -f json
# ripgrep is mangled here — always: RIPGREP_CONFIG_PATH=/dev/null rg --no-config …
```

**Effort facts:** persisted levels `low medium high xhigh` (enum), `max`
session-only; Opus 4.8 default `high`, 4.7 default `xhigh`; resolver clamps both
`max→high` and `xhigh→high` per capability; `CLAUDE_CODE_EFFORT_LEVEL` =
highest-precedence input (hard-locks `/effort`); `CLAUDE_EFFORT` =
Claude-emitted output (ignore as input).

**Related memories:** `project_claude_effort_pin_state` (canonical fact-store),
`feedback_hm_activation_exit`, `feedback_no_nix_antipatterns`,
`feedback_content_separation`, `feedback_use_devenv_tasks`,
`feedback_project_settings_location`, `project_ai_passthrough_gaps`,
`project_mcp_proxy_kiro2_auth_gap`, `reference_bun_binary_patching`.
