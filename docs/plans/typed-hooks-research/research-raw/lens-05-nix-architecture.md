# SECTION_SCHEMA: Typed per-event hook options inside the mkAiApp factory (Claude + Kiro, HM + devenv parity)

## Scope of this section

How to model **typed, per-event, matcher-aware** hook options for Claude Code
and Kiro CLI inside the existing `mkAiApp` record factory, replacing today's
untyped passthrough (`ai.claude.hooks` = `attrsOf lines` script bodies +
event-wiring buried in freeform `ai.claude.settings.hooks`; `ai.kiro.hooks` =
raw-JSON-envelope files). Everything below uses explicit `lib.types` — never
`types.anything`. The one legitimate freeform escape hatch is
`freeformType = (pkgs.formats.json {}).type`, which is the pattern already used
for `ai.claude.settings` / `ai.kiro.settings`
(`packages/claude-code/lib/mkClaude.nix:52`,
`packages/kiro-cli/lib/mkKiro.nix:117`).

---

## 1. The backend surfaces we lower onto (ground truth, not memory)

Load-bearing because the Claude HM and Claude devenv backends **do not agree**
on what a "hook" option is, and today's factory papers over it with a stub.

### Claude — home-manager `programs.claude-code` (nix-community/home-manager `modules/programs/claude-code/options.nix`, ref `e3dea8e`)

- `hooks = lib.mkOption { type = lib.types.attrsOf lib.types.lines; … }` — **the
  attribute name is a hook FILENAME, the value is a script body**; upstream
  writes each to `~/.claude/hooks/<name>` and marks it executable
  (`tests/.../full-config.nix` →
  `assertFileIsExecutable home-files/.claude/hooks/pre-edit`). **It carries NO
  event, NO matcher.** It is a bag of scripts.
- `hooksDir = nullOr path` (symlinked dir; mutually exclusive with `hooks` via
  assertion).
- `settings = (pkgs.formats.json {}).type` (fully freeform). **The
  event→matcher→handler wiring lives ONLY inside `settings.hooks`**, untyped.
  Upstream's own example is the classic shape:
  ```nix
  settings.hooks.PreToolUse = [ { matcher = "Bash"; hooks = [ { type = "command"; command = "…"; } ]; } ];
  ```
  → **Conclusion: HM upstream has NO typed event-hook option. To type it, we
  generate the `settings.hooks` JSON ourselves and pass it through the freeform
  `settings` passthrough** (and/or write the script bodies through
  `programs.claude-code.hooks`, but reference them by absolute store path — see
  §4).

### Claude — devenv `claude.code` (cachix/devenv `src/modules/integrations/claude.nix`, ref `5f1cf17`)

- `hooks = submodule { freeformType = attrsOf hookSubmodule; options.git-hooks-run = …; }`
  where
  **`hookSubmodule = { enable ? true; name ? ""; hookType (enum of 17 events); matcher ? ""; command; }`**
  — i.e. devenv's `claude.code.hooks` is a **named-record** surface _shaped
  exactly like Kiro's_, keyed by hook name, carrying the event as a `hookType`
  field. Devenv itself `groupBy`s by `hookType` and emits
  `files."…/.claude/settings.json".json.hooks.<Event> = [{matcher; hooks = [{type = "command"; command;}];}]`.
- **Two consequences:** (a) devenv's emission is **command-only and lossy** — it
  hard-codes `type = "command"`, drops per-handler `timeout`, and has no
  `http`/`prompt`/`agent`/`mcp_tool`; (b) its `hookType` enum
  (`PreToolUse PostToolUse PostToolUseFailure Notification UserPromptSubmit SessionStart SessionEnd Stop SubagentStart SubagentStop PreCompact PermissionRequest WorktreeCreate WorktreeRemove TeammateIdle TaskCompleted ConfigChange`)
  independently **corroborates the expanded Claude event set** (see §2).

### ⚠ Latent bug the typed refactor must fix

`packages/claude-code/lib/mkClaude.nix:507` sets
`claude.code.hooks = (cfg.settings.hooks or {}) // cfg.hooks;` where `cfg.hooks`
is `attrsOf lines` (script strings) and `cfg.settings.hooks` is the
event-nesting JSON (`{PreToolUse = [...]}`). **Neither matches devenv's real
`attrsOf hookSubmodule` type** — a string isn't a `{hookType; command;}` record,
and `PreToolUse = [...]` treats the event name as a hook _name_ whose value is a
list, not a submodule. This only passes `nix flake check` because
`checks/module-eval.nix:112` stubs `claude.code = attrsOf anything`. In a real
devenv eval it is a type error. Surface + fix in the same refactor.

