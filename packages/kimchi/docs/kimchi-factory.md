# Kimchi factory (mkKimchi)

> **Last verified:** 2026-08-16 (commit pending — normalized context now renders
> into `ai.kimchi.files` before the generic backend sink, making the final
> `harness/AGENTS.md` replaceable or suppressible as one whole entry). Prior:
> 2026-08-15 (commit pending — Kimchi's normalized environment-variable pool now
> accepts null tombstones, so a runtime entry can suppress a same-key portable
> root default). Prior: 2026-08-15 (commit pending — Kimchi's typed context now
> composes root-first with runtime context into the existing
> `harness/AGENTS.md`; the retired instructions pool is no longer part of the
> capability census, and rules continue to degrade because Kimchi has no rules
> pool). Prior: 2026-08-15 (commit pending — records Kimchi's normalized pool
> capability census and deliberate absence of rules; native JSON passthrough
> moved to `ai.kimchi.nativeSettings`, while the uniform closed
> `ai.kimchi.settings` surface does not change the two-file native lifecycle).
> Prior: 2026-06-23 (commit pending). If you touch
> `packages/kimchi/lib/mkKimchi.nix`, `packages/kimchi/modules/**`, or the
> Kimchi credential / wrapper handling and this fragment isn't updated in the
> same commit, stop and fix it.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkAiApp` participant,
closest in shape to `mkKiro` (dual config trees + activation-merge for the
mutable tree). The HM and devenv modules are thin shims that apply `hmTransform`
/ `devenvTransform` to the record.

The factory consumes Kimchi-shaped JSON from `ai.kimchi.nativeSettings`. The
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
`config.json` and `harness/settings.json` go through
`helpers.mkSettingsActivationScript` (jq `.[0] * .[1]` merge) on HM and a static
write on devenv — never a raw symlink-to-store. Immutable artifacts ultimately
use static `home.file` / `files.*`, but normalized context first renders into
the final `ai.kimchi.files` map and only then reaches that generic sink. This
makes `harness/AGENTS.md` a whole-entry consumer replacement/tombstone point;
`mcp.json` and skills retain their existing typed owners. When both root and
Kimchi-specific context are configured, their bodies concatenate root-first;
`ai.kimchi.context.filename` controls the artifact name.

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

Do **not** run `config.json` settings through `aiCommon.flattenDotKeys` — that
helper is Kiro-specific (Kiro's `cli.json` wants flat dot keys like
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
