# Handoff — Per-CLI model + thinking-level config surface, and the phantom `ai.settings` normalization gap

> **⚠️ SUPERSEDED (2026-06-01)** by
> `docs/plans/typed-model-and-thinking-config-convergence.md`, which merges this
> doc with `claude-effort-pin-and-mutable-state-reconciliation.md` and resolves
> the model-typing fork (soft-enum hint + hand-curated lists + per-CLI staleness
> checks; models are NOT derivation-extractable for any CLI). Kept for history.
> Build from the converged doc.

> **Status:** Research complete, **nothing edited yet.** Self-contained: a fresh
> session should be able to (a) scrub the documented-but-unimplemented
> `ai.settings` normalized-settings concept and (b) fold the model/thinking
> findings into the sibling auto-detect/effort-pin handoff **without re-deriving
> anything below.**
>
> **Origin session date:** 2026-06-01. Repo `nix-agentic-tools`, branch
> `refactor/ai-factory-architecture`. **nixos-config is out of scope.**
>
> **Sibling handoff (read it):**
> `docs/plans/claude-effort-pin-and-mutable-state-reconciliation.md`. That doc
> owns the **Claude** effort-pin reconciliation (Track A) + a cross-CLI
> mutable-state gap analysis (Track B, §4). **This doc pre-fills the
> Kiro/Copilot rows of that gap analysis's §4.4 matrix and answers its §4.3 step
> 4 ("effort/thinking analog") for Kiro and Copilot.** The two are meant to
> merge.

---

## 0. START HERE — the two deliverables

1. **Doc scrub (concrete, ready):** delete the normalized `ai.settings` /
   `ai.settings.model` / `ai.settings.telemetry` concept from docs. It is
   **documented in 9 places, implemented in 0** (verified — see §3). The design
   decision is **locked: do not implement it** (§2). So the only correct action
   is to remove/correct the docs that promise it. One commit.

2. **Fold-in (coordination):** the user has a sibling session building
   **auto-detection of available models + the extra thinking/effort level**,
   currently **Claude-only** (it extracts pin data from the packaged `claude`
   binary — sibling doc §3.2/§5). This session's findings extend the conceptual
   model to **Kiro and Copilot**, and surface a hard constraint that auto-detect
   must respect: **model identifiers are ecosystem-specific; never normalize
   them into one shared key** (§2). See §4 for exactly how to fold in.

Read §1–§2 once, then pick the deliverable.

---

## 1. The research — per-CLI model + thinking config surface (so you never re-derive it)

All three CLIs are built by the factory-of-factories. Each `mkXxx.nix` returns a
backend-agnostic app record; `hmTransform`/`devenvTransform` project it to HM
and devenv module functions. Per-CLI settings are a typed submodule with a
`freeformType` escape hatch for unknown keys.

### 1.1 Kiro — `packages/kiro-cli/lib/mkKiro.nix` (personally verified line refs)

Settings submodule at **`mkKiro.nix:68–113`**. Two typed knobs under `chat`:

| Option                                 | Path / line                  | Type          | Notes                                                               |
| -------------------------------------- | ---------------------------- | ------------- | ------------------------------------------------------------------- |
| `ai.kiro.settings.chat.defaultModel`   | `mkKiro.nix:76–80`           | `nullOr str`  | "Default chat model." Free string.                                  |
| `ai.kiro.settings.chat.enableThinking` | `mkKiro.nix:81–85`           | `nullOr bool` | "Enable thinking/reasoning mode." **Boolean on/off — NOT a level.** |
| `ai.kiro.settings.telemetry.enabled`   | `mkKiro.nix:91–100`          | `nullOr bool` | telemetry toggle                                                    |
| (any other key)                        | freeformType `mkKiro.nix:69` | json          | passes through untyped                                              |

- **Flattening:** `cli.json` uses flat dot-keys (`"chat.defaultModel"`), not
  nested JSON. `aiCommon.flattenDotKeys` (`lib/ai/ai-common.nix:228`) turns
  `settings.chat.defaultModel = "x"` → `{"chat.defaultModel":"x"}`. So Nix
  authors write clean nested attrs; the file gets flat keys.
- **HM write:** activation-time `jq -s '.[0] * .[1]'` merge into
  `~/.kiro/settings/cli.json` — **`kiroSettingsMerge` at `mkKiro.nix:370–393`**.
  Nix values win on conflict; user runtime keys survive. Gated on
  `filteredSettings != {}` (won't clobber an externally-managed cli.json if you
  only enabled Kiro for MCP fanout).
- **devenv write:** static write to `.kiro/settings/cli.json` —
  **`mkKiro.nix:553–556`** (no activation scripts in devenv; project-local, so
  no runtime-preservation concern).