### Kiro — HM & devenv (`packages/kiro-cli/lib/mkKiro.nix`, `packages/kiro-cli/lib/autoMemory.nix`)

- `ai.kiro.hooks = attrsOf (either lines path)` — **whole-file raw-JSON
  passthrough**; each key becomes `<configDir>/hooks/<name>.json`. The v3
  envelope schema (`kiro.dev/docs/cli/v3/hooks`, mirrored `mkKiro.nix:292-298`):
  `{ version:"v1", hooks:[ { name, description?, trigger, matcher?, action:{type:"command"|"agent", command|prompt}, timeout?(60), enabled?(true) } ] }`.
  One file can hold many hooks (auto-memory ships all four lifecycle hooks in
  one `kiro-memory.json` envelope — `autoMemory.nix:173-201`).
- **Emission asymmetry (load-bearing, already implemented for the untyped
  surface):** HM writes `home.file."<cfgDir>/hooks/<name>.json"` (a store
  symlink) — but **v3 discovers hooks ONLY under the launch-cwd `.kiro/hooks/`,
  never global `~/.kiro/hooks/`, and its `read_dir` scan SKIPS store symlinks**
  (`claude-rules-kiro-cli.md`; kirodotdev/Kiro #5440/#7737/#9075). So the HM
  emission is _effectively dead for v3_ (kept as source-of-truth only). devenv
  therefore installs **REAL files via `enterShell`**
  (`install -m 0644 ${writeText …} .kiro/hooks/<name>.json`,
  `mkKiro.nix:650-667`), NOT `files.*` symlinks. The typed emitter must preserve
  exactly this.
- Kiro hook **stdin is metadata-only** (`{session_id, cwd}`;
  `UserPromptSubmit.prompt` is empty), **`Stop` fires per-turn**, there is **no
  `SessionEnd`** (`autoMemory.nix` header; `claude-rules-kiro-cli.md`). These
  shape which hooks a consumer can meaningfully use and are why a shared
  cross-CLI pool is wrong (§3).

---

## 2. Typed shape per CLI

### Event / trigger vocabularies — source them, don't hard-code

Claude's event set is large and moving. Confirmed-stable canonical 9 (Claude
Code plugin-dev hook skill + classic docs):
`PreToolUse PostToolUse UserPromptSubmit Notification Stop SubagentStop PreCompact SessionStart SessionEnd`.
The current docs page (`code.claude.com/docs/en/hooks`) lists ~30 (adds
`Setup UserPromptExpansion PermissionRequest PermissionDenied PostToolUseFailure PostToolBatch MessageDisplay SubagentStart TaskCreated TaskCompleted StopFailure TeammateIdle InstructionsLoaded ConfigChange CwdChanged FileChanged WorktreeCreate WorktreeRemove PostCompact Elicitation ElicitationResult`),
of which devenv independently ships 17 in its `hookType` enum — so the expansion
is **real, not a fetch artifact**, but the exact live set is
binary-version-specific.

**Recommendation (DRY / SSOT, matches `models.json` +
`overlays/claude-code-extracted.json`):** commit
`packages/claude-code/hook-events.json` (and
`packages/kiro-cli/hook-triggers.json`); ideally extract the Claude list from
the packaged binary via the existing `extraExtract` guard that already produces
`effortLevels`/`launchEffortPins`, so a version bump can't silently drift the
enum. Use a **soft enum** (`either (enum known) str`) — same non-enforcing
philosophy as `settings.model` (`mkClaude.nix:77-87`) — so a newly-shipped event
never breaks eval.

```nix
knownClaudeHookEvents = builtins.fromJSON (builtins.readFile ../hook-events.json);
knownKiroHookTriggers = builtins.fromJSON (builtins.readFile ../hook-triggers.json);
# Kiro v3 triggers (kiro.dev/docs/cli/v3/hooks): SessionStart Stop PreToolUse
# PostToolUse PreTaskExec PostTaskExec UserPromptSubmit PostFileCreate
# PostFileSave PostFileDelete Manual
```

### 2a. Claude — keyed BY EVENT, arrays of matcher-groups (mirrors settings.json 1:1)

