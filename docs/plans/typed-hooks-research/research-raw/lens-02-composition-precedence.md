# Hook Composition & Precedence: Claude Code and Kiro v3 (multi-source, script-concat, Nix merge)

## TL;DR (the load-bearing answers)

1. **Claude UNIONs, it does not override.** When several hooks match one event —
   whether from different `settings.json` sources (user / project / local /
   managed / plugin) OR from several matcher-blocks in one file OR from
   skill/agent frontmatter — Claude Code runs **all** of them, **in parallel**,
   and **de-duplicates identical handlers** (command hooks by `command`+`args`,
   HTTP hooks by `url`). Blocking is aggregated by the CLI as
   **most-restrictive-wins** (any `exit 2` / `decision:"block"` blocks;
   `deny > ask > allow`). Nothing needs to be concatenated in Nix — **emit each
   contributor as a separate array entry and let the CLI union them.**
   (Confirmed: `code.claude.com/docs/en/hooks`,
   `code.claude.com/docs/en/settings`, plus independent corroboration.)

2. **Kiro v3 also unions, at the JSON-entry level.** A single
   `.kiro/hooks/<name>.json` envelope with a `hooks:[…]` array fires every entry
   whose trigger/matcher matches — `autoMemory.nix` proves 3+ fire from one
   envelope (memory D30). Multiple **files** in `.kiro/hooks/` are read by a
   `read_dir` directory scan and all load, so the natural composition unit is
   _the file with a distinct name_ — which sidesteps the shebang problem
   entirely because Kiro hooks are JSON envelopes carrying `command` strings,
   never concatenated scripts.

3. **The shebang problem is a non-problem if you pick strategy (a).** You cannot
   concatenate two `#!/usr/bin/env bash` scripts. But neither CLI ever requires
   one-command-per-event: both accept an **array** of independent command
   entries and run them all. So the correct pattern is **(a) one array entry per
   contributing script + let the CLI union/aggregate**, produced mechanically by
   **(c) Nix `listOf` list-concatenation**. A **(b) generated dispatcher
   wrapper** is only needed in the hypothetical where a CLI restricts you to a
   single command per matcher — not the case for Claude or Kiro today — and it
   is strictly worse (you lose the CLI's parallelism and must re-implement
   exit-code aggregation yourself).

4. **There is a latent HM↔devenv schema mismatch to fix before typing.**
   `ai.claude.hooks` is `attrsOf lines` = **script bodies written to files**;
   the event→matcher→command **wiring** lives in the untyped
   `ai.claude.settings.hooks` JSON. On HM these are two orthogonal upstream
   options; on devenv the repo `//`-merges them into one option
   (`mkClaude.nix:507`), conflating two different shapes. The future typed
   design must separate "script file bodies" from "event wiring" and give devenv
   the same two-surface split HM has.

---

## 1. CLAUDE — composition & precedence

### 1a. Across `settings.json` sources — UNION, parallel, de-duped

**Confirmed behavior** (`code.claude.com/docs/en/hooks`, corroborated by
multiple independent write-ups):

- **Union, not override.** "All matching hooks run in parallel, and identical
  handlers are deduplicated automatically." Hooks from **user
  (`~/.claude/settings.json`), project (`.claude/settings.json`), local
  (`.claude/settings.local.json`), managed/enterprise, plugin
  `hooks/hooks.json`, and skill/agent frontmatter** are **combined**, then
  de-duplicated, then all run.
- **This is the documented exception to normal precedence.** The settings doc's
  precedence ladder (managed > CLI args > local > project > user) governs scalar
  keys — "if user sets `spinnerTipsEnabled=true` and project sets `false`,
  project wins." But **"Permission rules behave differently because they merge
  across scopes rather than override,"** and **"Arrays merge across settings
  sources."** Hooks follow the merge (union) rule, not the override rule.
- **De-dup is by handler identity:** "Command hooks are deduplicated by command
  string and `args`, and HTTP hooks are deduplicated by URL." Two _different_
  commands that do the same thing both run; two _byte-identical_ command+args
  entries run once. (Practical Nix consequence: emitting the same absolute
  store-path command from two contributors is safe — it collapses to one run.)
- **Ordering is non-deterministic** because execution is parallel. Do not rely
  on hook order for correctness.
