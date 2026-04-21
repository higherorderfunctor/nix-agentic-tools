# `ai.claude.settings` — Translation + Gap Fill

> **Status:** devenv side shipped in commit 796677d (2026-04-21). HM
> translation refactor tracked as separate plan doc.
>
> **Goal:** close the `ai.claude.settings` backlog item by making the
> factory translate our input to each backend's native surface
> (upstream where available, direct file write where not). Matches the
> transformer-pattern principle — our optionset is OUR design, the
> factory translates to each backend's shape on emission.

## Implementation notes (deltas from plan)

- **Options-doc stub discovery (fixed in same commit).** The plan
  anticipated that `checks/module-eval.nix`'s `devenvStubs` would
  absorb the new `claude.code.hooks` / `claude.code.settingsPath`
  writes (it uses `attrsOf anything`, so it does). It did not account
  for the SEPARATE `devenvStubModule` in `lib/options-doc.nix`, which
  declares a TYPED subset of `claude.code` options (`enable`, `env`,
  `mcpServers`, `model`). Our new writes hit
  `"option does not exist"` errors in the `docs-options-devenv`
  derivation. Fixed by extending the options-doc stub with `hooks`
  (attrs-of-anything) and `settingsPath` (str, default
  `.claude/settings.json`).
- **Takeaway for future factory changes:** when adding writes to
  `claude.code.*`, `copilot.*`, or `kiro.*` (stubbed-upstream
  options), check BOTH stubs — `devenvStubs` in `checks/module-eval.nix`
  and `devenvStubModule` in `lib/options-doc.nix`. Same for the HM
  side: `hmStubs` (module-eval) and `hmStubModule` (options-doc).
- **Update (2026-04-21, commit 732ca51):** stub churn for Claude
  upstream options (`programs.claude-code` in HM, `claude.code` in
  devenv) eliminated by collapsing the per-option typed stubs to
  `attrsOf anything`. Upstream options were never in the doc scope
  (options-doc filters to `ai.*`), so the typed stubs produced no
  output — only maintenance cost. Future `ai.claude.*` additions
  no longer require stub extensions. Copilot + Kiro stubs were
  already freeform; Claude was the outlier.

## Current state audit

- `ai.claude.settings` declared at `packages/claude-code/lib/mkClaude.nix:44-51`
  as `attrsOf anything` (freeform, matches upstream's shape by
  coincidence).
- **HM**: `inherit (cfg) settings;` at `mkClaude.nix:89` passes the
  value straight to `programs.claude-code.settings`. Upstream HM then
  writes `~/.claude/settings.json`. Works end-to-end, but the
  implementation is raw inherit, not translation.
- **Devenv**: `env = cfg.settings.env or {};` at `mkClaude.nix:164`
  pulls only the `env` sub-attr and routes it to upstream
  `claude.code.env`. Every other key in `ai.claude.settings`
  (effortLevel, permissions, model, etc.) is silently dropped.
- **Plan backlog bullet** says "silently ignored" — outdated for HM,
  correct for devenv (minus env).
- **Module-eval tests**: none exercise `ai.claude.settings.<key>`
  pass-through or emission.

## Principle

> Our optionset is our design, not a mirror of upstream's. Each backend
> translates our input to whatever surface is native there.

Applied here:

- Our schema: `ai.claude.settings` (today freeform; typed shape is a
  separate concern, explicitly deferred).
- HM backend: translate `ai.claude.settings → programs.claude-code.settings`
  (upstream HM owns the disk write).
- Devenv backend: translate `ai.claude.settings →
claude.code.<k>` where upstream exposes the key, and gap-write the
  rest via `files.".claude/settings.json".json`. Module system attrs
  merge unions the two writes into a single settings.json.

## Scope — what ships this pass

### 1. Backlog cleanup — `docs/plan.md`

Rewrite the `ai.claude.settings rendering` bullet to reflect reality:

- HM works today via transitional pass-through; flagged for migration
  to the explicit-translation pattern that devenv is getting in this
  pass.
- Devenv gap being closed in this pass (this document).
- Typed `ai.claude.settings` schema remains out of scope; current
  `attrsOf anything` is retained.

### 2. HM side — test only, no behavior change

- Keep `inherit (cfg) settings;` as-is. Today it is an identity
  translation because our schema matches upstream's.
- Add a short comment above it noting the transitional nature and
  pointing at the devenv block as the end-state pattern.
- Add a module-eval test: set `ai.claude.settings.effortLevel = "medium"`
  with `ai.claude.enable = true`, assert
  `config.programs.claude-code.settings.effortLevel == "medium"`.

### 3. Devenv side — translation + gap fill

In `mkClaude.nix` devenv `config` callback:

- Route keys upstream already understands:
  - `claude.code.hooks = cfg.settings.hooks or {};`
  - `mergedServers` continues to route to `claude.code.mcpServers`
    (no change).