```nix
# One reusable handler submodule — a tagged union over `type`.
# Exactly ONE payload sub-shape is populated per `type`; assertions enforce.
claudeHookHandler = lib.types.submodule {
  options = {
    type = lib.mkOption {
      type = lib.types.enum [ "command" "http" "prompt" "agent" "mcp_tool" ];
      default = "command";
    };
    # --- command handler: `command` = literal cmd OR path we install;
    #     `script` = inline body → writeShellScript → absolute store path (§4). ---
    script  = lib.mkOption { type = lib.types.nullOr lib.types.lines; default = null; };
    command = lib.mkOption { type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path); default = null; };
    args    = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
    timeout = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; }; # upstream default 600
    # --- http handler ---
    url            = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    headers        = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
    allowedEnvVars = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
    # --- prompt / agent handler ---
    prompt = lib.mkOption { type = lib.types.nullOr lib.types.lines; default = null; };
    model  = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
  };
};

claudeHookGroup = lib.types.submodule {
  options = {
    matcher = lib.mkOption { type = lib.types.str; default = ""; }; # "" = all; regex over tool/agent/type per event
    hooks   = lib.mkOption { type = lib.types.listOf claudeHookHandler; default = []; };
  };
};

# ai.claude.hooks.<Event> = [ { matcher; hooks = [ handler … ]; } … ]
# Built as a submodule whose OPTIONS are the known events, so each event
# is a typed `listOf claudeHookGroup` and unknown/bleeding-edge events
# still round-trip through a JSON freeform tail.
ai.claude.hooks = lib.mkOption {
  type = lib.types.submodule {
    freeformType = (pkgs.formats.json {}).type;                    # escape hatch for un-modeled events
    options = lib.genAttrs knownClaudeHookEvents (_:
      lib.mkOption { type = lib.types.listOf claudeHookGroup; default = []; });
  };
  default = {};
};
```

- **v1 scope decision:** the four non-`command` handler types
  (`http`/`prompt`/`agent`/`mcp_tool`) are newer and only partly documented. A
  defensible v1 types **`command` only** (drop the http/prompt/agent/model
  fields) and leaves the rest to the freeform tail; a v2 promotes them. Flagged
  as a decision.
