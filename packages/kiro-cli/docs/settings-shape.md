## Kiro settings: a flat format with object values, and where the key stops

> **Last verified:** 2026-10-15 — the TUI source is decoded statically from each
> release; runtime surfaceSupport declarations own normalized backend reach and
> nested delivery diagnostics. Unknown complete settings keys warn; Home Manager
> permits them, while devenv refuses every key outside the workspace allowlist.
> Both backends expose the spelling allowlist.

**Settled — do not relitigate:** Native `settings list --all` is not a
substitute for the TUI workspace contract. It reports 60 workspace keys while
the shipped TUI merge allows 23, including in 2.22.1. The package's
project-local guard must follow the TUI consumer, so extraction uses the
materialized source.

### Model suggestions

`cli.native.settings.chat.defaultModel` accepts any string and suggests model
slugs from the independently pinned `kiro-model-catalog` package. Its
public-document source, refresh and parsing contract live in
[model-catalog.md](../../kiro-model-catalog/docs/model-catalog.md). The binary
facts under `packages/kiro-cli/extracted/` contain only engine and settings
measurements.

### Flat settings and object values

`~/.kiro/settings/cli.json` is FLAT: its keys are dotted strings, not nested
objects. `cli.native.settings` lets you write the nested Nix that reads
naturally and `flattenKiroSettings` lowers it:

```nix
{ mcp.loadedBefore = true; chat.enableTangentMode = true; }
# -> {"mcp.loadedBefore": true, "chat.enableTangentMode": true}
```

The trap is that **flat keys do not imply scalar values.** `chat.modelDefaults`
is one key whose value is an object of per-model records. Attrset shape alone
cannot tell that apart from two more levels of grouping, so a walk that flattens
everything writes

```json
{ "chat.modelDefaults.claude-opus-5.effort": "high" }
```

which kiro never matches — it compares the literal key it reads. Nothing errors;
the setting simply does not exist. That held on BOTH backends, so the option was
not a devenv-scope problem, it was unusable.

### The boundary is extracted, not guessed

`aiCommon.flattenDotKeysUntil` takes a list of dotted paths that are complete
setting keys and stops recursing the moment the accumulated path is one of them.
`mkKiro.nix` passes `kiroSettingKeys` — the union of two measured lists from the
`packages/kiro-cli/extracted/` facts, read through `lib.extracted` (each host's
raw measures them; consumers read the merged value):

- `settingKeys`: the bundle's own `SCREAMING -> "dotted.key"` registry, 55 keys
  at 2.23.0, all `chat.*`.
- `workspaceOverridableSettings`: the workspace allowlist, which adds 21 keys
  the registry omits — the whole `toolSearch.*`, `compaction.*` and
  `knowledge.*` families, plus ten `chat.*` keys including
  `chat.enableTangentMode`. That last one is the extractor's own PROBE anchor,
  which makes it the sharpest available evidence that the registry is not the
  settings universe: the probe the allowlist scan keys off is itself absent from
  the registry scan.

Neither alone covers the format, which is why the extractor reports them
separately and the union is taken at the consumer. Since 2.23.0 the chat binary
embeds its TUI source as a zstd frame followed by the payload's SHA-256 hex.
`extract/embedded-tui.py` decodes the one bun-script frame whose checksum sits
right after it, without running the binary, so each platform's release is read
on Linux. TypeScript AST checks then locate the registry, the allowlist, and the
workspace merge that uses it. The two validated expressions and the selected
merge helper are evaluated with inert loaders and dynamic code generation
disabled.

`flattenDotKeys` is now `flattenDotKeysUntil []` — the historical
flatten-everything behavior, unchanged for anything that does not pass a
boundary.

This per-model object is also why `ai.kiro.settings.reasoningEffort` does not
exist. Kiro has no global persisted effort key: lowering one portable scalar
would mean choosing a model, or writing it into every model's record. Both
change what the user asked for. So the factory declares
`surfaceSupport.settings.backends = []`, and an unsupported pool declares no
per-runtime option. The root `ai.settings.reasoningEffort` warns for Kiro
because Kiro persists settings such as effort only per model in
`chat.modelDefaults`, so normalized settings have no lossless target. For
reasoning effort, use
`ai.kiro.cli.native.settings.chat.modelDefaults.<model>.effort` for the native
per-model value, or Kiro's session-only `--effort` flag when persistence is not
wanted.

### Unknown complete keys warn

The generic `lib/open-keys` inspector checks the flattened file as one struct
level. Every dotted key stays one literal name, and each known value is opaque:
`chat.modelDefaults` accepts arbitrary model names and fields without treating
them as setting keys. The known names come from `kiroSettingKeys`, plus the
existing typed `telemetry.enabled` option that neither extracted list names.
These facts are not a complete nested schema.

An unknown key such as `chat.defautModel` warns with a suggestion for
`chat.defaultModel` on Home Manager and devenv. Home Manager writes it
unchanged, keeping new upstream keys usable before the facts catch up. The
warning is computed at config level and emitted only when the backend declares
`warnings`. Devenv refuses every key outside its measured workspace allowlist,
including unrecognized names, because Kiro silently discards them at that scope.

`ai.kiro.cli.allowUnrecognizedSettings` suppresses spelling warnings for
intentional unknown keys on both backends; it never bypasses devenv's workspace
guard. Entries are paths: dots separate fields, `*` selects a map member and
`[]` selects a list element. Quote a literal dotted name, for example
`[''"chat.futureSetting"'']`, since Kiro's flattened settings keys are literal
names. An entry that becomes known warns as stale and should be removed.

<!-- cspell:ignore defaut -->

### What this does and does not fix

It fixes the WRITTEN SHAPE. A key still has to be one kiro honors at that scope:
under devenv the workspace allowlist applies on top, so `chat.modelDefaults`
works there and `telemetry.enabled` does not. See
[`workflow-gating.md`](workflow-gating.md) for that half.

It also removes a misleading diagnostic. The devenv workspace guard reports the
WRITTEN key, so before the boundary existed it named
`chat.modelDefaults.claude-opus-5.effort` as a rejected key — true, but the
fault was the flattener walking past the key, not the allowlist. The two now
agree by construction.

### If a future setting is still written wrong

The boundary only knows the keys the binary names. A setting absent from both
lists flattens all the way, so an object-valued one added outside the registry
would regress silently — the same failure this fixed, in a key nobody measured.
`module-kiro-devenv-object-valued-setting-stays-nested` and its HM twin pin the
behavior; `module-kiro-scalar-setting-still-flattens` is the control that the
walk does not stop EARLY, which would write nested `{"chat":{...}}` that kiro
cannot read either.
