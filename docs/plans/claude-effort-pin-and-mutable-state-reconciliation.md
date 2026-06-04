# Handoff — Declarative Claude effort level, and the broader "CLI mutable-state vs. HM-immutable-config" gap

> **⚠️ SUPERSEDED (2026-06-01)** by
> `docs/plans/typed-model-and-thinking-config-convergence.md`, which merges this
> doc with `per-cli-model-and-thinking-config.md`, folds in five-agent binary
> forensics, and resolves all open questions (HM-only parity, per-key
> `unpinLaunchEffort`, Track B collapse). Kept for history. Build from the
> converged doc.

> **Status:** Design validated, IFD-reviewed, **not yet implemented.** This
> doc is self-contained: a fresh session should be able to (a) implement the
> Claude effort-pin feature and (b) run a gap analysis across the other CLIs
> (Kiro, Copilot) **without re-deriving anything below.**
>
> **Origin session date:** 2026-06-01. Active Claude Code version while
> diagnosing: **2.1.159**. Repo: `nix-agentic-tools` (factory architecture
> branch `refactor/ai-factory-architecture`).
>
> **Do NOT touch nixos-config** — `effortLevel = "xhigh"` is already set there.
> This work is entirely in `nix-agentic-tools`.

---

## 0. START HERE (for the new session)

Two tracks. They share Part 3's mechanism.

- **Track A — implement** the Claude effort-pin reconciliation (Parts 2–3).
  Concrete, ready to build. Includes the typed dynamic-options design.
- **Track B — gap analysis** (Part 4): inventory, for **each** AI CLI
  (Claude, Copilot, Kiro), where the tool keeps **mutable runtime state** that
  collides with home-manager's **immutable store-symlink config**, and decide
  whether the Part 3 pattern generalizes (it largely already exists — see
  §4.2). The effort pin is just the first concrete instance of a general class.

Read Parts 1–3 once, then pick a track.

---

## 1. The problem and the mechanism (so you never re-diagnose this)

### 1.1 Symptom

`claude` launches showing **`high` effort** even though
`~/.claude/settings.json` (HM-managed) contains `"effortLevel": "xhigh"`.
`/effort xhigh` fails with:

```
Failed to set effort level: Failed to read raw settings from
~/.claude/settings.json: EACCES: permission denied, open
'/nix/store/...-home-manager-files/.claude/settings.json'
```

### 1.2 Two-part on-disk state model

Effort resolution depends on **two** files, only one of which HM controls:

| State                                                 | File                      | Owner                                                                    | HM-managed?                           |
| ----------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------ | ------------------------------------- |
| **Desired level** `effortLevel`                       | `~/.claude/settings.json` | declarative                                                              | **yes** — `0444` `/nix/store` symlink |
| **Launch-pin ack** `unpinOpus<NN>LaunchEffort` (bool) | `~/.claude.json`          | tool runtime state (also holds OAuth tokens, counters, per-project data) | **no** — mutable                      |

`opus48LaunchSeenCount` in `~/.claude.json` is a **separate** banner counter,
NOT the effort gate. Don't be misled by it.

### 1.3 The resolver (decoded from the 2.1.159 binary)

Binary: `/nix/store/<hash>-claude-code-2.1.159/bin/claude` (a Bun single-exec;
the bundled JS is greppable with `grep -aoE` over byte windows — `ugrep`/the
default alias chokes on `.{0,N}` windows on a 240 MB file, so use a small
Python byte-search instead). Relevant functions, deminified:

```js
function getEnvEffort() {
  // GkH
  let v = process.env.CLAUDE_CODE_EFFORT_LEVEL;
  return v?.toLowerCase() === "unset" || v?.toLowerCase() === "auto"
    ? null
    : parse(v);
}
function launchPinActive(model) {
  // TkH  — ONLY these two ids
  let id = normalize(model);
  if (id.includes("opus-4-7")) return !state.unpinOpus47LaunchEffort;
  if (id.includes("opus-4-8")) return !state.unpinOpus48LaunchEffort;
  return false;
}
function launchDefaultEffort(model) {
  // F48
  if (id === "claude-opus-4-8") return "high";
  if (id === "claude-opus-4-7") return "xhigh";
  return "high";
}
function unpinAll() {
  // lI  — what /effort triggers
  state.unpinOpus47LaunchEffort = true;
  state.unpinOpus48LaunchEffort = true; // written to ~/.claude.json
}
function resolveEffort(model, configured) {
  // Xo(H,$)
  if (!supportsEffort(model)) return;
  let pinned = launchPinActive(model); // q
  let launchDefault = launchDefaultEffort(model); // K
  let env = getEnvEffort(); // _
  if (env === null) return pinned ? launchDefault : undefined; // no env: pinned→high else configured
  let z =
    env ?? (pinned ? launchDefault : undefined) ?? configured ?? launchDefault;
  //      ^ env non-null ⇒ z = env. ENV WINS over pin, configured, default.
  if (z === "xhigh" && !supportsXhigh(model)) return "high"; // capability clamp only
  return z;
}
```

