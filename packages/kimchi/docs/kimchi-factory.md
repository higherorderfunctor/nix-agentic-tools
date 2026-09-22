# Kimchi factory (mkKimchi)

> **Last verified:** 2026-09-21 (commit pending — devenv rejects settings that
> Kimchi reads only from user scope and guards files Kimchi resolves from its
> exact working directory). Home Manager context renders into `ai.kimchi.files`
> before the generic backend sink; devenv contributes directly to the shared
> repository `AGENTS.md` owner. Full lineage:
> `git show 54efc1e8:packages/kimchi/docs/kimchi-factory.md`.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkAiApp` participant,
closest in shape to `mkKiro` (dual config trees + activation-merge for the
mutable tree). The HM and devenv modules are thin shims that apply `hmTransform`
/ `devenvTransform` to the record.

The factory consumes Kimchi-shaped JSON from `ai.kimchi.nativeSettings`. The
closed `ai.kimchi.settings` submodule is the shared normalized surface; a field
may be present there before Kimchi has a lossless native lowering, in which case
it remains declarative data rather than being guessed into either native file.

## User and project paths (the load-bearing fact)

`ai.kimchi.configDir` controls the Home Manager output root (default
`.config/kimchi`). The pinned Kimchi 1.1.27 binary hard-codes that default for
its global config and harness, so a non-default value requires a compatible
package override; the option alone does not relocate the runtime. It does not
control devenv project paths. The backend split is:

| pool             | Home Manager user path              | devenv project path                    |
| ---------------- | ----------------------------------- | -------------------------------------- |
| context          | `<configDir>/harness/AGENTS.md`     | root `AGENTS.md`                       |
| MCP servers      | `<configDir>/harness/mcp.json`      | `.kimchi/mcp.json`                     |
| skills           | `<configDir>/harness/skills/<name>` | `.kimchi/skills/<name>`                |
| Kimchi settings  | `<configDir>/config.json`           | `.kimchi/config.json`                  |
| harness settings | `<configDir>/harness/settings.json` | `.config/kimchi/harness/settings.json` |

Project Kimchi settings, MCP servers, and harness settings are exact-cwd
readers: Kimchi checks those paths only under `process.cwd()`. When devenv
delivers any of the three, its wrapper rejects launches below the devenv root
with an actionable message. It does not silently change directories, because
that would also change the working directory seen by Kimchi's tools. Context and
skills themselves walk ancestors, but the typed Kimchi settings include a
default `skillPaths = []`, so every enabled devenv Kimchi currently delivers
project config and the wrapper is root-only. Locked by
`module-kimchi-devenv-exact-cwd-guard`.

The project harness directory is deliberately its own factory value. pi 0.85.1
derives `CONFIG_DIR_NAME` from Kimchi's packaged
`piConfig.configDir = ".config/kimchi/harness"`; its project settings watcher
resolves `<cwd>/<CONFIG_DIR_NAME>/settings.json`. This baked project namespace
does not follow `ai.kimchi.configDir`, which controls only Home Manager output.
Setting `configDir = ".config/foo"` therefore leaves the devenv harness target
unchanged (and needs a compatible package override before pinned Kimchi will
read the relocated user files).

Kimchi settings are ordinary **nested** JSON (`telemetry`, `llmEndpoint`,
`skillPaths`, `preferences`). The user harness contains runtime settings, MCP,
context, and skills.

The `harness/` tree is **mutable at runtime** — Kimchi rewrites `settings.json`
(`/multi-model`, `kimchi resources`) and downloads vendor content into it. So
the two user settings files go through `helpers.mkSettingsActivationScript` (jq
`.[0] * .[1]` merge) on Home Manager, never a raw symlink-to-store. Devenv's
Kimchi settings are a static project write. Immutable artifacts ultimately use
static `home.file` / `files.*`. Home Manager context first renders into the
final `ai.kimchi.files` map and only then reaches that generic sink. Devenv
generated context and any public Kimchi replacement or tombstone instead join
the single repository `AGENTS.md` owner shared with Codex and Kiro, preventing
competing native writers when several runtimes are enabled. The backend-native
context path remains a whole-entry consumer replacement/tombstone point; MCP and
skills retain their existing typed owners. When both root and Kimchi-specific
context are configured, their bodies concatenate root-first. Home Manager emits
the configured `ai.kimchi.context.filename`, but pinned Kimchi's global loader
discovers only `AGENTS.md`, so a custom value needs a compatible package
override. Devenv always writes `AGENTS.md`, the only project context filename
Kimchi discovers.

Kimchi's project config, MCP, skills, and harness settings remain inert until
project trust is established. Interactive trust is persisted in the user's
harness `trust.json`; lookup walks ancestors, and headless and ACP sessions
honor that decision before consulting the user-global `defaultProjectTrust`.
`--approve` supplies a run-scoped override to CLI and TUI, but not ACP, which
resolves trust again for each session without the CLI override.

The devenv module rejects every `harnessSettings` key that Kimchi reads only
from user scope: `defaultProjectTrust`, `fermentV2`, `hidePhaseChanges`,
`modelMetadata`, `modelRoles`, `multiModel`, `resources`,
`shellProfileApiKeyMigrationDismissed`, and `statusLine`. pi deliberately reads
`defaultProjectTrust` from its global settings manager so a project cannot grant
itself trust. Kimchi's implementations of the other eight read
`~/.config/kimchi/harness/settings.json` directly rather than pi's merged
project settings. Set them through Home Manager or through Kimchi's own UI and
commands, which persist to user-global files. Home Manager activation-merges the
two mutable settings files rather than symlinking them into the read-only Nix
store.

Root `AGENTS.md` is the upstream exception: Kimchi's prompt-enrichment extension
currently walks ancestor context files directly without consulting
`isProjectScopeAllowed`. Do not describe that file as trust-gated unless
upstream adds the missing check.

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
always-injected user `harness/AGENTS.md` or project-root `AGENTS.md`
(orientation tier, like Codex). It has **no** path-scoped steering (no Claude
`rules/` or Kiro `steering/` equivalent), so the scoped-fragment transforms do
not apply to it.

## Shared prep

`mkPrep` (top-level `let`) computes the backend-agnostic values (filtered
settings, effective env, agency text, the wrapped package) once; the `hm` and
`devenv` config closures each call it rather than duplicating the logic.
