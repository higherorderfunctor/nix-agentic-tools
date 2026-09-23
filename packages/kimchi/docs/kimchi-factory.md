# Kimchi factory (mkKimchi)

> **Last verified:** 2026-09-23 — `mcp.json` is reconciled by leaf like the
> other two JSON documents; normalized reasoning effort lowers to harness
> `defaultThinkingLevel`. Home Manager retains Kimchi's user paths while devenv
> uses the pinned runtime's project paths. Both mutable documents still reach
> the shared delivery router. Full lineage:
> `git show 54efc1e8:packages/kimchi/docs/kimchi-factory.md`.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkRuntime` participant,
closest in shape to `mkKiro` (dual config trees + activation-merge for the
mutable tree). The HM and devenv modules are thin shims that apply `hmTransform`
/ `devenvTransform` to the record.

Its shared local delivery function describes each file: its bytes, consumer
facts, and writer if it is not a symlink. Both backend callbacks use that same
function with the merged pools supplied by `mkBackendTransform.nix`, and
`lib/ai/deliver.nix` decides how each entry lands. The other runtimes retain
their existing callbacks during the staged migration.

The factory consumes Kimchi-shaped JSON from `ai.kimchi.native.settings` and
`ai.kimchi.native.harnessSettings`. The closed `ai.kimchi.settings` submodule is
the shared normalized surface. Its `reasoningEffort` field lowers losslessly to
`native.harnessSettings.defaultThinkingLevel` at `mkDefault` priority, so an
explicit native harness value wins: pi 0.85.1's `ThinkingLevel` is a superset of
the normalized enum, and pi reads the key from the merged user and project
harness settings. Locked by `module-kimchi-normalized-reasoning-effort`.

## User and project paths (the load-bearing fact)

`ai.kimchi.configDir` controls the Home Manager output root (default
`.config/kimchi`). It does not control devenv project paths. The backend split
is:

| pool             | Home Manager user path              | devenv project path                    |
| ---------------- | ----------------------------------- | -------------------------------------- |
| context          | `<configDir>/harness/AGENTS.md`     | root `AGENTS.md`                       |
| MCP servers      | `<configDir>/harness/mcp.json`      | `.kimchi/mcp.json`                     |
| skills           | `<configDir>/harness/skills/<name>` | `.kimchi/skills/<name>`                |
| Kimchi settings  | `<configDir>/config.json`           | `.kimchi/config.json`                  |
| harness settings | `<configDir>/harness/settings.json` | `.config/kimchi/harness/settings.json` |

Project Kimchi settings, MCP servers, and harness settings are exact-cwd
readers. The devenv wrapper rejects launches below the devenv root instead of
silently missing them. Context and skills walk ancestors, but the typed Kimchi
settings include a default `skillPaths = []`, so every enabled devenv Kimchi
currently delivers project config and receives the root-only guard. Locked by
`module-kimchi-devenv-exact-cwd-guard`.

The project harness directory is deliberately fixed. pi derives
`CONFIG_DIR_NAME` from Kimchi's packaged
`piConfig.configDir = ".config/kimchi/harness"`; its project settings watcher
resolves `<cwd>/<CONFIG_DIR_NAME>/settings.json`. This namespace does not follow
`ai.kimchi.configDir`.

Kimchi settings are ordinary **nested** JSON (`telemetry`, `llmEndpoint`,
`skillPaths`, `preferences`). The user harness contains runtime settings, MCP,
context, and skills.

The `harness/` tree is **mutable at runtime** — Kimchi rewrites `settings.json`
(`/multi-model`, `kimchi resources`) and downloads vendor content into it.
`mcp.json` is written too, on both backends, and always by renaming a temporary
over the path, which silently replaces a store symlink: 1.1.30's first-run
migration (`src/setup-wizard.ts:117-137`) and ACP import
(`src/modes/acp/ext-methods/import-apply.ts:289`) write the user file, and
`/mcp enable|disable` writes the project file through the patched pi-mcp-adapter
2.34.0 (`config.ts:1142-1147`). So `config.json`, `harness/settings.json` and
`mcp.json` each state `facts.harnessWrites` and name an `ai.kimchi.activation`
writer that declares their ledger: the rule resolves them to `shared`, and the
router builds one `lib/ai/own.nix` bundle and one activation entry or devenv
task per document, reconciling only the leaves Nix declares against a
per-document ledger. A migrated server or a `disabled` toggle Kimchi adds is an
unowned sibling the reconciler keeps. The three are separate writers on purpose:
nothing orders them against each other, and each entry name is a
consumer-visible contract. Devenv requires namespaced task names, so each writer
uses backend-keyed `entry`: `ai:kimchi:config-merge`,
`ai:kimchi:harness-settings-merge` and `ai:kimchi:mcp-merge` on devenv, with
`kimchiConfigMerge`, `kimchiHarnessSettingsMerge` and `kimchiMcpMerge` on HM.
Locked by `module-kimchi-hm-mcp-reconciled`,
`module-kimchi-devenv-project-paths` and the `ai-delivery` policy rows. Home
Manager ledger names continue to hash `configDir`, preserving ownership from
generations before project-path delivery; devenv's new ledgers hash their actual
project document paths.

All three files state `facts.harnessWrites = true`, and every writer survives an
empty declaration on either backend, so removing the last MCP server retracts
it. HM uses `$HOME` and XDG state; devenv uses `$DEVENV_ROOT` and
`$DEVENV_STATE/nix-agentic-tools`. New documents are 0600 and existing regular
files retain their modes. Empty harness settings release all owned leaves; empty
native settings still declare the typed `skillPaths = []` default. A file
tombstone releases that final claim too.

Everything else Kimchi delivers is immutable and symlink-readable, so it takes
both defaults and states no fact at all. Normalized context renders into the
`ai.kimchi.files` map on Home Manager. Devenv context joins the single root
`AGENTS.md` owner shared with Codex and Kiro. In either backend, the generated
body is a default on the entry's `content` option, so a consumer can replace or
suppress it. When root and Kimchi-specific context are both configured, their
bodies concatenate root-first. Home Manager honors `ai.kimchi.context.filename`;
devenv always writes `AGENTS.md`.

Project config, MCP, skills, and harness settings remain inert until project
trust is established. Interactive trust persists in the user's harness
`trust.json`; headless and ACP sessions honor that decision or the user-global
`defaultProjectTrust`. Root `AGENTS.md` is the upstream exception: Kimchi's
context loader walks ancestors directly without consulting the project-scope
gate.

The devenv module rejects every `harnessSettings` key Kimchi reads only from
user scope: `defaultProjectTrust`, `fermentV2`, `hidePhaseChanges`,
`modelMetadata`, `modelRoles`, `multiModel`, `resources`,
`shellProfileApiKeyMigrationDismissed`, and `statusLine`. Set these with Home
Manager or through Kimchi itself. Home Manager and devenv reconcile the mutable
JSON documents by owned leaf, preserving runtime-written siblings.

## Normalized pool capability boundary

The app record's `supportedPools` is exactly `context`, `environmentVariables`,
`mcpServers`, `settings`, and `skills`. Kimchi has no native path-scoped rules,
portable agents, LSP, portable hooks, or shell-selection landing key. Those
per-runtime normalized options are absent; root values for them remain valid and
silently degrade for Kimchi. `settings` is the uniform closed normalized
namespace; its current field lowers to `defaultThinkingLevel` in the mutable
harness settings document.

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
always-injected user `harness/AGENTS.md` or project-root `AGENTS.md`
(orientation tier, like Codex). It has **no** path-scoped steering (no Claude
`rules/` or Kiro `steering/` equivalent), so the scoped-fragment transforms do
not apply to it.

## Shared prep

`mkPrep` (top-level `let`) computes the backend-agnostic values (filtered
settings, effective env, agency text, and the wrapped package). The shared
delivery function and the `installPackage` hook each call it rather than
duplicating that logic.