**Consequences (all confirmed):**

1. **Precedence:** `CLAUDE_CODE_EFFORT_LEVEL` (env) **beats everything** —
   launch-pin, configured `effortLevel`, and model default — subject only to a
   capability clamp (`xhigh`→`high` if the model can't do xhigh; Opus 4.8 can).
2. **Launch-pin:** for a newly-shipped model, effort is forced to that model's
   launch default (`high` for 4.8, `xhigh` for 4.7) until
   `unpinOpus<NN>LaunchEffort` is `true`. Only `opus-4-7`/`opus-4-8` are pinned
   today; the **full pin set is exactly the `unpin\w+LaunchEffort` keys in the
   binary** (verified: `unpinOpus47LaunchEffort`, `unpinOpus48LaunchEffort`).
3. **Valid effort levels** (also greppable): `low medium high xhigh max`
   (+ `ultracode`, a session-only Claude Code setting, not a model level).

### 1.4 Why `effortLevel="xhigh"` silently loses — the structural conflict

`/effort` does a **read-modify-WRITE of the entire `settings.json`** (it
rewrites/reorders every key) **and** sets the unpin flag in `~/.claude.json` in
the **same transaction**. With `settings.json` a `0444` store symlink the write
`EACCES`es → the whole transaction aborts → the unpin flag is **never written**
→ pinned to `high` forever. A long-running session also caches the symlink's
realpath (the store path) at launch, so even swapping in a writable file
mid-session, the first retry still hits the cached store path.

**Root insight (this is the general gap — see Part 4):** Claude treats
`settings.json` as a file it **owns and rewrites**; HM treats it as **immutable
generated output**. Any tool setting whose _persistence path_ is the
HM-managed file collides.

### 1.5 Red herring: `CLAUDE_EFFORT`

A `CLAUDE_EFFORT=<level>` env var appears in shells spawned by Claude. It is
**emitted by Claude** to child processes reflecting the _live_ level — an
**output, not an input**. The real input override is `CLAUDE_CODE_EFFORT_LEVEL`.
Don't confuse them.

### 1.6 Current state of THIS machine + probe artifacts (local, ephemeral)

During diagnosis we manually ran `/effort xhigh` against a temporarily-writable
copy of `settings.json`, which set `unpinOpus47LaunchEffort` and
`unpinOpus48LaunchEffort` to **`true`** in `~/.claude.json` (they persist) and
then **restored** the store symlink. So **this machine already shows xhigh** via
the manual unpin. To reproduce the _broken_ state for testing, clear those two
flags in `~/.claude.json`. Raw backups + a secret-redacted fingerprint live
under `/tmp/claude-effort-probe/` (this machine only; `.before/.after`,
`settings.symlink-target`). They are disposable.

---

## 2. Options considered, and the decision

| Opt   | Approach                                                                                                                                            | Verdict                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **C** | `CLAUDE_CODE_EFFORT_LEVEL=<x>` env var (HM `home.sessionVariables` + devenv `env.*`), auto-mirrored from `settings.effortLevel`                     | **Rejected** for Claude. It works, is treadmill-free, sidesteps the EACCES entirely (Claude never writes), and beats the pin for _all_ models. **But** the env var is a **HARD LOCK** — when set, `/effort` is disabled ("Not applied: CLAUDE_CODE_EFFORT_LEVEL=… overrides effort this session"), so no per-session `max`/`ultracode` without `unset`. User wants `/effort` to keep working. **Keep C in mind for Track B** — for a different CLI the env-lock trade-off may be acceptable/ideal. |
| **A** | Keep `effortLevel="xhigh"` (soft default, `/effort` still works) **+** reconcile the `unpin…LaunchEffort` flags into `~/.claude.json` declaratively | **CHOSEN.** See Part 3.                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| **B** | Make `settings.json` writable (`mkOutOfStoreSymlink`/activation copy) so `/effort` persists natively                                                | **Rejected.** Claude then mutates/reorders the file → drifts from the Nix source → defeats declarative repeatability.                                                                                                                                                                                                                                                                                                                                                                              |

---

## 3. The chosen design (Track A) — IFD-safe sidecar reconciliation

Mirrors the repo's **`*-sources.json` sidecar idiom** (e.g.
`overlays/claude-code-sources.json`), NOT the instruction-file pipeline (those
are gitignored live symlinks — a different precedent). The setting stays
declarative; a small activation step reconciles the tool's mutable state so the
setting is actually honored.