- Drop the `env = cfg.settings.env or {};` shortcut. `env` flows
  through the gap write along with everything else.
- Gap-write everything else:
  ```nix
  files.".claude/settings.json".json =
    aiCommon.filterNulls
      (removeAttrs cfg.settings [ "hooks" "mcpServers" ]);
  ```
- The module system's attrs merge unions this write with upstream's
  own `files.<settingsPath>.json = { hooks = …; }` write. Both land
  in the same on-disk `.claude/settings.json`.

### 4. Path-key alignment (sub-problem to resolve in implementation)

- Upstream writes using the key `"${config.devenv.root}/.claude/settings.json"`
  (absolute path derived from devenv root).
- Our gap-write uses the relative key `".claude/settings.json"`.
- **If devenv treats these as the same file**: module merge works, no
  further action needed.
- **If they're distinct files.\* keys**: we pin
  `claude.code.settingsPath = lib.mkDefault ".claude/settings.json"`
  in our factory so both writes hit the same relative key and merge.
- Resolution path during implementation:
  1. Attempt the relative-key write first.
  2. Evaluate a real devenv shell (not the stub harness) and inspect
     whether one file or two are produced. Stub harness cannot exercise
     upstream's real write, so this has to be verified outside
     module-eval.
  3. If two files appear, apply the `settingsPath` pin and re-test.

### 5. Devenv tests

Assert our factory's output; upstream's rendering is not exercised by
the module-eval stub harness.

- `ai.claude.settings.effortLevel = "medium"` → resolved
  `config.files.".claude/settings.json".json.effortLevel == "medium"`.
- `ai.claude.settings.env.FOO = "bar"` → resolved
  `config.files.".claude/settings.json".json.env.FOO == "bar"`
  (regression guard for the dropped shortcut).
- `ai.claude.settings.hooks.PreToolUse = [...]` →
  `config.claude.code.hooks.PreToolUse` (stubbed, just asserts the
  routed key lands). Also asserts `hooks` does NOT appear in our
  gap-write (`removeAttrs` filtered it out).
- `ai.claude.settings = { }` → no `files.".claude/settings.json".json`
  key set by our factory (filterNulls + empty removeAttrs result is
  empty, lib.mkIf-guarded).

Harness limitation noted inline: stub devenv module does not run
upstream's real claude.code logic, so the deep-merge on disk is
verified by the pin strategy in §4 rather than by module-eval.

### 6. Commit

Single commit: `feat(claude): translate ai.claude.settings to devenv
via hook routing + gap write`. Covers plan update, HM comment + test,
devenv translation + tests.

## Out of scope (flagged follow-ups)

- **HM explicit-translation refactor. ~~Anti-pattern~~ → identity
  translation.** _Correction (2026-04-21):_ initial scoping
  flagged the HM `inherit (cfg) settings;` as raw inherit needing
  the same refactor as devenv. On further research this is wrong —
  upstream HM's `programs.claude-code.settings` accepts
  `attrsOf anything` and writes the full attrs to
  `.claude/settings.json` via `home.file.<path>.source`. Our schema
  declares the same shape, so `inherit (cfg) settings;` is IDENTITY
  translation, not a mirror. Translation happens; it just has
  nothing to do. No refactor needed until the schema diverges
  (see typed-schema bullet below). The HM upstream `home.file.source`
  path-typed write also means the module-merge trick we used on
  devenv would NOT work on HM — two `.source` setters conflict.
  If/when typed schema lands, HM would need `mkForce` + our own
  JSON render, different strategy than devenv.
- **Typed `ai.claude.settings` schema.** Opinionated submodule with
  known keys (`effortLevel`, `enableAllProjectMcpServers`,
  `permissions`, `env`, `hooks`, `outputStyle`) + freeformType escape
  hatch. Matches how Kiro's settings are typed today. Becomes the
  trigger for an actual HM translation refactor (see above). Separate
  design pass.
- **`ai.claude.plugins` — same story as settings.** Upstream HM's
  `plugins` option is `listOf (either package path)` matching our
  declaration exactly. `inherit (cfg) plugins;` is identity
  translation. Not an anti-pattern. Flagged in plan.md as a
  typed-schema follow-up only.
- **Any upstream engagement.** Not on the table.

## Size estimate

~40 lines factory changes + 3–4 new tests + 1 plan.md edit + 1 commit.

## Review checklist (what to verify before approving)

- [ ] Plan says translation, not inherit, for devenv.
- [ ] HM stays unchanged this pass (only comment + test added).
- [ ] Gap write uses `files.".claude/settings.json".json`, not `.text`
      (attrs-typed JSON format enables module merge).
- [ ] Hooks routed to upstream, excluded from gap write via
      `removeAttrs`.
- [ ] Env no longer short-circuited — flows through gap write.
- [ ] Tests assert our factory's output only (stub harness limitation
      acknowledged).
- [ ] Path-key alignment (§4) resolution strategy is documented.
- [ ] Out-of-scope items listed, not started.