- **`enableThinking` description literally says "thinking/reasoning mode"** — a
  binary. There is **no `thinkingLevel` / effort gradient** for Kiro, and
  (unlike Claude) **no launch-pin gate** in the option surface. If Kiro ever
  adds a level key to cli.json you can set it _today_ via freeform:
  `ai.kiro.settings.chat.<key> = ...`.

### 1.2 Copilot — `packages/copilot-cli/lib/mkCopilot.nix`

- Typed keys: **`model`, `theme`** (per `dev/references/config-parity.md`
  type-coverage table). **No reasoning/thinking/effort knob at all.**
- Existing activation merge `copilotSettingsMerge` at `mkCopilot.nix:318` (line
  cited by sibling doc §4.2; not re-verified this session).

### 1.3 Claude — `packages/claude-code/lib/mkClaude.nix`

- Model via upstream `programs.claude-code.settings.model`; effort via
  `settings.effortLevel`. **This is the CLI that actually has model-derived
  thinking-level capability** (`low medium high xhigh max`, + session-only
  `ultracode`). Opus 4.8 supports `xhigh`.
- The "auto-detect" the user mentioned lives here: the sibling session extracts
  per-model launch-effort-pin flags (`unpinOpus<NN>LaunchEffort`) **from the
  packaged binary** into `overlays/launch-effort-pins.json`, reconciled into
  `~/.claude.json` at activation. See sibling doc Parts 2–3.

### 1.4 `xhigh` is a Claude-Code harness concept, not a portable one

`xhigh` is the Claude Code `effortLevel` (Opus 4.8/4.7), set in
`~/.claude/settings.json`. It is **not** a Kiro or Copilot concept. Kiro's
reasoning is binary (`enableThinking`); Copilot has none. So "xhigh if Kiro
exposes it" → **Kiro does not expose it.** Don't try to map it across.

---

## 2. The locked decision — do NOT normalize `ai.settings.model` / `.telemetry`

**User's call, and it's correct.** A normalized `ai.settings.model` fanned out
at `mkDefault` to all CLIs would write **one string into three disjoint
namespaces**:

- Claude → Anthropic model ids
- Copilot → OpenAI/GPT (and others) ids
- Kiro → its own Bedrock-backed list

Any single value is valid for **at most one** ecosystem and silently wrong or
runtime-rejected for the rest. That's worse than no option — it _looks_ portable
but isn't. `telemetry` is no better: per the parity doc, Claude and Copilot are
"N/A (no upstream option)," so it maps to **only Kiro** — a "normalization" of
one is just a mislabeled per-CLI knob.

**Therefore:**

- The correct surface is the **per-CLI** `ai.<cli>.settings.*` (which already
  exists for all three — §1).
- The genuinely-portable surfaces **stay normalized** in
  `lib/ai/sharedOptions.nix` (`context`, `mcpServers`, `instructions`, `rules`,
  `rulesDir`, `lspServers`, `agents`, `agentsDir`, `environmentVariables`,
  `skills`, `skillsDir` — those _are_ the same content across ecosystems). **Do
  not touch those.** Only `model`/`telemetry` were wrongly promised as
  normalized.
- **Constraint for the auto-detect session:** model/thinking detection and
  options must be **per-ecosystem**, never a shared `model` key. This decision
  is the boundary condition for that work.

---

## 3. The gap artifact — phantom `ai.settings` in docs only

`ai.settings` is **declared in zero `.nix` files** and **tested nowhere**.
`lib/ai/sharedOptions.nix` (the top-level `options.ai` aggregator) declares the
11 normalized options listed in §2 but **no `settings`**. Confirmation greps
(run them again if you doubt it — note the gotcha in §6):

```
rg -n --no-config "ai\.settings" -g '*.nix' .   # → only docs-site .nix table strings, never an option decl
rg -n --no-config "settings = lib\.mkOption" lib/ai/sharedOptions.nix   # → no match
```

### 3.1 Every reference to scrub (9 files)

Verified with
`RIPGREP_CONFIG_PATH=/dev/null rg -n --no-config "ai\.settings" -g '!.git' -g '!**/memory/**' .`:

