## Kiro settings: a flat format with object values, and where the key stops

> **Last verified:** 2026-09-22 — the normalized reasoning-effort pool is
> explicitly excluded because Kiro persists effort only inside per-model
> `chat.modelDefaults` records. Model suggestions join the extracted sidecar
> from a public documentation snapshot, independently of CLI releases.

### Model suggestions are a public catalog, not an account entitlement list

`nativeSettings.chat.defaultModel` reads `extracted.json.models` as a soft enum.
Any string remains accepted. The model field is derived from
`model-catalog.json`, a snapshot of the names in
[Kiro's public comparison table](https://kiro.dev/docs/models.md). The other
extracted fields still come from the pinned binary.

The update script refreshes that snapshot and rebuilds the extraction on every
scheduled sweep, even when the CLI version is unchanged.
`passthru.refreshModels` exposes the same refresh for a deliberate local run.
Flake checks use only committed data and the packaged binary; no login or
network is needed inside the extraction build.

Names are normalized to lowercase, hyphenated CLI suggestions, preserving dotted
versions and the documented Sonnet 4.0 → `claude-sonnet-4` spelling. The parser
fails on unknown naming formats, duplicate IDs, malformed rows, or a missing
table. These are suggestions derived from documentation, not a claim that every
account can use every listed model. Documentation can still lag a server
rollout; the optional authenticated `check:model-staleness` compares a local
account's IDs as a subset and now fails on omissions.

The current snapshot covers all 19 IDs observed across the two accounts below.
Its `claude-fable-5.1` suggestion is inferred from the public display name; that
CLI spelling has not been verified against an authenticated account. The parser
also retains `claude-fable-5`, observed in Kiro 2.22.1's bundled
`feature-pipeline` and `semantic-review-multi-model` recipes via the token-free
ACP `_kiro/workflow/listRecipes` method. The recipe ID does not establish that
Fable 5 and 5.1 are aliases, so both suggestions are retained. An unknown naming
format or an unavailable public source fails the isolated Kiro update target,
including any simultaneous binary version bump, until the source recovers or the
normalization is reviewed.

**Settled — do not relitigate:** Kiro 2.22.1 requires login for
`chat --list-models --format json` under an isolated home. The same version
returned 14 IDs for a work account and nine for a free account on 2026-09-19,
with 19 distinct IDs between them. The native binary and its embedded archives
did not contain Opus 5 or Sonnet 5 IDs. Kiro Crew's static registry also omitted
them; newer IDs appeared in UI fixtures, not a maintained complete catalog. A
free CI account, a binary string scan, or Crew's fallback registry cannot
establish a complete suggestion list.

### Flat settings and object values

`~/.kiro/settings/cli.json` is FLAT: its keys are dotted strings, not nested
objects. `nativeSettings` lets you write the nested Nix that reads naturally and
`flattenKiroSettings` lowers it:

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
`mkKiro.nix` passes `kiroSettingKeys` — the union of two measured lists from
`packages/kiro-cli/extracted.json`:

- `settingKeys`: the bundle's own `SCREAMING -> "dotted.key"` registry, 52 keys
  at 2.21.1, all `chat.*`.
- `workspaceOverridableSettings`: the workspace allowlist, which adds 21 keys
  the registry omits — the whole `toolSearch.*`, `compaction.*` and
  `knowledge.*` families, plus ten `chat.*` keys including
  `chat.enableTangentMode`. That last one is the extractor's own PROBE anchor,
  which makes it the sharpest available evidence that the registry is not the
  settings universe: the probe the allowlist scan keys off is itself absent from
  the registry scan.

Neither alone covers the format, which is why the sidecar reports them
separately and the union is taken at the consumer. Both come out of one scan of
the chat binary (`kiroSettingsExtractScript`) because they share the registry
regex, and a second pass would be a second place for it to drift.

`flattenDotKeys` is now `flattenDotKeysUntil []` — the historical
flatten-everything behavior, unchanged for anything that does not pass a
boundary.

This per-model object is also why `ai.kiro.settings.reasoningEffort` does not
exist. Kiro has no global persisted effort key: lowering one portable scalar
would require either choosing a model or applying it to every model record. Both
change the user's request, so the factory excludes the normalized settings pool
instead of accepting a value it cannot lower losslessly. Use
`ai.kiro.nativeSettings.chat.modelDefaults.<model>.effort` for the native
per-model setting, or Kiro's session-only `--effort` flag when persistence is
not wanted.

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
