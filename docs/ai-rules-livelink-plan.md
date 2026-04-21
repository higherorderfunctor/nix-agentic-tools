# `ai.rules` live-edit support via out-of-store symlink

> **Status:** plan; proceeding autonomously.
>
> **Goal:** add `sourcePath` field to the rule submodule that
> triggers `home.file.<path>.source = mkOutOfStoreSymlink …` on HM
> instead of baking content into the store. Lets consumers edit the
> source `.md` file and see changes live without `home-manager
switch`. Closes the miss flagged in `session-handoff-2026-04-21.md`
> that blocks clean migration of the consumer's 15 kiro steering
> files.

## Why

Today `ai.<cli>.rules.<name>.text` accepts `lines | path`. Either
form bakes content into the store:

- `lines` → written via `.text = <rendered>` with transformer
  frontmatter.
- `path` (Nix literal) → `readFile`ed at eval time, rendered the
  same way.

Neither preserves live-edit. The consumer's current
`mkOutOfStoreSymlink` helper points `.kiro/steering/foo` at
`~/…/kiro-config/steering/foo` on disk — edits propagate without
rebuild.

## Approach

New field `sourcePath` on `ruleModule` (nullable string, default
`null`). Mutually exclusive with `text`:

- When `sourcePath != null`: HM emits
  `home.file.".kiro/steering/${name}.md".source =
config.lib.file.mkOutOfStoreSymlink rule.sourcePath;` — **no
  transformer frontmatter injection**. The user's source file owns
  its own `inclusion: always` etc.
- When `text` is set (the normal case): behavior unchanged — bake
  content with transformer frontmatter.

## Trade-offs

- Users who want live-edit forgo transformer-generated frontmatter.
  They manage `inclusion:` / `applyTo:` / `paths:` themselves in the
  source file.
- Consumer's 15 kiro steering files are mostly `inclusion: always`
  — they'd add one line of frontmatter per file (or skip it —
  untagged markdown under `.kiro/steering/` is always-loaded per
  kiro.dev docs).
- Trade is explicit and documented on the option.

## Devenv side

`home.file.*.source = mkOutOfStoreSymlink …` is HM-only.
Devenv's `files.*.source` is `types.path` and gets `ln -s`ed
directly at createFileScript time. Passing an absolute string
path to it creates a symlink to the filesystem — live-edit works
IF nix accepts the string as a `path` type (it coerces `/abs`
strings in many contexts).

For the MVP: devenv emission uses `files.<name>.source = rule.sourcePath`
as a string. If devenv's type check rejects this at eval, devolve
to baking (still correct, just loses live-edit in devenv).
Consumer cares about HM; devenv live-edit is a nice-to-have.

## Schema changes

`lib/ai/ai-common.nix` `ruleModule`:

```nix
sourcePath = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;
  description = ''
    Absolute filesystem path for out-of-store symlink emission.
    Preserves live-edit (edits to the source file are visible
    immediately without rebuild). When set, `text` is ignored and
    transformer frontmatter is NOT injected — manage
    frontmatter in the source file directly. Mutually exclusive
    with `text`.
  '';
  example = "/home/user/.config/kiro/steering/foo.md";
};
```

Relax `text` to `nullOr (either lines path)` default `null` so
`sourcePath`-only declarations don't require setting a dummy
`text`.

Assertion in each per-CLI factory: exactly one of `text` or
`sourcePath` must be set per rule.

## Factory wiring

Thread `config` through transform callbacks so factories can call
`config.lib.file.mkOutOfStoreSymlink`.

Per-CLI rules emission pattern:

```nix
home.file = lib.mapAttrs' (name: rule:
  lib.nameValuePair ".claude/rules/${name}.md" (
    if rule.sourcePath != null
    then { source = config.lib.file.mkOutOfStoreSymlink rule.sourcePath; }
    else { text = fragmentsLib.mkRenderer claudeTransformer { package = name; } (rule // { text = resolveRuleText rule; }); }
  ))
mergedRules;
```