| File:line                                           | What it claims                                                   | Priority                                                                                                                                        |
| --------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `devshell/docs-site/pages/ai-mapping.md:64`         | `ai.settings.model = "claude-sonnet-4"; # mkDefault (1000)`      | **HIGH — published, user-facing**                                                                                                               |
| `devshell/docs-site/pages/home-manager-footer.md:8` | `ai.settings.model = "claude-sonnet-4";`                         | **HIGH — published, user-facing**                                                                                                               |
| `dev/fragments/ai-module/ai-module-fanout.md:84`    | `ai.settings.{model,telemetry}` — normalized settings            | **HIGH — always-loaded agent steering**                                                                                                         |
| `dev/fragments/hm-modules/module-conventions.md:30` | lists `ai.settings` among top-level options                      | **HIGH — agent steering**                                                                                                                       |
| `dev/references/config-parity.md:29,69,71,74`       | whole "Normalized Settings (ai.settings)" section + table        | reference                                                                                                                                       |
| `dev/docs/concepts/config-parity.md:24`             | settings row says `ai.settings`                                  | reference                                                                                                                                       |
| `dev/docs/concepts/unified-ai-module.md:55,63`      | `ai.settings.model = ...` + "sets each CLI's model at mkDefault" | reference                                                                                                                                       |
| `dev/docs/getting-started/home-manager.md:168`      | `# override ai.settings.model for Copilot`                       | getting-started                                                                                                                                 |
| `dev/notes/ai-transformer-design.md:23,241,1459`    | design exploration of the remap                                  | **leave as-is** (design notes; the rejected idea legitimately belongs in notes — optionally annotate "rejected: models are ecosystem-specific") |

### 3.2 Scrub plan (surgical)

- Remove the "Normalized Settings (ai.settings)" section + table row from both
  `config-parity.md` files; keep the **per-CLI `.settings` rows** (those are
  real). In the type-coverage tables the per-CLI Kiro/Copilot/Claude columns
  stay.
- In `ai-mapping.md` / `home-manager-footer.md` replace the `ai.settings.model`
  example with a per-CLI example (e.g. `ai.kiro.settings.chat.defaultModel` /
  `ai.copilot.settings.model` / `programs.claude-code.settings.model`), or drop
  the model line entirely if the page is about portable content.
- In the two fragments, remove `ai.settings` from the normalized-options list.
  Because fragments changed, **regenerate instruction files**:
  `devenv tasks run --mode before generate:instructions` (never hand-edit the
  generated `.claude/rules/*`, `.github/instructions/*`, `.kiro/steering/*`).
- `unified-ai-module.md` / `home-manager.md` getting-started: rewrite the model
  example as per-CLI.
- Leave `dev/notes/ai-transformer-design.md` (design archive). Optionally add a
  one-line "rejected — models are ecosystem-specific (see
  `docs/plans/per-cli-model-and-thinking-config.md`)".
- `treefmt` every changed file. `nix flake check` (the structural check
  validates cross-references). Per AGENTS.md change-propagation: grep the repo
  for `ai.settings` one more time before committing to confirm zero stragglers.

Commit shape:
`docs(ai): drop unimplemented normalized ai.settings; models are per-CLI`.

---

## 4. Fold-in with the sibling auto-detect / effort-pin handoff

Target: `docs/plans/claude-effort-pin-and-mutable-state-reconciliation.md`.

### 4.1 Pre-filled answer to that doc's §4.3 step 4 ("effort/thinking analog")

- **Kiro:** thinking analog = `chat.enableThinking` (**boolean, no level, no
  launch-pin gate** in the _option surface_). Model = `chat.defaultModel` (free
  str). **Caveat:** I inspected the **Nix option layer only**, not the
  `kiro-cli` **binary**. Steps 2–3 of §4.3 (grep the binary for
  `unpin/Migration/firstRun/reasoning/thinking/Default` shadowing flags + EACCES
  writes) are **still TODO**. Kiro 2.0 is a moving target (see memories
  `project_mcp_proxy_kiro2_auth_gap`, `project_ai_passthrough_gaps`).
- **Copilot:** no thinking/effort analog exists (typed keys are `model`, `theme`
  only). Binary forensics still TODO.
- **Claude:** owns the only real effort/thinking-level gate — the sibling's
  Track A.

### 4.2 Pre-filled §4.4 gap-matrix rows (model/thinking columns)

| CLI     | mutable state file          | HM reconcile mechanism                          | thinking/effort analog       | launch-pin gate?                           | model option                |
| ------- | --------------------------- | ----------------------------------------------- | ---------------------------- | ------------------------------------------ | --------------------------- |
| Claude  | `~/.claude.json` (global)   | activation merge (sibling Track A, new)         | `effortLevel` (low…max)      | **yes** `unpin…LaunchEffort`               | `settings.model` (upstream) |
| Kiro    | `~/.kiro/settings/cli.json` | `kiroSettingsMerge` jq merge (`mkKiro.nix:373`) | `chat.enableThinking` (bool) | none found (option layer); **binary TODO** | `chat.defaultModel`         |
| Copilot | (TODO confirm)              | `copilotSettingsMerge` (`mkCopilot.nix:318`)    | **none**                     | n/a                                        | `settings.model`            |

Note Kiro's cli.json is **tool-mutable + HM-merged (jq)**, not a `0444` store
symlink → **no EACCES-class collision** like Claude's. That's why Kiro already
"just works" for runtime model selection: the merge preserves a user's `/model`
choice across rebuilds.

### 4.3 The auto-detect generalization — and where it breaks