### 3.1 ⚠️ THE INVIOLABLE IFD RULE (read first)

> **Eval reads ONLY the committed `overlays/launch-effort-pins.json`.**
> Never let any eval-time expression (`builtins.readFile`/`fromJSON`/`import`)
> touch the **output of the grep `runCommand`** (e.g.
> `"${pkgs.claude-code.passthru.launchEffortPins}"`). Doing so forces Nix to
> **build** the grep derivation (which realizes the claude-code binary) during
> evaluation = **IFD** = the cold-CI `path '…-source.drv' is not valid`
> failure class this repo eliminated in commit **`f277053`** ("eliminate IFD
> from version computation"). The grep output is consumed **only by
> `nix build`** — the generator (writes the committed JSON) and the drift check
> (diffs against it). See `.claude/rules/overlays.md` § IFD Patterns and
> `dev/fragments/overlays/ifd-patterns.md`.

Why this is safe: `fromJSON (readFile ./committed.json)` of a **source path** is
pure (no IFD). The repo already relies on this in 4 places
(`overlays/claude-code.nix:31`, `overlays/copilot-cli.nix:37`,
`overlays/kiro-cli.nix:19`, `config/generate-update-ninja.nix:8`). Build-vs-eval
split is real: CI `build` job = `nix-fast-build .#packages`; CI `test` job =
`nix flake check` (eval-only, runs `checks.*`). A _new_ IFD breaks the `test`
job on a cold runner.

### 3.2 The five pieces (with confirmed hook points)

1. **Extractor (pure `runCommand`)** — `passthru.launchEffortPins` on the
   claude-code derivation in **`overlays/claude-code.nix`** (next to
   `passthru.updateScript`, ~line 55). Greps the built binary:

   ```nix
   passthru.launchEffortPins = ourPkgs.runCommandLocal "claude-launch-effort-pins" { } ''
     ${ourPkgs.gnugrep}/bin/grep -aoE 'unpin[A-Za-z0-9]+LaunchEffort' \
       ${placeholder-or-finalAttrs-ref}/bin/claude \
       | ${ourPkgs.coreutils}/bin/sort -u \
       | ${ourPkgs.jq}/bin/jq -R . | ${ourPkgs.jq}/bin/jq -s . > $out
   '';
   ```

   (Resolve the self-reference to `$out/bin/claude` via `finalAttrs`/`passthru`
   wiring; the base package installs the pre-built binary as `$out/bin/claude`
   per `overlays/claude-code.nix`.) **Output is `nix build`-only. Never
   eval-read.**

2. **Generator (rides the existing updateScript — this is the key move that
   kills the "CI codegen pain")** — extend `vu.mkUpdateScript`
   (**`overlays/lib.nix:106-146`**), the same shell that already prefetches the
   binary and writes the committed `claude-code-sources.json`. Add one step:
   grep the just-prefetched binary and write
   **`overlays/launch-effort-pins.json`** with `jq`. Both sidecars then land
   **atomically in the same `update/claude-code` PR**. **Reason this matters:**
   if pin-regen were a _separate_ step, the update PR would bump the binary
   (possibly adding `unpinOpus49LaunchEffort`) but leave the pin JSON stale →
   the drift check (#4) would fail that very PR and block auto-merge. Atomic
   regen avoids that; the drift check then only fires on genuinely unhandled
   flags (e.g. a manual bump that bypassed the updateScript).
   - Matrix entry already exists: `config/update-matrix.nix:78`
     (`claude-code = { flags = "--use-update-script"; }`).

3. **Committed SSOT** — `overlays/launch-effort-pins.json`, a JSON **array** of
   key names, e.g. `["unpinOpus47LaunchEffort","unpinOpus48LaunchEffort"]`.
   Read at eval **only** via `builtins.fromJSON (builtins.readFile ./...)`.
   **`git add` it** (flake check can't see untracked files —
   `.claude/rules/nix-standards.md` § Flake Source Visibility).

4. **Drift check (pure)** — new **`checks/launch-effort-pins.nix`**, registered
   in **`flake.nix:202-212`** beside `cacheHitParityCheck`. Template:
   **`checks/cache-hit-parity.nix:172-195`**. A `pkgs.runCommand` that
   `nix build`s the extractor (#1) output and diffs it against
   `fromJSON (readFile ../overlays/launch-effort-pins.json)`; `exit 1` with a
   **loud** message on mismatch. Also assert the grep is **non-empty** so a
   future Anthropic _rename_ of the mechanism fails loudly instead of silently
   applying nothing.

5. **Activation consumer (HM)** — in the HM projection `lib.mkMerge` of
   **`packages/claude-code/lib/mkClaude.nix`** (`hm.config` block, **lines
   ~199-284**). It's a near-clone of the existing reusable merger
   **`lib/ai/hm-helpers.nix:142-161` `mkSettingsActivationScript`** (already
   does the `jq -s '.[0] * .[1]'` merge-into-mutable-JSON), used by
   **`packages/copilot-cli/lib/mkCopilot.nix:318` `copilotSettingsMerge`** and
   **`packages/kiro-cli/lib/mkKiro.nix:373` `kiroSettingsMerge`**. Set each
   pinned key `= true` and jq-merge into `~/.claude.json`. Constraints:
   absolute store paths (`${pkgs.jq}/bin/jq`, `${pkgs.coreutils}/bin/...` —
   `.claude/rules/nix-standards.md` § Shell Wrappers); **never `exit`** in an
   activation block (memory `feedback_hm_activation_exit`); write atomically
   (temp + `mv`); handle `~/.claude.json` absent (treat as `{}`); idempotent.
   **Log how many keys it applied** (so an "applied 0" is visible if the SSOT
   ever empties).

### 3.3 Typed dynamic options (Track A #2 — user opted in)

The committed JSON is the eval-pure bridge that lets the **same data** drive
**typed module options** without IFD. In `packages/claude-code/lib/mkClaude.nix`
(options block ~line 22-166, alongside `settings` at ~line 44):

```nix
# eval-pure: ./ path resolves to a committed SOURCE file, NOT a derivation output.
# Path from packages/claude-code/lib/ to overlays/ is ../../../overlays/...
let
  launchPinKeys = builtins.fromJSON
    (builtins.readFile ../../../overlays/launch-effort-pins.json);
in {
  # ... existing options ...
  unpinLaunchEffort = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = lib.genAttrs launchPinKeys (_: true);   # dynamic shape from the data file
    description = ''
      Per-model "acknowledge launch-default effort" flags merged into
      ~/.claude.json so the declarative `settings.effortLevel` is honored
      instead of the model's launch-default pin. Keys are auto-derived from
      the packaged claude-code binary (overlays/launch-effort-pins.json);
      set a key false to leave that model pinned.
    '';
  };
}
```

The **activation consumer (#5) reads `cfg.unpinLaunchEffort`**, not the raw
JSON, so options and applier stay in lockstep. This directly answers the design
question "`runCommand` → dynamic options to match?": **yes, via the committed
JSON** (`runCommand` _produces/validates_ it at build time; the option
_declares_ off the committed source file at eval time). A simpler alternative if
per-key granularity isn't wanted: a single `unpinLaunchEffort = mkOption bool`
master toggle that applies all `launchPinKeys` when true.

### 3.4 Config parity (HM vs devenv) — a real open decision

- The **effort _setting_** already has parity: `settings.effortLevel` gap-writes
  to `.claude/settings.json` on **both** HM and devenv sides (verified in
  `checks/module-eval.nix`).
- The **unpin _reconciliation_** (the `~/.claude.json` merge) is **HM-only** as
  designed, because `~/.claude.json` is **global user state**, not repo-scoped.
- **Tension with AGENTS.md** ("if configurable in HM it must be configurable in
  devenv; gaps are bugs"): a **devenv-only** user (via `mkAgenticShell`, no HM)
  would still be pinned, since nothing reconciles their `~/.claude.json`.
- **Decision for the gap session:** (a) add a devenv `enterShell` reconciliation
  (mutates global state from a project shell — invasive but closes the gap),
  (b) document this as a deliberate parity exception (runtime-state
  reconciliation of global state is inherently not a repo-scoped config
  surface), or (c) reconsider env-var Option C for the devenv path only. Lean:
  document the exception for HM-primary, but **decide explicitly**.

### 3.5 Build sequence

1. Add `overlays/launch-effort-pins.json` (the two current keys) + `git add`.
2. Add extractor `passthru.launchEffortPins` (`overlays/claude-code.nix`).
3. Extend `mkUpdateScript` to regenerate the JSON (`overlays/lib.nix`).
4. Add drift check `checks/launch-effort-pins.nix` + register (`flake.nix`) +
   `git add`.
5. Add typed option `unpinLaunchEffort` + activation consumer
   (`mkClaude.nix`); reuse `mkSettingsActivationScript`.
6. `treefmt` changed files; `nix flake check` (cold, to catch any IFD);
   `nix build .#checks.<system>.launch-effort-pins`.
7. Manual verify: clear the two flags in `~/.claude.json`, `home-manager
switch`, launch `claude` → header shows `xhigh`, and `/effort max` still
   works for a session.

### 3.6 Verification checklist

- [ ] `nix flake check` passes **on a cold eval** (no IFD regression).
- [ ] Drift check fails loudly when `launch-effort-pins.json` omits a key the
      binary has (simulate by deleting a key).
- [ ] After activation, `jq '.unpinOpus48LaunchEffort' ~/.claude.json` → `true`.
- [ ] Fresh `claude` (flags cleared first) shows `xhigh`; `/effort` still usable.
- [ ] An `update/claude-code` PR regenerates **both** sidecars together.

---

## 4. Gap analysis brief (Track B) — generalize across CLIs

### 4.1 The general class

**"Tool-owned mutable runtime state that shadows or blocks HM-immutable
declarative config."** The effort pin is one instance. The pattern: a CLI keeps
a writable state file it read-modify-writes (Claude `~/.claude.json`), and
either (a) it writes the _same_ file HM manages (→ EACCES), or (b) a flag in the
mutable file **shadows** the declarative setting until the tool itself flips it.

### 4.2 What already exists (don't reinvent)

The repo **already** has a cross-CLI "merge declarative values into a tool's
mutable JSON at activation" mechanism:

- `lib/ai/hm-helpers.nix:142-161` — `mkSettingsActivationScript` (generic
  `jq -s '.[0] * .[1]'` merge into a mutable JSON file).
- `packages/copilot-cli/lib/mkCopilot.nix:318` — `copilotSettingsMerge`.
- `packages/kiro-cli/lib/mkKiro.nix:373` — `kiroSettingsMerge`.

So the activation-merge half of Part 3 is **already a shared pattern**. The
_new_ half is the **package-extracted data file** (the pin list) + **drift
check**. The generalization question is whether other CLIs have analogous
package-derived reconciliation data.

### 4.3 Per-CLI investigation checklist

For **each** of Claude, Copilot, Kiro (and any future CLI):

1. **Inventory state files.** Which paths does the tool _write at runtime_
   (mutable, tool-owned) vs which does HM manage (store symlink)? For Claude:
   mutable `~/.claude.json` vs managed `~/.claude/settings.json`. Find the
   equivalents for Copilot/Kiro (grep their binaries/configs; check what
   `mkCopilot`/`mkKiro` already merge and why).
2. **Find shadowing flags.** Are there "first-run / migration / launch-default /
   onboarding" booleans in the mutable state that **override** declarative
   settings (like `unpinOpus<NN>LaunchEffort`)? Grep each tool's binary for
   `unpin`, `Launch`, `Migration`, `migrationVersion`, `Onboarding`,
   `firstRun`, `Default`, `effort`/`reasoning`/`thinking`.
3. **Find EACCES-class writes.** Does the tool RMW an HM-managed file at
   runtime (settings persistence, `/`-command state)? Those break under a
   `0444` symlink. Reproduce by attempting the tool's "save setting" path.
4. **Effort/thinking analog.** Does Copilot or Kiro have a reasoning/effort/
   thinking-depth setting, and does it have a launch-pin-style gate?
   (Kiro context: see memory `project_mcp_proxy_kiro2_auth_gap`,
   `project_ai_passthrough_gaps`. Kiro 2.0 is a moving target.)
5. **Pick the fix per tool.** Three tools in the toolbox, choose per-tool:
   - **Env-var override** (Option C) — if the tool respects an env var that
     beats its state (cleanest, treadmill-free; cost = may hard-lock the
     interactive command). Best when the tool _reads_ an env override.
   - **Activation merge** (Part 3 / existing `mkSettingsActivationScript`) —
     when the gate is a flag in a mutable file the tool checks but we can
     pre-set. Keeps interactive commands working.
   - **Writable config** (Option B) — last resort; breaks declarative purity.
6. **Parity** — for whichever fix, resolve the HM-vs-devenv question from §3.4
   for that tool too.

### 4.4 Deliverable for Track B

A gap matrix: rows = {Claude, Copilot, Kiro}; columns = {mutable state file,
HM-managed file, shadowing flags found, EACCES-class writes, effort/thinking
analog, recommended fix, HM/devenv parity decision}. Then decide whether to
build **one generalized abstraction** (package-extracted reconciliation data +
shared activation merge + shared drift check, parameterized per CLI) vs.
per-CLI one-offs. The shared `mkSettingsActivationScript` already argues for
generalization.

---

## 5. Decisions locked / open

**Locked:**

- Claude effort uses **Option A** (activation reconciliation), not env-var lock.
- Data flows through a **committed sidecar JSON** (`*-sources.json` idiom), not
  the gitignored instruction-file pipeline.
- **Auto-generate via the existing `mkUpdateScript`**, atomically with
  `claude-code-sources.json` — no separate codegen step, no intra-PR drift.
- **Typed dynamic options** via `importJSON`/`fromJSON` of the committed file
  (user opted into #2).
- **The inviolable IFD rule** (§3.1).
- **nixos-config is out of scope** (`effortLevel="xhigh"` already set there).

**Open (decide in the new session):**

- §3.4 HM-vs-devenv parity for the reconciliation (enterShell? document
  exception? env-var for devenv?).
- Master-toggle vs per-key `attrsOf bool` for `unpinLaunchEffort`.
- Track B: generalize to one abstraction vs per-CLI fixes.

---

## 6. Appendix — file:line index & commands

**Repo hooks:**

- `overlays/claude-code.nix` — base package; `:31` `fromJSON+readFile` sidecar
  (the pure idiom to copy); `~:55` `passthru.updateScript` (extractor +
  generator neighbor).
- `overlays/claude-code-sources.json` — the model committed sidecar.
- `overlays/lib.nix:106-146` — `vu.mkUpdateScript` (extend for generator).
- `config/update-matrix.nix:78` — `claude-code` matrix entry.
- `checks/cache-hit-parity.nix:172-195` — drift-check template.
- `flake.nix:202-212` — checks registration.
- `packages/claude-code/lib/mkClaude.nix` — options ~`22-166` (add typed
  option near `settings` at `~44`); HM projection `~199-284` (activation
  consumer); devenv projection `~287-395`.
- `lib/ai/hm-helpers.nix:142-161` — `mkSettingsActivationScript` (reuse).
- `packages/copilot-cli/lib/mkCopilot.nix:318`,
  `packages/kiro-cli/lib/mkKiro.nix:373` — existing activation merges.
- `checks/module-eval.nix` — existing `settings.effortLevel` parity tests
  (extend with env/unpin assertions).
- IFD canon: `.claude/rules/overlays.md` § IFD Patterns;
  `dev/fragments/overlays/ifd-patterns.md`; resolution commit `f277053`.

**Binary forensics (re-runnable):**

```bash
BIN=$(nix build .#claude-code --no-link --print-out-paths)/bin/claude
# all launch-pin keys (the canonical signal):
grep -aoE 'unpin[A-Za-z0-9]+LaunchEffort' "$BIN" | sort -u
# resolver windows (python; ugrep chokes on .{0,N} over 240MB):
python3 - "$BIN" <<'PY'
import sys; d=open(sys.argv[1],'rb').read()
for n in (b'function Xo(',b'function GkH(',b'function TkH(',b'function F48('):
    i=d.find(n);  print(d[i:i+260].decode('latin-1') if i>=0 else f'{n} not found','\n')
PY
```

**Effort facts:** levels `low medium high xhigh max`; Opus 4.8 default `high`,
4.7 default `xhigh`; `CLAUDE_CODE_EFFORT_LEVEL` = highest-precedence input
(hard-locks `/effort`); `CLAUDE_EFFORT` = Claude-emitted output (ignore as
input). Docs: code.claude.com/docs/en/model-config § "Adjust effort level".

**Related memories:** `project_claude_effort_pin_state` (the canonical
fact-store for this work), `feedback_hm_activation_exit`,
`feedback_no_nix_antipatterns`, `feedback_project_settings_location`,
`project_ai_passthrough_gaps`, `project_mcp_proxy_kiro2_auth_gap`,
`reference_bun_binary_patching`.