Same shape for kiro (kiroTransformer) and copilot (copilotTransformer).

For devenv: `files.<path>.source = rule.sourcePath` when set (no
`mkOutOfStoreSymlink` equivalent needed — devenv's source is
identity).

## Tests

Add HM tests:

- Rule with `sourcePath` emits `home.file.<path>.source` pointing
  at a mkOutOfStoreSymlink value (not `.text`).
- Rule with `sourcePath` does NOT get transformer frontmatter
  baked (assert `.text` is unset).
- Rule with `text` continues to work unchanged (regression).
- Assertion fires when both `text` and `sourcePath` are set on
  the same rule.

Devenv: smoke test that `sourcePath` lands in `files.<path>.source`.

## Consumer migration preview (documentation only this session)

```nix
# In nixos-config ai/default.nix, replaces kiroSymlinkSteering
# helper + kiroSteeringFiles list.
ai.kiro.rules =
  lib.mapAttrs
  (name: _: {
    sourcePath = "${kiroConfigPath}/steering/${name}";
  })
  (lib.filterAttrs
    (n: _: lib.hasSuffix ".md" n)
    (builtins.readDir (kiroConfigPath + "/steering")));
```

~20 lines in the consumer swapped for auto-discovery of the
steering dir. Factory handles the rest.

## Out of scope

- Live-edit for `ai.context` (single file). Same technique would
  apply; can be a follow-up. Consumer's context uses
  `./claude-config/global-instructions.md` (baked path) today and
  seems fine with rebuild semantics.
- Live-edit for `ai.skills` / `ai.agents` / `ai.mcpServers`.
  Different emission patterns; separate design if needed.
- `rulesDir` bulk-symlink option. Can be implemented later as a
  sugar layer over per-entry `sourcePath`.

## Commit

Single commit: `feat(ai): ai.rules sourcePath for out-of-store
live-edit`.

## Implementation pivots (diverged from plan)

- **Test harness missing `config.lib.file.mkOutOfStoreSymlink`.**
  Real HM injects `config.lib` with `file.mkOutOfStoreSymlink`,
  `dag.*`, etc. Module-eval stub harness
  (`checks/module-eval.nix` `hmStubs`) doesn't provide it, so the
  typed-LSP-style test eval errors with
  `attribute 'lib' missing` on `config.lib.file...`.

  **Pivot:** extend `hmStubs` with a stubbed `config.lib.file.mkOutOfStoreSymlink`
  option that's an identity function (returns the path string
  unchanged). Tests then assert on presence of `.source` vs
  `.text`, not the exact mkOutOfStoreSymlink return shape.
  Documented in the commit.

- **Initial plan passed `config` to devenv callback too.** Set up
  both `hmTransform.nix` and `devenvTransform.nix` to thread
  `config` through. Deadnix flagged `config` as unused in
  copilot/kiro devenv signatures (only HM uses
  `config.lib.file.mkOutOfStoreSymlink`; devenv uses raw
  `rule.sourcePath` → `files.<path>.source` without wrapping).

  **Pivot:** stop passing `config` in `devenvTransform.nix`'s
  callback args — only HM needs it. Removed `config,` from
  copilot + kiro devenv signatures. Devenv has no
  mkOutOfStoreSymlink equivalent; if live-edit doesn't work in
  devenv, it's a nix types.path coercion concern, not a
  factory-reachable feature.

## Review checklist

- [ ] `sourcePath` added to `ruleModule`; `text` relaxed to
      nullable.
- [ ] Mutual-exclusivity assertion emitted per rule.
- [ ] `config` threaded through hmTransform / devenvTransform
      callbacks.
- [ ] Claude/Kiro/Copilot HM emissions check `sourcePath` and use
      `mkOutOfStoreSymlink` when set.
- [ ] Devenv emissions use `files.*.source = rule.sourcePath`.
- [ ] Existing rules tests still pass.
- [ ] New tests cover sourcePath emission + assertion.
- [ ] `nix flake check` green.
