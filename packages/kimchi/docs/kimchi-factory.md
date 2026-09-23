# Kimchi factory (mkKimchi)

> **Last verified:** 2026-09-22 — native file settings live under
> `ai.<runtime>.native` (`native.settings`; Kimchi also
> `native.harnessSettings`). Both runtime-writable documents reconcile their
> owned leaves through `lib/ai/own.py`, one bundle and one activation entry
> each, and the context entry defaults its `content` option rather than the
> whole entry. Full lineage:
> `git show 54efc1e8:packages/kimchi/docs/kimchi-factory.md`.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkAiApp` participant,
closest in shape to `mkKiro` (dual config trees + activation-merge for the
mutable tree). The HM and devenv modules are thin shims that apply `hmTransform`
/ `devenvTransform` to the record.

The factory consumes Kimchi-shaped JSON from `ai.kimchi.native.settings`. The
closed `ai.kimchi.settings` submodule is the shared normalized surface; a field
may be present there before Kimchi has a lossless native lowering, in which case
it remains declarative data rather than being guessed into either native file.

## Two config trees (the load-bearing fact)

Kimchi splits config across two roots under `<configDir>` (default
`.config/kimchi`):

- `config.json` — account/CLI settings (`telemetry`, `llmEndpoint`,
  `skillPaths`, `preferences`). Ordinary **nested** JSON.
- `harness/` — agent runtime: `settings.json` (`modelRoles`, `resources`),
  `mcp.json`, `AGENTS.md`, `skills/`.

The `harness/` tree is **mutable at runtime** — Kimchi rewrites `settings.json`
(`/multi-model`, `kimchi resources`) and downloads vendor content into it. So
`config.json` and `harness/settings.json` each go through
`helpers.mkOwnedDocument` on HM — one `lib/ai/own.nix` bundle and one activation
entry per document, reconciling only the leaves Nix declares against a
per-document ledger — and a static write on devenv, never a raw
symlink-to-store. The two are separate bundles on purpose: nothing orders them
against each other, and each entry name is a consumer-visible contract.
Immutable artifacts ultimately use static `home.file` / `files.*`, but
normalized context first renders into the final `ai.kimchi.files` map and only
then reaches that generic sink. This makes `harness/AGENTS.md` a consumer
replacement point: the generated body is a default on the entry's `content`
option alone, so a consumer replaces the bytes, changes how the file lands, or
suppresses it with `null`, independently; `mcp.json` and skills retain their
existing typed owners. When both root and Kimchi-specific context are
configured, their bodies concatenate root-first; `ai.kimchi.context.filename`
controls the artifact name.

## Normalized pool capability boundary

The app record's `supportedPools` is exactly `context`, `environmentVariables`,
`mcpServers`, `settings`, and `skills`. Kimchi has no native path-scoped rules,
portable agents, LSP, portable hooks, or shell-selection landing key. Those
per-runtime normalized options are absent; root values for them remain valid and
silently degrade for Kimchi. `settings` is the uniform closed normalized
namespace; its current field has no Kimchi-native lowering.

The three keyed pools Kimchi consumes (`environmentVariables`, `mcpServers`, and
`skills`) follow the shared atomic replacement rule. A Kimchi-specific same-key
value replaces the root entry wholesale; null suppresses it before Kimchi's
wrapper or file emitters run.

In particular, `ai.kimchi.rules` and `ai.kimchi.rulesDir` do not exist. Do not
restore them in anticipation of future rules support: Kimchi's rules support is
deliberately unimplemented.

## Gotcha: config.json is NESTED, not flat

Do **not** run `config.json` settings through `aiCommon.flattenDotKeysUntil` —
that helper is Kiro-specific (Kiro's `cli.json` wants flat dot keys like
`chat.enableTangentMode`). Kimchi's `config.json` is nested JSON; flattening
turns `settings.telemetry.enabled` into a literal `"telemetry.enabled"` string
key Kimchi cannot read. Locked by `module-kimchi-config-json-nested`.

## Gotcha: apiKey is a runtime SOPS credential, never a store literal

`apiKey` is `lib.mcp.mkCredentialsOption "KIMCHI_API_KEY"` — the same
`{ file | helper }` discriminated union the MCP servers use. The key is exported
at launch via `lib.mcp.mkCredentialsSnippet`
(`KIMCHI_API_KEY="$(<coreutils>/bin/cat <file>)"`) injected through
`wrapProgram --run`, so the decrypted secret is read at runtime and the store
holds only the **path**, never the key. Never reintroduce a plaintext `str`
apiKey funneled into `--set`: that bakes the secret into a world-readable
`/nix/store` wrapper. Mimic the existing credential pattern; do not invent a new
secret surface.

## Gotcha: wrapProgram separator

Join `wrapProgram` flags with a single space — `lib.concatStringsSep " "`,
matching `mkKiro` / `mkCopilot`. A `" \<newline>  "` separator inside a regular
Nix string collapses the backslash, so with two or more env vars the second
`--set` runs as its own command → `exit 127`. The package is wrapped in **both**
backends (the wrapper owns the env vars and the credential export), so HM and
devenv stay at parity by construction. Locked by `module-kimchi-wrapper-builds`.

## Orientation-only steering

`defaults.outputPath = null` and
`transformers.markdown = lib.ai.transformers.agentsmd`: Kimchi takes a flat,
always-injected `harness/AGENTS.md` (orientation tier, like Codex). It has
**no** path-scoped steering (no Claude `rules/` or Kiro `steering/` equivalent),
so the scoped-fragment transforms do not apply to it.

## Shared prep

`mkPrep` (top-level `let`) computes the backend-agnostic values (filtered
settings, effective env, agency text, the wrapped package) once; the `hm` and
`devenv` config closures each call it rather than duplicating the logic.
