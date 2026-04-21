# `ai.lspServers` top-level — cross-ecosystem LSP pool

> **Status:** plan only; proceeding autonomously. User will review
> journal post-execution.
>
> **Goal:** add `ai.lspServers` at the top level that fans out to
> each enabled CLI's per-CLI `lspServers` option. Consumers declare
> an LSP server once; it flows to every enabled ecosystem's native
> LSP config file without per-CLI duplication.

## Scope justification

- Today consumers must set `ai.kiro.lspServers.nixd = {…}` AND
  `ai.copilot.lspServers.nixd = {…}` separately to configure the
  same LSP server for both. The per-CLI options already exist and
  write to their native `lsp-config.json` / `settings/lsp.json`
  paths. A top-level pool matches the `ai.mcpServers` /
  `ai.skills` / `ai.instructions` / `ai.rules` pattern.
- Freeform-not-typed: per-CLI options today are
  `attrsOf (attrsOf anything)`. Matching that shape at top-level
  keeps the change non-breaking. Consumers still write the raw
  JSON shape each CLI expects (inherited behavior).
- Typed `lspServerModule` (at `lib/ai/ai-common.nix`) + per-CLI
  translators (`mkLspConfig` / `mkCopilotLspConfig`) exist and are
  unused. A future pass could migrate per-CLI to typed, with the
  top-level option switching type in tandem. **Out of scope here**
  — breaking type change, deserves its own journal.
- No Claude-side implication today; upstream HM `programs.claude-code.lspServers`
  exists but our `mkClaude` doesn't currently route it. Could add
  in the same pass or separately — see "Option: include Claude
  routing" below.

## Out of scope (tracked follow-ups)

- **Typed migration** (`ai.lspServers` + per-CLI → `lspServerModule`
  everywhere, per-CLI translator invoked in factory). Breaking for
  any consumer today using the freeform shape. Follow-up plan.
- **Claude-side `ai.claude.lspServers`.** Upstream HM supports it;
  our factory doesn't currently expose it. Considered for this pass
  but pulled into a separate journal to keep this one small (Claude
  has its own per-CLI declarations to add, not just top-level
  fanout). See "Follow-up" at end.

## Current state audit

- **`ai.kiro.lspServers`** — `packages/kiro-cli/lib/mkKiro.nix`,
  declared as `attrsOf (attrsOf anything)`. HM writes
  `home.file."${cfg.configDir}/settings/lsp.json".text =
builtins.toJSON cfg.lspServers`. Devenv mirrors.
- **`ai.copilot.lspServers`** — `packages/copilot-cli/lib/mkCopilot.nix`,
  same `attrsOf (attrsOf anything)` type. HM writes to
  `home.file."${cfg.configDir}/lsp-config.json".text`. Devenv mirrors.
- **Top-level `ai.lspServers`** — does NOT exist today.
- **`sharedOptions.nix`** — declares `ai.context`, `ai.mcpServers`,
  `ai.instructions`, `ai.rules`, `ai.skills`. Need to add `ai.lspServers`.
- **`hmTransform.nix` / `devenvTransform.nix`** — compute
  `mergedServers`, `mergedInstructions`, etc. Need to add
  `mergedLspServers` and thread it through the callback args.
- **Module-eval tests** — cover per-CLI `lspServers` HM + devenv
  writes. None for top-level fanout.

## Plan

### 1. Add `ai.lspServers` to `sharedOptions.nix`

```nix
lspServers = lib.mkOption {
  type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
  default = {};
  description = ''
    LSP servers fanned out to every enabled AI app. Per-app overrides
    (ai.<name>.lspServers) merge on top and win on conflict.
  '';
};
```

### 2. Thread `mergedLspServers` through both transforms

`hmTransform.nix` + `devenvTransform.nix` already compute:

```nix
mergedServers = config.ai.mcpServers // cfg.mcpServers;
mergedInstructions = config.ai.instructions ++ cfg.instructions;
mergedSkills = config.ai.skills // cfg.skills;
mergedRules = config.ai.rules // cfg.rules;
```

Add:

```nix
mergedLspServers = config.ai.lspServers // cfg.lspServers;
```

Pass it to the config callback. No declaration of `ai.<name>.lspServers`
needs to change — per-CLI factories already declare it in their own
`options =` blocks.

### 3. Update Kiro + Copilot factories to consume `mergedLspServers`

Today each factory reads `cfg.lspServers` directly. Switch to
`mergedLspServers`:

- `mkKiro.nix` HM: `home.file."${cfg.configDir}/settings/lsp.json".text
= builtins.toJSON mergedLspServers;` (replacing `cfg.lspServers`).
  Conditional on `mergedLspServers != {}`.
- `mkKiro.nix` devenv: same replacement.
- `mkCopilot.nix` HM + devenv: same for `lsp-config.json`.

Both factory callbacks need `mergedLspServers` added to their
destructured arg list.

### 4. Module-eval tests

Add four tests (2 HM + 2 devenv):

- `ai.lspServers.nixd = {…}` with `ai.kiro.enable = true` → Kiro
  HM writes the server to `settings/lsp.json`.
- Same, devenv → Kiro devenv writes.
- Same, `ai.copilot.enable = true` → Copilot HM writes to
  `lsp-config.json`.
- Same, Copilot devenv.

Plus one precedence test: `ai.lspServers.nixd` AND
`ai.kiro.lspServers.nixd` both set → per-CLI wins in the Kiro
output.

### 5. No doc updates needed beyond this plan

The change is additive to the existing pattern. Plan.md has no
open bullet for `ai.lspServers` — not a backlog item, just a
natural extension. The design doc (`unified-instructions-design.md`)
already mentions `ai.lspServers` as part of the transformer pattern.

### 6. Commit

Single commit: `feat(ai): add top-level ai.lspServers fanout`.
Covers sharedOptions, both transforms, Kiro/Copilot factory
plumbing, 5 tests.

## Size estimate

~20 lines factory/transform changes + ~80 lines tests + 1 commit.

## Review checklist

- [ ] `ai.lspServers` declared in `sharedOptions.nix` with same
      type as per-CLI (`attrsOf (attrsOf anything)`).
- [ ] Both transforms compute `mergedLspServers` and pass it to
      the callback.
- [ ] Kiro HM + devenv switched from `cfg.lspServers` to
      `mergedLspServers`.
- [ ] Copilot HM + devenv switched similarly.
- [ ] Per-CLI precedence (Kiro `.lspServers.foo` beats
      `ai.lspServers.foo` of the same name) — verified by test.
- [ ] No breaking change — per-CLI-only usage still works.
- [ ] Module-eval tests green; flake check green.
- [ ] Commit message notes the typed-migration deferred follow-up
      and the Claude-side absence.

## Follow-up (not this pass)

- **`ai.claude.lspServers`** — add per-CLI option to mkClaude and
  route it to `programs.claude-code.lspServers`. Upstream HM
  supports it. Top-level fanout then covers Claude automatically
  through the same `mergedLspServers` pipeline. Separate journal.
- **Typed migration.** All LSP servers (top-level + per-CLI)
  switch from `attrsOf (attrsOf anything)` to `lspServerModule`;
  per-CLI factories invoke `mkLspConfig` / `mkCopilotLspConfig`
  translators on the way to disk. Breaking for consumers using
  the freeform shape today. Separate journal.