- **Blocking aggregation = most-restrictive-wins.** "Every hook's command runs
  to completion before Claude Code merges the results. One hook returning deny
  doesn't stop sibling hooks from executing… Claude Code picks the most
  restrictive one: a deny overrides any allow." For
  `PreToolUse`/`UserPromptSubmit`, `exit 2` (or `decision:"block"`) from **any**
  hook blocks; `deny > ask > allow`.
- **Enterprise suppression exists:** `allowManagedHooksOnly` (managed settings)
  can block user/project/plugin hooks — the one case where union is deliberately
  narrowed. Plugins force-enabled via managed `enabledPlugins` are exempt.

**So: Nix does NOT need to concat.** Emit an array; the CLI unions. The only
thing Nix must guarantee is that when two Nix modules contribute to the same
event, the resulting `settings.hooks.<Event>` is a **concatenated list of
matcher-blocks**, not a clobber (see §4).

### 1b. The two repo routes are ORTHOGONAL, not competing

The prompt frames "`ai.claude.hooks` script files vs `ai.claude.settings.hooks`
JSON wiring" as two routes that might union or override. They are **neither** —
they are **two halves of one hook** that compose **by reference**:

| Route        | Repo option                                                 | Upstream target                                             | What it writes                                                                                                                                                                                     | Verified  |
| ------------ | ----------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| Script body  | `ai.claude.hooks` (`attrsOf lines`, `mkClaude.nix:250-267`) | `programs.claude-code.hooks`                                | Executable **files** under `~/.claude/hooks/<name>` (`mkTextEntries "hooks"`, HM module line 730; option type `attrsOf lines`, "Hooks are stored in the `hooks/` subdirectory", HM module 305-311) | Confirmed |
| Event wiring | `ai.claude.settings.hooks` (freeform JSON passthrough)      | `programs.claude-code.settings` → `~/.claude/settings.json` | The `{ <Event>: [{ matcher, hooks:[{type:"command", command}] }] }` binding (HM module settings example 143-165)                                                                                   | Confirmed |

A script-backed hook needs **both**: route 1 puts the executable on disk, route
2's `command` references it (by `~/.claude/hooks/<name>` path or an absolute
store path). They don't override each other and there is no de-dup between them
— they're different files (`hooks/<name>` vs `settings.json`). The CLI-level
union in §1a happens **only** on the route-2 wiring.

> **Design implication:** the future typed surface should model these as **two
> coupled options** — a typed per-event/matcher wiring option that can
> _reference or inline_ a script, plus the existing file-body option — rather
> than one flat map. A typed
> `hooks.<Event> = [{ matcher, command|scriptFile|http|prompt }]` where
> `scriptFile` auto-wires an `ai.claude.hooks` entry AND its `settings.hooks`
> command is the clean shape.

### 1c. devenv route — the `//` merge and its shape hazard

`mkClaude.nix:507` (devenv projection):

```nix
claude.code.hooks = (cfg.settings.hooks or {}) // cfg.hooks;
```

Here `cfg.settings.hooks` is **event-wiring JSON** but `cfg.hooks` is
**`attrsOf lines` script bodies** — two different shapes `//`-merged into one
upstream option that the comment says "upstream already writes into
settings.json" (i.e. it expects the event-wiring shape). `hooks` is also removed
from the gap-write (`upstreamOwnedSettingsKeys = ["hooks" "mcpServers"]`,
`mkClaude.nix:472`) so it isn't double-written. Today this "works" only because
a consumer typically populates _one_ of the two. It is a **medium-confidence
latent bug** for the typed rework: on devenv there is no separate "hook script
file" surface the way HM has `programs.claude-code.hooks`, so the future design
must either (i) give devenv its own file-writing path for script bodies, or (ii)
forbid `ai.claude.hooks` script-bodies on devenv and require inline/store-path
commands. **Verify the exact type devenv's `claude.code.hooks` expects during
implementation.**

---

## 2. KIRO v3 — composition & precedence

### 2a. Multiple `hooks[]` entries in one file — UNION (confirmed)