The user wants the sibling's "auto-detect available models / thinking level"
(today: extract from the packaged `claude` binary into a committed
`*-sources.json` sidecar) to extend to **Kiro models**. Key risks/constraints to
record for that session:

1. **Per-ecosystem only** (the §2 decision). No shared model key. Auto-detection
   produces a _per-CLI_ model list, never a unified one.
2. **Extraction source differs by CLI.** Claude's models/pins are **greppable
   from the packaged binary** (sibling §5, `overlays/claude-code-sources.json`).
   **Kiro's model list is backend-driven** (Bedrock/AWS manifest; the package is
   a fetched binary — see `.claude/rules/ai-clis.md`, `kiro-cli-sources.json`).
   So Kiro's "available models" likely **cannot be statically extracted from the
   binary** the way Claude's can — it may need a runtime probe (`kiro-cli`'s
   model picker / `/model`) or simply stay a hand-curated free string. **Open
   question — do not assume the Claude extraction idiom transfers to Kiro.**
3. **Thinking-level capability is Claude-only.** There is nothing to auto-detect
   for Kiro (binary toggle) or Copilot (absent). So the "extra thinking level"
   half of the auto-detect is Claude-scoped by nature, matching "other doc only
   Claude right now."

---

## 5. Open questions / decisions for the new session

- **Scrub vs. implement:** locked to scrub (don't implement `ai.settings`). If
  anyone reopens it, §2 is the rebuttal.
- **Kiro model auto-detect feasibility:** static binary extraction vs runtime
  probe vs hand-curated string. Needs the §4.2 binary forensics first.
- **Should `defaultModel` get value validation?** Currently free `str` (writes
  whatever you give it; Kiro rejects bad ids at runtime). A NixOS `enum` would
  need an auto-derived model list → blocked on the auto-detect feasibility
  above. Lean: leave it free `str` until/unless Kiro models become statically
  derivable.
- **Confirm the user's actual goal:** they wanted **Opus 4.8 as Kiro's
  default**. Unverified whether Kiro's `chat.defaultModel` accepts an Opus 4.8
  id or what the string is (repo examples use `"claude-sonnet-4"`). Confirm from
  Kiro's `/model` picker before recommending a concrete value.

---

## 6. Appendix — file:line index, gotchas, commands

**Personally verified this session:**

- `packages/kiro-cli/lib/mkKiro.nix:68–113` settings submodule; `:76–80`
  defaultModel; `:81–85` enableThinking; `:370–393` `kiroSettingsMerge` (HM jq
  merge); `:553–556` devenv static cli.json write.
- `lib/ai/ai-common.nix:228` `flattenDotKeys`.
- `lib/ai/sharedOptions.nix:15` `options.ai = {` — declares 11 normalized
  options, **no `settings`**.
- `checks/module-eval.nix:723–737` Kiro settings activation test (uses
  `settings.chat.defaultModel = "claude-sonnet-4"`); `:479` uses **per-CLI**
  `ai.copilot.settings.model` (confirms no normalized path is tested).
- `dev/references/config-parity.md:55–80` the (wrong) "Normalized Settings"
  section + type-coverage table.

**Inherited from sibling doc (not re-verified here):** `mkCopilot.nix:318`,
`mkClaude.nix` options ~`44`/HM ~`199–284`/devenv ~`287–395`,
`lib/ai/hm-helpers.nix:142–161` `mkSettingsActivationScript`,
`overlays/launch-effort-pins.json` + `overlays/claude-code.nix:31`.

**⚠ GOTCHA — ripgrep is mangled in this environment.** The user's
`RIPGREP_CONFIG_PATH` applies a replacement that silently rewrites matched
tokens (observed: `settings.model` and `defaultModel` rendered as `ln`/`n` in
output). **Always grep with `RIPGREP_CONFIG_PATH=/dev/null rg --no-config …`**
(or use `grep`) when searching for these identifiers, or you'll get garbage and
misread the repo. Plain `grep -rIn` also works but watch zsh glob expansion of
`--include=*.nix` (quote it).

**Re-confirm-the-gap commands:**

```bash
export RIPGREP_CONFIG_PATH=/dev/null
rg -n --no-config "ai\.settings" -g '!.git' -g '!**/memory/**' .     # the 9 doc hits
rg -n --no-config "ai\.settings" -g '*.nix' .                        # → zero option decls
rg -n --no-config "settings = lib\.mkOption" lib/ai/sharedOptions.nix # → no match
```

**Related memories:** `project_claude_effort_pin_state.md` (xhigh won't stick —
the Claude-side EACCES that motivated the sibling doc),
`project_ai_passthrough_gaps.md`, `project_mcp_proxy_kiro2_auth_gap.md`,
`feedback_use_devenv_tasks.md` (regenerate instructions via devenv tasks, not
manual build+cp).
