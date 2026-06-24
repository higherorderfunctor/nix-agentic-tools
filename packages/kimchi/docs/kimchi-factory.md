# Kimchi factory (mkKimchi)

> **Last verified:** 2026-06-23 (commit pending). If you touch
> `packages/kimchi/lib/mkKimchi.nix`, `packages/kimchi/modules/**`,
> or the Kimchi credential / wrapper handling and this fragment isn't
> updated in the same commit, stop and fix it.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkAiApp` participant,
closest in shape to `mkKiro` (dual config trees + activation-merge for the
mutable tree). The HM and devenv modules are thin shims that apply
`hmTransform` / `devenvTransform` to the record.

## Two config trees (the load-bearing fact)

Kimchi splits config across two roots under `<configDir>` (default
`.config/kimchi`):

- `config.json` — account/CLI settings (`telemetry`, `llmEndpoint`,
  `skillPaths`, `preferences`). Ordinary **nested** JSON.
- `harness/` — agent runtime: `settings.json` (`modelRoles`, `resources`),
  `mcp.json`, `AGENTS.md`, `skills/`.

The `harness/` tree is **mutable at runtime** — Kimchi rewrites
`settings.json` (`/multi-model`, `kimchi resources`) and downloads vendor
content into it. So `config.json` and `harness/settings.json` go through
`helpers.mkSettingsActivationScript` (jq `.[0] * .[1]` merge) on HM and a
static write on devenv — never a raw symlink-to-store. The immutable parts
(`mcp.json`, `AGENTS.md`, `skills/`) are static `home.file` / `files.*`.

## Gotcha: config.json is NESTED, not flat

Do **not** run `config.json` settings through `aiCommon.flattenDotKeys` —
that helper is Kiro-specific (Kiro's `cli.json` wants flat dot keys like
`chat.enableTangentMode`). Kimchi's `config.json` is nested JSON; flattening
turns `settings.telemetry.enabled` into a literal `"telemetry.enabled"`
string key Kimchi cannot read. Locked by `module-kimchi-config-json-nested`.

## Gotcha: apiKey is a runtime SOPS credential, never a store literal

`apiKey` is `lib.mcp.mkCredentialsOption "KIMCHI_API_KEY"` — the same
`{ file | helper }` discriminated union the MCP servers use. The key is
exported at launch via `lib.mcp.mkCredentialsSnippet`
(`KIMCHI_API_KEY="$(<coreutils>/bin/cat <file>)"`) injected through
`wrapProgram --run`, so the decrypted secret is read at runtime and the
store holds only the **path**, never the key. Never reintroduce a plaintext
`str` apiKey funneled into `--set`: that bakes the secret into a
world-readable `/nix/store` wrapper. Mimic the existing credential pattern;
do not invent a new secret surface.

## Gotcha: wrapProgram separator

Join `wrapProgram` flags with a single space — `lib.concatStringsSep " "`,
matching `mkKiro` / `mkCopilot`. A `" \<newline>  "` separator inside a
regular Nix string collapses the backslash, so with two or more env vars the
second `--set` runs as its own command → `exit 127`. The package is wrapped
in **both** backends (the wrapper owns the env vars and the credential
export), so HM and devenv stay at parity by construction. Locked by
`module-kimchi-wrapper-builds`.

## Orientation-only steering

`defaults.outputPath = null` and `transformers.markdown =
lib.ai.transformers.agentsmd`: Kimchi takes a flat, always-injected
`harness/AGENTS.md` (orientation tier, like Codex). It has **no** path-scoped
steering (no Claude `rules/` or Kiro `steering/` equivalent), so the
scoped-fragment transforms do not apply to it.

## Shared prep

`mkPrep` (top-level `let`) computes the backend-agnostic values (filtered
settings, effective env, agency text, the wrapped package) once; the `hm`
and `devenv` config closures each call it rather than duplicating the logic.