- Matcher is uniformly `str` (Claude ignores it on non-matcher events; an
  assertion _may_ reject a non-empty matcher on `Stop`/`UserPromptSubmit`/… for
  hygiene, but that duplicates Claude's own tolerance — low value).

### 2b. Kiro — keyed BY NAMED HOOK RECORD, with a `trigger` field (mirrors the v3 envelope)

```nix
kiroHookAction = lib.types.submodule {
  options = {
    type    = lib.mkOption { type = lib.types.enum [ "command" "agent" ]; default = "command"; };
    command = lib.mkOption { type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path); default = null; };
    script  = lib.mkOption { type = lib.types.nullOr lib.types.lines; default = null; }; # → writeShellScript (§4)
    prompt  = lib.mkOption { type = lib.types.nullOr lib.types.lines; default = null; }; # type = "agent"
  };
};

kiroHookRecord = lib.types.submodule ({ name, ... }: {
  options = {
    trigger     = lib.mkOption { type = lib.types.either (lib.types.enum knownKiroHookTriggers) lib.types.str; };
    matcher     = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; }; # regex; ignored by non-matcher triggers
    action      = lib.mkOption { type = kiroHookAction; };
    timeout     = lib.mkOption { type = lib.types.ints.unsigned; default = 60; };  # 0 disables; ignored for agent actions
    enabled     = lib.mkOption { type = lib.types.bool; default = true; };
    description = lib.mkOption { type = lib.types.str; default = ""; };
    hookName    = lib.mkOption { type = lib.types.str; default = name; };           # → JSON `name`
  };
});

# Typed surface, keyed by hook name. Factory bundles all records into ONE
# envelope file (or one-per-hook) — both are discovered by v3's dir scan.
ai.kiro.hooks = lib.mkOption { type = lib.types.attrsOf kiroHookRecord; default = {}; };
```

### 2c. Reconciling the two keyings

They are genuinely different because the on-disk formats are different: Claude's
`settings.json` nests **event → [matcher-group → handler-array]**; Kiro's
envelope is a **flat list of named records each carrying its own `trigger`**.
The typed surfaces therefore key differently _on purpose_ — Claude by event
(natural, matches the file), Kiro by hook name (natural, matches the envelope +
lets `ai.kiro.hooks.<name>` merge/override cleanly like every other Kiro pool).
The only common substructure is `{event/trigger, matcher?, command/script}`;
that commonality is captured in a **shared emission helper (§4), not a shared
option** (§3).

---

## 3. Should there be a shared `ai.hooks`? — No. Keep per-CLI.

**Recommendation: per-CLI typed options only, plus shared emission _helpers_.**
The repo already made this call for the untyped surface and for commands, and
the reasons are stronger for hooks:

1. **Divergent event vocabularies.** Claude ~30 events vs Kiro 11; only ~5
   overlap semantically (`SessionStart`, `Stop`, `PreToolUse`, `PostToolUse`,
   `UserPromptSubmit`). A shared enum is either a lax union (loses per-CLI
   validation) or a lowest-common-denominator (loses the CLI-specific events —
   defeating the whole "expose EVERY hook" goal).
2. **Divergent stdin/output/exit contracts.** Claude command hooks receive rich
   JSON stdin (`tool_input`, …) and speak structured JSON stdout
   (`{"decision":"block"}`, `additionalContext`, `hookSpecificOutput`). Kiro
   command hooks receive **metadata-only** stdin (`{session_id, cwd}`) and
   communicate via **exit code** (`2` = block, and only for
   `PreToolUse`/`UserPromptSubmit`) + stdout-added-to-context (only
   `SessionStart`/`UserPromptSubmit`). A single script authored against a shared
   `ai.hooks` would have to branch on _which CLI invoked it_ — a shared pool
   would silently mis-emit portable-looking scripts.
3. **Divergent blocking + lifecycle.** `Stop` **can block on Claude, cannot on
   Kiro**; Kiro `Stop` fires **per-turn**, Claude `Stop` at end-of-response;
   Kiro has **no `SessionEnd`**. A "do X once at session end" intent maps to
   Claude `SessionEnd` and has _no Kiro equivalent_ — no shared option can honor
   it.
4. **Precedent + house rule.** `mkClaude.nix:261-263` ("Claude-only — Kiro's
   `ai.kiro.hooks` takes JSON-shaped hook definitions … so no top-level
   `ai.hooks` fanout") and the `commands` option likewise
   (`mkClaude.nix:241-243`). The `feedback_content_separation` memory
   ("overlay/module-specific types ship with the consumer, NOT shared `lib/`")
   points the same way.

What _is_ worth sharing is the emission plumbing (§4): `lib.ai.mkHookScript` and
a `hooksFromDir`-style ingester. That gives DRY at the layer where the
divergence is zero (baking a strict-mode script to an absolute store path)
without coupling the option surface.

---

## 4. Where generated hook scripts live, and the `command` reference

**Shared helper (new, `lib/ai/ai-common.nix` or `lib/ai/hooks.nix`):**

```nix
# Bake an inline hook body to an absolute store path with the repo's
# mandatory strict-mode header. Absolute path is REQUIRED: Claude/Kiro
# MCP+hook env REPLACES the process env, so a bare command name has no
# PATH (claude-rules-nix-standards.md → "Shell Wrappers: Absolute Paths").
mkHookScript = { pkgs, name, body }:
  pkgs.writeShellScript "aihook-${name}" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${body}
  '';
```

- The typed `script` / `action.script` field runs through `mkHookScript`; the
  resulting `"${drv}"` (a store-path string _with context_) becomes the emitted
  `command`. The `command` field accepts `str` (used verbatim — caller
  guarantees absolute) or `path` (emit `"${path}"`, its store path). This is
  exactly how `autoMemory.nix` already bakes its four wrappers and references
  them by `"${stopWrapper}"` (`autoMemory.nix:127-201`) — the typed option
  generalizes that one working pattern.
- **DRY with `dir-helpers.nix:hooksFromDir`.** Today `hooksFromDir` returns
  `attrsOf lines` (readFile'd script bodies) and feeds Claude's untyped `hooks`
  (script files). It carries **no event/matcher** — a bare script file can't.
  Under the typed model, keep `hooksDir`/`hooksFromDir` as a _low-level
  script-body ingester_ whose outputs are referenced by explicit typed entries
  (`command = <ref to ingested script>`), **or** deprecate it in favor of
  explicit typed records. (Decision below.) A Kiro variant (`command`-shaped)
  can reuse the same helper since it also just needs "body → store script".

---

## 5. Lowering table (typed option → each backend), keeping HM↔devenv parity

|            | **Claude HM**                                                                                 | **Claude devenv**                                                                                                                                                           | **Kiro HM**                                                                                      | **Kiro devenv**                                                                  |
| ---------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Target     | `programs.claude-code.settings.hooks` (freeform passthrough) — **we generate the event JSON** | `files.".claude/settings.json".json.hooks` (**write it ourselves**, deep-merged with upstream settings — same trick as the existing `gapSettings` write `mkClaude.nix:515`) | `home.file."<cfgDir>/hooks/<name>.json".text` (⚠ **dead under v3** — store symlink, global path) | `enterShell` **real-file** `install -m 0644 <writeText> .kiro/hooks/<name>.json` |
| Script cmd | absolute `"${mkHookScript …}"`                                                                | same                                                                                                                                                                        | same                                                                                             | same                                                                             |
| Parity     | Both emit the **identical** `settings.json.hooks` JSON from the same typed value              | Both emit the **identical** envelope JSON                                                                                                                                   |                                                                                                  |                                                                                  |

Notes / edge cases baked into the recommendation:

- **Claude devenv: bypass `claude.code.hooks`, write the JSON directly.**
  Routing through devenv's `claude.code.hooks` submodule (a) is lossy
  (command-only, no timeout) and (b) is the source of the §1 schema-mismatch.
  Writing `files.".claude/settings.json".json.hooks` ourselves gives full
  fidelity _and_ byte-parity with the HM side (both consume the same
  `renderClaudeHooks cfg.hooks`). This mirrors the already-shipped gap-settings
  pattern (`mkClaude.nix:511-517`).
- **Composition/precedence collision (Claude devenv):** when `git-hooks.enable`
  is true, devenv's default `claude.code.hooks.git-hooks-run` _also_ writes
  `settings.hooks.PostToolUse`. Two independent writers of
  `…settings.json.json.hooks.PostToolUse` — and `pkgs.formats.json` merge
  **replaces** lists rather than concatenating, so one clobbers the other. The
  emitter must either (i) merge our `PostToolUse` group _into_ whatever
  `claude.code.hooks` produced, or (ii) disable `git-hooks-run` when the typed
  option owns `PostToolUse`, or (iii) route our `PostToolUse` back through
  `claude.code.hooks` records so devenv does the grouping. Flag as a decision; a
  golden check should assert the merged result contains BOTH.
- **Kiro v3 workspace-local / real-file constraint is non-negotiable** — the
  typed emitter reuses the existing `enterShell` real-file mechanism verbatim;
  reverting to `files.*` makes `/hooks` silently show zero (invariant #11,
  `claude-rules-kiro-cli.md`).
- Keep the existing `!(hooks != {} && hooksDir != null)` mutual-exclusion
  assertions (`mkKiro.nix:426-428`).

---

## 6. Composition & precedence across the layers

- **Within a CLI:** `ai.claude.hooks.<Event>` is a **list** → contributions from
  multiple modules **concatenate** (matches Claude's own multi-group semantics;
  no collision check needed, unlike the attrset pools). `ai.kiro.hooks` is an
  **attrset keyed by hook name** → route it through `mergeWithCollisionCheck`
  exactly like every other Kiro pool (`ai-common.nix:315`), so two modules
  declaring the same hook name is a _failure_, not a silent override (the `ai.*`
  collision house rule).
- **Typed vs freeform escape hatch:** the freeform tail on `ai.claude.hooks`
  (and a retained `ai.claude.settings.hooks`, deprecated) must **deep-merge
  under** the typed output so bleeding-edge events remain reachable — same
  "soft" stance as `settings.model`.
- **Cross-place (multiple config sources):** the GOAL's "hooks defined in more
  than one place" is: (project) devenv `.claude/settings.json` + (user) HM
  `~/.claude/settings.json` + Claude's own precedence. That precedence is
  **Claude's**, not ours — our job is only to not _lose_ a contribution
  (list-concat within a scope) and to document that user+project both fire. No
  new module axis.

---

## 7. Backward-compat / migration (this is a breaking option-shape change)

**Claude.** `ai.claude.hooks` today is `attrsOf lines` (script bodies). The
valuable typed surface _wants that exact name_ for the event map, so the shapes
collide. Recommended path:

- Repurpose `ai.claude.hooks` → the typed **event map** (§2a). Move script-body
  ingestion to `ai.claude.hooksDir` / a renamed `ai.claude.hookScripts` (still
  `attrsOf lines`, still → `programs.claude-code.hooks` files) that typed
  entries _reference_.
- Keep reading `ai.claude.settings.hooks` (freeform) as a **deprecated** escape
  hatch that deep-merges under the typed output, with a one-release `lib.warn`.
- This is breaking; do it inside the factory refactor sweep and update the
  consumer (`nixos-config`) in lockstep, HITL (`feedback_nixos_config_hitl`).

**Kiro.** `ai.kiro.hooks` today is `attrsOf (either lines path)` =
whole-envelope raw JSON; **`autoMemory.nix` is a real consumer** that returns
`hooks."kiro-memory" = builtins.toJSON envelope` (one file, four hooks) and
bakes wrapper store paths into `action.command`. If typed `ai.kiro.hooks`
becomes name-keyed records, auto-memory must return four records instead of one
JSON string. Recommended path:

- Add typed `ai.kiro.hooks` (name-keyed records, §2b) as the new surface; the
  `action.command = either str path` field lets `autoMemory` pass its pre-baked
  `"${wrapper}"` paths and migrate **incrementally**.
- Keep a raw `ai.kiro.hooksJson` (`attrsOf (either lines path)`) whole-envelope
  escape hatch so auto-memory (and any pre-baked JSON) keeps working during
  migration; deprecate later.
- Preserve every load-bearing invariant (real-file emission, HOME baking,
  per-turn `Stop`, no-`SessionEnd`, secret-via-file) — those live in
  `autoMemory.nix`, not the option type, so they survive the option-shape change
  untouched.

---

## 8. Checks / fixtures (folds in the GOAL's "verify every hook, some need auth → manual" open question)

Three tiers, matching existing precedents:

1. **Eval-time wiring (hermetic, no tokens) — `nix flake check`.** Extend
   `checks/module-eval.nix` (already stubs both backends): assert a typed
   `ai.claude.hooks.PreToolUse = [{matcher; hooks=[{script=…}]}]` lowers to the
   right `settings.json.hooks` JSON on **both** HM and devenv (byte-parity), and
   that `ai.kiro.hooks.<name>` lowers to the right envelope + `enterShell`
   real-file install. Reuse the `kiro-auto-memory-hm-devenv-parity` pattern
   (`module-eval.nix:1078`). Add a collision test (two modules, same Kiro hook
   name → assertion fires).
2. **Behavioral, script-only (hermetic, no CLI, no tokens) —
   `nix flake check`.** The `checks/validate-at-stop.nix` precedent: feed a
   synthetic JSON payload on stdin to the _generated hook script_, assert
   stdout/exit (block reason, exit 2, etc.) against **stub** tools. Covers
   command-hook logic without the binary. Fixtures under
   `checks/fixtures/claude-hooks/` already exist.
3. **Live firing (real binary, may need auth → NOT in flake check).** Whether
   Claude/Kiro actually _invokes_ the hook on the event needs the CLI and burns
   tokens for auth-gated events. Deliver as a **flake app**
   (`nix run .#hooks-live`) or **devenv task**, env-gated + opt-in, driving a
   throwaway trusted project — exactly the `dev/scripts/kiro-memory-hitl.sh`
   shape. `nix flake check` covers tiers 1–2; tier 3 is manual by construction.
   (Answering the GOAL's open question: **no, `nix flake check` cannot cover
   live-firing of auth-gated hooks** — keep those in a flake app / devenv task,
   not the check set.)

---

## 9. Factory wiring summary (the mkAiApp plumbing, per the 4-layer pattern)

- **Options** (`ai.claude.hooks` typed event map; `ai.kiro.hooks` typed records)
  live in each package's `mkClaude.nix` / `mkKiro.nix` `options` block
  (CLI-specific shape → per-CLI, per the "Adding a new shared pool" fragment
  step 2 "for CLI-specific shape, like kiro's JSON agents").
- **No L1/L2 top-level pool, no `sharedOptions.nix` entry, no
  `mergeWithCollisionCheck` for Claude** (list-shaped). Kiro's attrset records
  DO route through `mergeWithCollisionCheck` if a top-level pool is ever added —
  but §3 says don't add one.
- **L4 emission** in each factory's `hm.config` / `devenv.config` callback, per
  the lowering table (§5). Emission helpers (`mkHookScript`,
  `renderClaudeHooks`, `renderKiroEnvelope`) live in `lib/ai/` (pure, shared,
  testable outside the module system — like `mkLspConfig`).
- **`hooksDir`** (Claude) keeps its L2b→L3 `hooksFromDir` fanout
  (`mkClaude.nix:329-333`) but now feeds the _script-body_ sub-surface, not the
  event map.