One `.kiro/hooks/<name>.json` envelope `{ version:"v1", hooks:[…] }` fires
**every** entry whose `trigger` (+ `matcher`) matches. `autoMemory.nix:173-201`
ships **four** lifecycle hooks (Stop, SessionStart, Manual, UserPromptSubmit) in
**one** `kiro-memory` envelope
(`hooks."kiro-memory" = builtins.toJSON hookEnvelope`, line 232); memory
decision **D30** records this firing live ("kiro fires 3+ hooks from one file —
no per-hook split"). So within a file, union is confirmed fact.

### 2b. Multiple hook FILES — all load and union (inference, strong)

Kiro docs: **"You define them once in `.kiro/hooks/` and they apply across all
agents in the workspace"** (`kiro-v3-docs.txt:304`), and each file is a
standalone `.kiro/hooks/<name>.json` (line 310). The loader is a `read_dir`
**directory scan** (documented in-repo at `mkKiro.nix:643-649` — the very reason
store symlinks are skipped). A directory scan reads **every** `<name>.json`, so
multiple files all load and their `hooks[]` arrays **union**. This is not
last-wins across files — the file is just a container. **Open:** whether two
entries sharing the same `name` field (used only as a telemetry identifier,
`kiro-v3-docs.txt:386`) are de-duplicated, and the ordering across files, are
**undocumented** (see Open Questions).

### 2c. Project vs the (ignored) global — no merge; global is DEAD under v3

Kiro v3 discovers hooks **only** under the launch cwd's `.kiro/hooks/` —
**never** global `~/.kiro/hooks/` (memory `kiro_v3_hooks_workspace_local`;
`mkKiro.nix:643-649`; kiro.dev/docs/cli/v3/hooks; issues Kiro #5440/#7737/#9075
— only steering + skills load globally). Consequences already baked into the
repo:

- The **HM** global install (`~/.kiro/hooks/`, `mkKiro.nix:469-471` via
  `home.file`) is **effectively dead for v3** (kept as source-of-truth only).
- The **devenv** backend writes hooks as **REAL files** via `enterShell`
  `install -m 0644 <writeText> .kiro/hooks/<name>.json` (`mkKiro.nix:650-657`),
  **not** devenv `files.*` symlinks (v3's scan skips symlinks).

So there is **no project↔global precedence question** on v3 — there is only
project. (v2 embedded-in-agent hooks still work transitionally,
`kiro-v3-docs.txt:306`; DEFER per scope.)

### 2d. Ordering, blocking, and matcher semantics

- **Blocking (`kiro-v3-docs.txt:394-402`):** command actions — `exit 0` =
  success (STDOUT added to context for SessionStart/UserPromptSubmit, else
  ignored); **`exit 2` = block** (only `PreToolUse`, `UserPromptSubmit`), STDERR
  returned to the LLM; any other code = warning, execution proceeds. Only
  `PreToolUse`, `PreTaskExec`, `UserPromptSubmit` **can block** (trigger table
  341-353).
- **Matcher (`369-380`):** regex; evaluates against tool-name
  (`Pre/PostToolUse`), file-path (`PostFile*`), prompt-text
  (`UserPromptSubmit`); **not evaluated** (always fires) for `SessionStart`,
  `Stop`, `PreTaskExec`, `PostTaskExec`, `Manual`.
- **Multi-hook aggregation for one Kiro event is UNDOCUMENTED** — the docs give
  per-hook exit semantics but never state how two matching `PreToolUse` hooks
  combine. **Inference:** any `exit 2` blocks (any-blocks-wins), consistent with
  the deny-wins model Kiro uses for permissions (`kiro-v3-docs.txt:172` "deny >
  ask > allow"). Flag as an open question / thing to verify empirically.
- **Edge case — subagents:** the goal doc notes Kiro "reportedly does NOT fire
  hooks in subagents." Docs say hooks "apply across all agents in the workspace"
  (line 304), which is ambiguous about _subagent_ spawns vs top-level agents.
  Treat subagent firing as **unverified** and cover it in the manual fixtures.
- **Agent action type:** a `{type:"agent", prompt}` hook appends text to context
  with **no subprocess** (`336-337`) — it has no exit code and cannot block, so
  it never participates in the shebang/exit-aggregation problem at all.

### 2e. Repo limitation to lift: `hooks` XOR `hooksDir`

`mkKiro.nix:426/597` asserts `!(cfg.hooks != {} && cfg.hooksDir != null)` —
today you **cannot** compose inline hooks _and_ a hooks directory. Since Kiro
unions all files in the dir anyway, the typed design should **drop this mutual
exclusion** and let both contribute (distinct filenames → both land → CLI
unions).

---

## 3. THE SHEBANG / SCRIPT-CONCAT PROBLEM

**The constraint:** two `#!/usr/bin/env bash` files cannot be textually
concatenated into one valid script (a second shebang becomes a comment at best,
and `set -e`/trap/exit semantics collide). So "merge two script-file hooks" must
never mean "cat two scripts."

**It never has to.** Enumerated strategies:

| Strategy                                    | Mechanism                                                                                                                                                     | When needed                                                                   | Verdict                                                                                                          |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **(a) Separate array entries → CLI unions** | Each contributor is its own `{type:"command", command:"<abs-store-path>"}` (Claude) or its own `hooks[]` entry / own `<name>.json` (Kiro). CLI runs them all. | Always available — both CLIs union arrays.                                    | **RECOMMENDED for both CLIs.** No concat, CLI does parallelism + exit-aggregation correctly.                     |
| **(b) Generated dispatcher wrapper**        | One `writeShellScript` that sequentially `exec`s/runs each contributing script and aggregates their results.                                                  | ONLY if a CLI restricted you to one command per event/matcher (neither does). | Fallback only. Loses Claude's parallelism; you must re-implement most-restrictive aggregation; more store paths. |
| **(c) Nix `listOf` concatenation**          | The _mechanism that builds the array in (a)_ — multiple modules each append their matcher-block/entry; module-system list-merge concatenates.                 | The Nix-side realization of (a).                                              | **Use with (a).** This is how the factory + consumer + skill-package each contribute without clobbering.         |

**Recommendation: (a) realized by (c).** Reserve (b) for a future CLI that lacks
array union.

**Exit-code / decision composition when several scripts run for one event:**

- **Claude — CLI-native, no action needed.** Parallel; all run to completion;
  **most-restrictive wins** (`deny > allow`; any `exit 2`/`decision:"block"`
  blocks). A dispatcher would _break_ this by serializing and forcing you to
  merge JSON `decision` objects by hand.
- **Kiro — CLI-native, aggregation undocumented.** Each entry's exit code is
  interpreted per the table; multi-hook aggregation is inferred as
  any-`exit 2`-blocks. If you were ever forced into a dispatcher (strategy b),
  **you** would own: run each child, capture codes, emit `exit 2` if any child
  did, and merge any JSON stdout — exactly the work (a) lets the CLI do.
- **Aggregating JSON stdout decisions:** with (a), you don't — the CLI merges
  sibling decisions (most-restrictive). Only a dispatcher forces you to
  deep-merge `{decision, reason, systemMessage}` objects and re-serialize, which
  is error-prone (whose `reason` wins? how do you concatenate
  `additionalContext`?). Another reason (a) beats (b).

---

## 4. NIX MERGE SEMANTICS — modelling factory + consumer + skill-package

**Goal:** hooks contributed by (i) the factory, (ii) the consumer, (iii) a skill
package must **compose (concatenate/union), not clobber.** How today's repo
merges, and where hooks differ:

- **Today's shared pools** (`mcpServers`, `skills`, `rules`, `lspServers`,
  `environmentVariables`, `agents`) use `mergeWithCollisionCheck`
  (`ai-common.nix:315-336`): `merged = topPool // cliPool` with a
  **collision-as-error** assertion. That is a _last-wins-with-guard_ attrset
  merge — appropriate for keyed singletons (one skill named `x`), **wrong for
  hooks**, where multiple contributors legitimately target the same event.
- **Hooks are deliberately NOT in that shared-pool machinery.**
  `hmTransform.nix`/`devenvTransform.nix` list only the six pools above; there
  is **no `ai.hooks` top-level fanout** (by design — `mkClaude.nix:260-263`:
  hooks are Claude-specific and Kiro's JSON shape differs). So hook composition
  must use **native module-system merge**, not `mergeWithCollisionCheck`.

**The right model per surface:**

1. **Claude event wiring** — make the typed option
   `attrsOf (listOf matcherBlockSubmodule)` (event → list of
   `{matcher, hooks:[…]}`). The NixOS module system **concatenates `listOf`
   definitions across modules automatically**. So factory + consumer +
   skill-package each writing `ai.claude.hooks.PreToolUse = [ their-block ]`
   compose to one concatenated list with **zero explicit `mkMerge`** — and that
   list is exactly the array the CLI unions (§1a). This is the single cleanest
   path and it makes the Nix merge _isomorphic_ to the CLI's runtime union. (The
   current freeform-JSON `settings.hooks` also nominally concatenates lists, but
   its behavior is un-typed and un-asserted — replacing it with an explicit
   `listOf` submodule guarantees concat + gives per-field types, satisfying the
   "never `types.anything`" standard.)
2. **Claude script bodies** — keep `attrsOf lines` (`ai.claude.hooks` today) but
   **rename** to disambiguate from wiring (e.g. `hookScripts`), and use
   **collision-as-error** merge (same as skills) since a filename _is_ a keyed
   singleton. A skill package contributing a script uses a namespaced filename
   to avoid collision.
3. **Kiro** — the composition unit is the **file**
   (`attrsOf (either lines path)`, whole `<name>.json` envelopes). Keep attrset
   merge but expect **distinct filenames per contributor**; two contributors
   under the same key should stay a **collision error** (a whole-envelope
   clobber is never what you want). To let two contributors add to the _same
   logical event_, they use two files (or two `hooks[]` entries in a
   factory-generated envelope) — the CLI's directory-scan union does the rest.
   Lift the `hooks` XOR `hooksDir` assertion (§2e) so inline + dir compose.
4. **`mkDefault` / `mkMerge` roles:** use `mkDefault` for _factory-provided
   defaults a consumer may replace_ (as `ultracodeOnLaunch` already does,
   `mkClaude.nix:341-346`, and as `hooksDir`→`hooks` expansion does, 329-333).
   Use `mkMerge` to _layer_ independent contributions (the file is already one
   big `mkMerge`). For **additive union** (the hooks case) rely on **`listOf`
   concatenation**, which needs neither `mkDefault` nor `mkMerge` — that's the
   point.

**Relate to the existing devenv `//`:**
`claude.code.hooks = (cfg.settings.hooks or {}) // cfg.hooks`
(`mkClaude.nix:507`) is a _right-biased attrset override_ — fine for merging two
disjoint keyed maps, **wrong** if both sides ever define the same event key
(right side clobbers the left's list — the opposite of union). Once the wiring
is a typed `attrsOf (listOf …)`, replace the `//` with module-native list-concat
(i.e. set both as separate config definitions and let `mkMerge` concatenate) so
devenv composes the same way HM does.

---

## Concrete citations index

- `packages/claude-code/lib/mkClaude.nix`: hooks option 250-267; hooksDir
  268-281; HM `inherit … hooks` 356; HM settings 364; devenv
  `upstreamOwnedSettingsKeys` 472; devenv
  `claude.code.hooks = (settings.hooks or {}) // cfg.hooks` 507.
- nixpkgs HM `programs.claude-code`
  (`/nix/store/9vprb…-source/modules/programs/claude-code.nix`): `settings`
  121-174 (incl. `hooks` event-wiring example 143-165); `hooks`
  `attrsOf lines`→files 305-311; `hooksDir` symlinked 386-393; settings.json
  write 690-694; `mkTextEntries "hooks"` 730; `mkRecursiveDirAttrs "hooks"` 722.
- `packages/kiro-cli/lib/mkKiro.nix`: v3 hook schema comment 292-298;
  `hooks`/`hooksDir` options 316-327; XOR assertion 426/597; HM `home.file` emit
  469-476; devenv real-file `enterShell` 650-657; hooksDir cp 661-667;
  workspace-local rationale 643-649.
- `packages/kiro-cli/lib/autoMemory.nix`: four-hook envelope 173-201; D30
  "multiple hooks per file" note 170-172; `toJSON` emit 232.
- `docs/plans/kiro-v3-docs.txt`: overview/"define once, apply across agents"
  304; format 310-332; action types 336-337; trigger table 341-353; matcher
  semantics 369-380; exit-code table 394-402; deny>ask>allow 172.
- `lib/ai/ai-common.nix`: `mergeWithCollisionCheck` 315-336.
  `lib/ai/dir-helpers.nix`: `hooksFromDir` 116-127.
  `lib/ai/app/{hm,devenv}Transform.nix`: shared-pool list (no hooks) 37-56 /
  24-43.
- Claude docs: `code.claude.com/docs/en/hooks`
  (union/parallel/dedup/most-restrictive; 30-event list);
  `code.claude.com/docs/en/settings` (precedence ladder; "Permission rules…
  merge across scopes rather than override"; "Arrays merge across settings
  sources"; `allowManagedHooksOnly`).

## Sources

- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)
- [Claude Code Settings](https://code.claude.com/docs/en/settings)
- [Automate actions with hooks (guide)](https://code.claude.com/docs/en/hooks-guide)
- [Sequential Hook Execution Option · anthropics/claude-code#21533](https://github.com/anthropics/claude-code/issues/21533)
- [Kiro v3 Hooks](https://kiro.dev/docs/cli/v3/hooks)
