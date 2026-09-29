# Kimchi factory (mkKimchi)

> **Last verified:** 2026-09-28 — Kimchi 1.1.37 delivers every managed settings
> file as a read-only copy. Home Manager also owns config.json and trust.json;
> devenv writes project files only. The HM option types seed values that would
> otherwise require writes at launch, and region is required. The pinned pi
> dependency is 0.85.1. Full lineage:
> `git show f5ecf77b:packages/kimchi/docs/kimchi-factory.md`.

`packages/kimchi/lib/mkKimchi.nix` is an `lib.ai.app.mkRuntime` participant,
closest in shape to `mkKiro` (dual config trees, settings as read-only copies).
The HM and devenv modules are thin shims that apply `hmTransform` /
`devenvTransform` to the record.

Its record-level `config`, `kimchiDelivery`, describes each file: its bytes,
consumer facts, and writer if it is not a symlink. It serves both backends,
reading `backend` for the paths only one of them has, with the merged pools
supplied by `mkBackendTransform.nix`, and `lib/ai/deliver.nix` decides how each
entry lands. One record-level `installPackage` likewise serves both, adding the
exact-cwd guard on devenv only.

The factory consumes Kimchi-shaped JSON from `ai.kimchi.native.settings` and
`ai.kimchi.native.harnessSettings`. The closed `ai.kimchi.settings` submodule is
the shared normalized surface. Its `reasoningEffort` field lowers losslessly to
`native.harnessSettings.defaultThinkingLevel` at `mkDefault` priority, so an
explicit native harness value wins: pi 0.85.1's `ThinkingLevel` is a superset of
the normalized enum, and pi reads the key from the merged user and project
harness settings. Locked by `module-kimchi-normalized-reasoning-effort`. On
devenv the key lands in the project harness `settings.json`, so a root effort
alone creates that exact-cwd, trust-gated file: Kimchi applies it only in a
trusted project, and the wrapper refuses launches below the devenv root. That is
the uniform consequence of any project harness setting, and the only way to
deliver effort at project scope.

Model selection is configuration Nix owns. Kimchi 1.1.37 would otherwise pick
Auto itself: it installs Auto as the saved default and writes the user harness
`settings.json` unless that file carries `autoDefaultApplied: true` (the trigger
and the write are described at the declaration in `mkKimchi.nix`). So whenever
HM manages that document it declares both:

- **The model**: `defaultProvider = "kimchi-dev"` and `defaultModel = "auto"`,
  at priority 1200 (`autoModelPriority`), below `mkDefault`. Both defaults are a
  module of the HM option _type_ (`hmHarnessDefaults`), not a definition of the
  option: an outer definition sits at normal priority, so the outer option's
  `filterOverrides` would drop a consumer's whole-attrset
  `harnessSettings = lib.mkDefault {…}` before the submodule saw it. That is why
  `native` is declared per backend. The pair is coupled: a consumer who declares
  either half at `mkDefault` or stronger, `null` included, gets neither half
  from the module, so a lone `defaultModel` on another provider never pairs with
  `kimchi-dev`, and `defaultModel = null` opts out of both. A weaker declaration
  (`mkOptionDefault`, `mkOverride` above 1200) loses to the default, and
  `mkOverride 1200` is a conflict error. The test reads each option's
  `highestPrio` inside the submodule, which looks at definition priorities and
  not values, so it cannot recurse. The shared `ai.settings` surface has no
  model field, so these two native keys are the only declaration path.
  - **Mostly a lock.** Kimchi tries to persist a startup `--model` given over a
    routed Auto default (`auto-model/index.ts:215-229`), as it does `/model`
    set-default, the `set_model` tool and ACP model changes, through pi's
    in-place settings write (`dist/core/settings-manager.js:101`). That write
    fails on the read-only copy and is caught, so the choice lasts the session.
    pi keeps the failed fields queued, though: if one of Kimchi's rename writers
    (`src/config/json.ts:154-160`: status line, model roles, resources, the
    shell-profile dismissal) has replaced the copy mid-session, pi's next save
    lands the queued model in the replacement, and it holds until the next
    activation restores the declaration.
  - **Multi-model.** Any saved default, Auto included, turns off the global
    `multiModel` default on a fresh launch whose model is not on `kimchi-dev`
    (`auto-model/index.ts:104-106,255-259`). An account whose catalog lacks Auto
    still starts, because pi 0.85.1 silently falls back to the model it picks
    when none is declared, but that fallback runs with multi-model off.
    `multiModel = true` needs `defaultModel = null`.
- **The marker**: `autoDefaultApplied = true` at `mkDefault`. It matters when
  the consumer declares a non-Auto `kimchi-dev` model or nulls the pair. Both
  explicit overrides are traps: Kimchi reads only `=== true`, installs Auto and
  renames a file carrying `true` over the copy, and every activation restores a
  copy that carries `false` or no marker at all, so Auto is reinstalled on the
  first fresh launch after each one.

Devenv is an explicit exclusion for both. Kimchi reads the marker only from the
user file and devenv rejects user-scope keys. A project model default would make
every devenv Kimchi's harness file non-empty, which puts it behind project trust
and the exact-cwd launch guard, and it would outrank the user's HM choice. So a
devenv-only user's first fresh launch runs on Auto and Kimchi persists it in
their user file; a declared project `defaultModel` outranks it on later
launches. Locked by `module-kimchi-auto-default-marker`.

`packages/kimchi/extracted.json` measures the two native settings surfaces and
the environment variables Kimchi and pi read, and `lib/extracted.nix` is its
only reader. It generates the closed `native.settings` (from `config.*`) and
`native.harnessSettings` (from `harness.*`, resolving `harness.definitions`)
option trees: scalars and enums map directly, objects with properties become
closed submodules, `additionalProperties` becomes `attrsOf`, and arrays keep
untyped elements unless they are scalars, because `filterNulls` does not recurse
into lists. So a key upstream adds to pi's `Settings` or to config.ts's
`readConfigExtras` becomes an option at the next re-extraction, and a key it
removes fails its consumer as an unknown option instead of writing bytes nothing
reads. Every option is `nullOr` with a null default. Alias keys (`aliasFor`, the
only hand annotation left on config keys) and inert keys have no option. A key
is inert when upstream tags its `KimchiConfig` member `@deprecated` and no
Kimchi code consumes it: nothing reads the loaded member, and nothing outside
`config.ts` reads the raw `readConfigExtras` member, while `config.ts` still
parses it to warn that it is obsolete. A release that consumes it again clears
the flag, and the key becomes an option. The option generator keeps three hand
tables: two exclusions (`apiKey` and `gitTokens`, secrets delivered by
`ai.kimchi.apiKey` and `ai.kimchi.gitTokens`), one refinement (`modelRoles`,
whose role names and single-string roles come from the sidecar while the
non-blank and non-empty checks do not), and one description note.
`report.stale*` lists any row whose path the sidecar lost, and
`checks/native-options.nix` fails on it.

The extractor has hand-written parts of its own, each guarded only as far as
stated. Kimchi's harness additions (`autoDefaultApplied`, `fermentV2`,
`modelRoles` and the rest, each typed from a named declaration) are a hand list
in `extract.mjs`. Two censuses check it: every harness key config.ts parses, and
every constant key passed to config/settings.ts's `readConfigSetting`,
`readConfigSettingAsync`, `writeConfigSetting` and `writeConfigSettingAsync`
anywhere in `src/`, must be a pi `Settings` key or an addition. Other direct
readers of the harness file are not censused (in 1.1.37,
`telemetry/config-snapshot.ts` reads `model` and `provider` for telemetry), so a
key upstream adds there meets the closed submodule as an unknown option with no
drift signal. The config.json shapes of `teleport`, `gitTokens` and the
`surveys` record have no declared type, so they are written by hand and pinned
both ways to their readers' runtime guards (`readTeleportCompactHintEnabled`,
`readGitToken`, `readSurveyConfig`): every scalar leaf must be `typeof`-guarded
as its type, and every guarded path must be in the shape. That check also runs
the generator over a fixture sidecar with a key added, a key removed and an enum
widened, and requires the option surface to move with it.

The sidecar also drives two rejections and one lookup. Devenv rejects
`native.settings` keys whose `project` flag is false, because Kimchi merges only
its project-honored keys from `.kimchi/config.json`. Both backends reject an
environment variable the sidecar marks not `consumerOverridable`, because
Kimchi's entry point overwrites it before anything reads it. That flag is
derived, not annotated: the extractor walks `src/entry.ts`'s top-level
statements in order and marks a variable fixed when a statement assigns it on
every path and no earlier statement reads it, counting what a callee handed
`process.env` reads from it. `PI_CODING_AGENT_DIR` is assigned too, but read and
preserved first, so it stays settable. The analysis fails instead of guessing
when a module entry.ts statically imports reads the same name, or when an
assignment follows entry.ts's first `await` or `import()`. Every variable the
factory sets itself (`KIMCHI_API_KEY`, `KIMCHI_NO_UPDATE_CHECK`,
`KIMCHI_REGION`, `KIMCHI_TELEMETRY_ENABLED`) goes through `environmentName`,
which fails evaluation if the pinned Kimchi no longer reads it or starts
overwriting it.

Every resolved environment name is either published from an annotation (a
`controls` description and nothing else) or listed, with a reason, under
`environmentIgnored` in `extract/annotations.json`; pi's own names follow
Kimchi's `piConfig.name` (`KIMCHI_CODING_AGENT_SESSION_DIR`, not pi's `PI_`
default). The extractor uses the TypeScript compiler's checker for declared keys
and types and syntax tree queries for environment access sites, while config
queries cross-check compiler types against top-level, nested, and array-element
runtime validation guards. A declaration is never taken by bare name when a
reference can pick it: config.ts's functions and interfaces resolve in
config.ts's own scope (Kimchi 1.1.37 has a second `loadConfig`), pi's `Settings`
comes from `settings-manager.d.ts`'s exports, and the harness `definitions` are
the interfaces `Settings` references, collected through the checker (pi also
declares an all-required `CompactionSettings` in `compaction.d.ts`). The Kimchi
harness schemas still looked up by name must match exactly one declaration among
the modules reachable from `src/entry.ts`, so the dead
`model-catalog/model-metadata.ts` is ignored, and a second live
`ModelCustomMetadataSchema` stops the extraction instead of narrowing the
option. Same-named constants back a constant only where the checker finds no
initializer, and only when they all agree. Three additional hash-pinned pi
declaration packages resolve the settings type's external imports; unresolved
named leaves fail extraction. Their versions are the ones Kimchi's
`pnpm-lock.yaml` resolves pi's dependencies to, which is what the source build
bundles, not the floor of pi's caret ranges: the update job reads them from the
lockfile, and the extractor (handed the lockfile as JSON through `yq`) fails
when a supplied package differs from it. The extractor also checks that the
hash-pinned source URL names the same release tag recorded in provenance;
Kimchi's source `package.json` intentionally retains the `0.0.0` development
placeholder. It no longer extracts the CLI: the wrapper passes no flags, so that
surface had no reader.

## User and project paths (the load-bearing fact)

`ai.kimchi.configDir` controls the Home Manager output root (default
`.config/kimchi`). It does not control devenv project paths. The backend split
is:

| pool             | Home Manager user path                            | devenv project path                    |
| ---------------- | ------------------------------------------------- | -------------------------------------- |
| context          | `<configDir>/harness/AGENTS.md`                   | root `AGENTS.md`                       |
| MCP servers      | `<configDir>/harness/mcp.json`                    | `.kimchi/mcp.json`                     |
| skills           | `<configDir>/harness/skills/<name>`               | `.kimchi/skills/<name>`                |
| Kimchi settings  | `<configDir>/config.json`                         | `.kimchi/config.json`                  |
| harness settings | `<configDir>/harness/settings.json`               | `.config/kimchi/harness/settings.json` |
| permissions      | `.config/kimchi/harness/permissions.json` (fixed) | `.kimchi/permissions.json`             |
| agents           | `<configDir>/harness/agents/<name>.md`            | `.kimchi/agents/<name>.md`             |
| hooks            | none (explicit exclusion)                         | `.kimchi/hooks.json`                   |
| project trust    | `<configDir>/harness/trust.json`                  | none (rejected: user scope)            |

Project Kimchi settings, MCP servers, harness settings, permissions, agents, and
hooks are exact-cwd readers. The devenv wrapper rejects launches below the
devenv root instead of silently missing them. It does not `cd` to the root
instead, because that would also change the working directory Kimchi's tools
see. Context and skills walk ancestors, so a devenv that declares none of the
exact-cwd files leaves the launch directory unrestricted. Locked by
`module-kimchi-devenv-exact-cwd-guard`, which checks both arms.

The project harness directory is deliberately fixed. pi derives
`CONFIG_DIR_NAME` from Kimchi's packaged
`piConfig.configDir = ".config/kimchi/harness"`; its project settings watcher
resolves `<cwd>/<CONFIG_DIR_NAME>/settings.json`. This namespace does not follow
`ai.kimchi.configDir`.

Kimchi settings are ordinary **nested** JSON (`telemetry`, `llmEndpoint`,
`skillPaths`, `preferences`). The user harness contains runtime settings, MCP,
context, and skills.

Settings are Nix's to write, so every Kimchi JSON file is a read-only copy
except one. Kimchi's writers either rename a temporary over the path (MCP edits:
1.1.37's first-run migration `src/setup-wizard.ts:117-137`, ACP import
`src/modes/acp/ext-methods/import-apply.ts:289`, `/mcp enable|disable` through
the patched pi-mcp-adapter 2.34.0 `config.ts:1142-1147`; and every
`writeConfigSetting`, `src/config/json.ts:154-160`) or write in place (pi's
settings and trust stores, `/permissions … save`). A rename replaces a store
symlink as easily as a 0444 file, and then Home Manager's next link check fails
while devenv silently skips the path. So each file is `method = "copy-ro"` in a
directory ledger of the one `kimchiFiles` writer (`ai:kimchi:files` on devenv,
plus `kimchiFilesPrune` on HM), one ledger per directory, named
`materialize/kimchi-files-<sha256 of the directory>.manifest`:

| directory                        | Home Manager                                        | devenv                                               |
| -------------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| `<configDir>`                    | `config.json` (0400)                                | none                                                 |
| `<configDir>/harness`            | `settings.json`, `mcp.json`, `trust.json`           | none                                                 |
| `.config/kimchi/harness` (fixed) | `permissions.json` (a second ledger if not default) | `settings.json`                                      |
| `.kimchi`                        | none                                                | `config.json` (0400), `mcp.json`, `permissions.json` |

A rename lasts until the next activation or shell entry, which backs the file up
and restores the declaration (`lib/ai/own.py`'s `backup_overwrite` arm); an
in-place write fails. The first run adopts a file an earlier generation
reconciled the same way, with a backup, so there is no migration writer. The
directories stay writable, because Kimchi keeps state and locks beside the
copies. Home Manager owns every user-global copy whatever is declared (`{}` when
nothing is); devenv claims a project copy only when something is declared, so a
project file never overrides the user one by existing. Locked by
`module-kimchi-hm-owns-user-files`, `module-kimchi-mcp-copies`,
`module-kimchi-devenv-project-paths` and `module-kimchi-files-runtime`, which
runs the real writers, adopts a reconciled `mcp.json` with an extra server, and
replaces an in-app rename.

A read-only harness `settings.json` can no longer take what Kimchi seeds there
at launch (`src/cli.ts:522-551`), and pi's defaults for two of them differ from
Kimchi's. So `hmHarnessDefaults` also declares `hideThinkingBlock` and
`quietStartup` as `mkDefault true`, beside `autoDefaultApplied`. Without
`autoDefaultApplied`, the Auto router would rename its default model over the
copy (`src/config.ts:831-843`).

Home Manager also owns the complete user `config.json` as a 0400 copy.
`hmSettingsDefaults` declares `migrationState = "skip-forever"`, the
`DEFAULT_SKILL_PATHS` list (including the default `ai.*` skill directory),
`preferences.hideTips = true`, known onboarding markers, the pinned 1.1.37
initial survey's `seenAt`, and `telemetry.enabled = false`. A future survey ID
can reappear after activation until the declaration is updated. The device ID is
absent because telemetry is disabled. `region` has no default: Home Manager
evaluation fails until the account region is declared. The launcher sets
`KIMCHI_REGION` and `KIMCHI_TELEMETRY_ENABLED` from the declared values. Devenv
emits either variable only when it is declared, and it never writes `$HOME`.

The harness type also declares `defaultProjectTrust = "never"`, so undeclared
projects are quietly untrusted and pi does not show the startup trust prompt. It
seeds Kimchi's theme and provider retry policy, disables pi install telemetry,
pins `lastChangelogVersion` from the packaged pi dependency, and marks the
shell-profile API-key migration dismissed. The latter prevents a prompt that can
rename over a Home Manager shell profile.

`ai.kimchi.gitTokens.<host>` takes a `{ file | helper }` credential, the
`lib/credentials.nix` shape. Kimchi reads git tokens only from the user
`config.json` and has no environment input for them
(`src/extensions/teleport/provisioning/git-token.ts`), so the copy's content
becomes a `run` renderer that exports each token from its file and merges it
into the declaration with `jq` when the writer runs; the store holds the path.
The writer is ordered after the `secrets` token. `native.settings` has no
`gitTokens` option, which would write the secret into the store. Devenv rejects
the option by name. The API key needs no leaf: Kimchi prefers `KIMCHI_API_KEY`
over the file everywhere it reads the key (`loadConfig`, the telemetry and
mismatch paths in `src/config.ts`), and the launcher exports it from
`ai.kimchi.apiKey`. With it set, an in-app login or logout changes nothing the
next launch reads. A leaf a login writes survives only until the next
activation, which restores the complete declaration instead of preserving
undeclared leaves. Locked by `module-kimchi-git-tokens` and
`module-kimchi-files-runtime`.

Home Manager writes `config.json` with mode 0400 because it may contain
`gitTokens`. A login or other rename-over edit can replace the copy until the
next activation, which backs it up and restores the declaration. No `deviceId`
or undeclared login key survives that activation. Devenv's project copy is also
0400, because Kimchi warns when a group or other user can read `config.json`
(`src/config.ts:390-403,533`). Its `skillPaths` default stays unset so the
project inherits the user list.

`ai.kimchi.permissions` mirrors Kimchi's `.strict()` zod schema key for key
(`src/extensions/permissions/config.ts:11-19`) with no freeform tail, because
one unknown key invalidates the whole file. The user file is hard-coded to
`~/.config/kimchi/harness/permissions.json` (`config.ts:35`), so its HM path
ignores `configDir`. `/permissions … save` writes in place and fails on either
copy.

The scalars do not inherit per key. Kimchi fills `defaultMode` and
`classifierTimeoutMs` with its defaults for any project file that exists, and
the project value wins (`config.ts:56-60,98-101`); only `classifierMaxTotalMs`
falls through to the user file. So any devenv permissions declaration resets a
user's `defaultMode` inside that project, which the option description states.
Removing the last key removes the project copy, so a `{}` never outlives the
declaration.

`native.harnessSettings.modelRoles` values are provider/model strings, or for
delegable roles a non-empty list of them. The role names, and which roles take
one string (`orchestrator` and `compactor` in 1.1.37), come from the sidecar's
`modelRoles` properties. Any other shape is discarded with a runtime warning
(`src/extensions/orchestration/model-roles.ts:117-181`), so the option type
rejects it at evaluation: an unknown role is an unknown option. Locked by
`module-kimchi-model-roles-shape`.

Everything else Kimchi delivers except the settings copies (above) and agents
(below) is immutable and symlink-readable, so it takes both defaults and states
no fact at all. Normalized context renders into the `ai.kimchi.files` map on
Home Manager. Devenv context joins the single root `AGENTS.md` owner shared with
Codex and Kiro, through the record's `sharedAgentsMd`, which names that fixed
key and no rules. In either backend, the generated body is a default on the
entry's `content` option, so a consumer can replace or suppress it. When root
and Kimchi-specific context are both configured, their bodies concatenate
root-first. Home Manager honors `ai.kimchi.context.filename`; devenv always
writes `AGENTS.md`.

Project config, MCP, skills, and harness settings remain inert until project
trust is established. The decision lives in the user's harness `trust.json`:
declared by `ai.kimchi.projectTrust` under Home Manager, saved by Kimchi's trust
prompt without it. Headless and ACP sessions honor that decision or the
user-global `defaultProjectTrust`. `--approve` is a run-scoped override for CLI
and TUI only: ACP resolves trust again for each session without it
(`src/modes/acp/server.ts:2166-2173`), so an unattended ACP client needs the
persisted decision or `defaultProjectTrust`. Root `AGENTS.md` is the upstream
exception: Kimchi's context loader walks ancestors directly without consulting
the project-scope gate.

`ai.kimchi.projectTrust` (absolute path → bool) is the persisted decision,
declared. pi 0.85.1 keeps it in `<agentDir>/trust.json`, which Kimchi pins to
its harness directory, and looks it up under `realpath(cwd)` and then each
parent, reading keys verbatim (`findNearestTrustEntry`,
`dist/core/trust-manager.js:20-33`). So one entry covers every project beneath
it, `false` denies a subtree, and a key reached through a symlink never matches.
Home Manager owns the file as a read-only copy in the `kimchiFiles` writer's
harness ledger, declared `{}` when nothing is set. The copy declares
`content.run` rather than `value`: `lib/project-trust.py` canonicalizes each key
with `os.path.realpath` when the writer runs, since evaluation cannot see the
filesystem, and fails the writer when two keys resolve to one directory with
different answers. pi writes the file in place under proper-lockfile's
`trust.json.lock` (`dist/core/trust-manager.js:94-142`), so remembering an
answer at the trust prompt fails on the copy, and the MCP trust prompt's "Trust"
fails closed for that session. The session-only answers ("Trust (this session
only)", "Do not trust (this session only)") write nothing and still work
(`dist/core/project-trust.js:41-56`). `/trust` cannot persist a choice under
Home Manager and may exit after the failed write. A devenv project on a Home
Manager machine must have its project root or a parent declared trusted in
`ai.kimchi.projectTrust` before Kimchi reads the project's settings, skills, MCP
servers or harness settings. Check parent entries before adding a duplicate.
Devenv rejects the option with an assertion: pi reads trust only from the user
store, so that a project cannot trust itself, and devenv writes only inside the
project; without Home Manager the file is Kimchi's own. Locked by
`module-kimchi-project-trust` and `module-kimchi-project-trust-runtime`, which
runs the real writer against a symlinked fixture.

The devenv module rejects every `native.harnessSettings` key whose sidecar
`project` flag is false, the list `userScopeHarnessKeys` in `lib/extracted.nix`.
The extractor derives the flag: a pi key honors the project file only if pi
reads it through SettingsManager's merged `this.settings`, so keys read only
through `this.globalSettings` or `getGlobalSettings()` (`defaultProjectTrust`,
`httpProxy` in pi 0.85.1) are user scope, and a key it sees read neither way
stops the extraction. Every Kimchi addition is user scope, because Kimchi reads
them itself from `~/.config/kimchi/harness/settings.json`, never through pi's
merged manager. It likewise rejects every `native.settings` key whose sidecar
`project` flag is false (`gitTokens`, `onboarding`, `preferences`, `region`,
`surveys`, `telemetry`, `teleport` in 1.1.37), except `region` and
`telemetry.enabled`, which it passes through the launcher environment instead.
Set the rest with Home Manager; without it, the user files are Kimchi's own.

## Agents: read-only copies

Kimchi 1.1.37 loads `<agentDir>/agents/*.md` and a trusted project's
`.kimchi/agents/*.md`, naming each agent by its filename
(`src/extensions/agents/personas/custom-agents.ts:21-85`). Its /agents commands
write those same files: Edit, Disable and Enable `writeFileSync` in place, and
Create and Eject add new ones (`src/extensions/agents/index.ts:2556-2874`). Each
agent file states `method = "copy-ro"` at `mkDefault` and takes the reconciler's
read-only mode: one real file per agent in a real directory, owned by the
`kimchiAgents` writer's `dir` ledger (`ai:kimchi:agents` on devenv, plus
`kimchiAgentsPrune` on HM). An in-place edit of a declared agent fails; a file
renamed over one is backed up and replaced at the next activation; a file Kimchi
created is an unowned sibling and is never touched. To turn a declared agent
off, set it to null. Locked by `module-kimchi-agents` and
`module-kimchi-agents-runtime`, which runs the real writers.

`/agents` Edit, Disable and Enable cannot change a declared read-only agent;
Kimchi surfaces the failed in-place write. Create and Eject can still add an
unowned sibling, but those files are outside the Nix declaration.

The MCP adapter's scaffold, preset and install commands write their own project
`.mcp.json` or user `~/.config/mcp/mcp.json`, not the Kimchi-owned `mcp.json`.
Those destinations need their own owner if they are to be managed from Nix.
`kimchi install` writes `packages` into harness `settings.json`; under Home
Manager that write does not persist. Declare the package's settings from Nix
instead.

A portable record renders as `description:` frontmatter plus the instructions
body, with no `name:`. Two inputs fail evaluation, naming `ai.kimchi.agents` as
the remedy: a record with a non-empty `tools` list (Claude/Copilot names; Kimchi
matches its lowercase builtins exactly, `agent-types.ts:12`, so dropping it
would widen the agent and translating it would fail silently), and root Markdown
(written for Claude, and Kimchi ignores `name:` and reads `model: sonnet` as a
model id). Markdown under `ai.kimchi.agents` or `ai.kimchi.agentsDir` is
Kimchi's own and lands verbatim. A path-like entry, a store-path string such as
a flake input's `"${src}/a.md"` included, is copied from that source by
`lib.ai.agent.fileContent`, which tests `isPathLike`; `builtins.isPath` alone
would write the path itself as the agent's text. Locked by
`module-kimchi-agents-rejected` and, for the string form on both backends,
`module-kimchi-agents`.

## Hooks: project `hooks.json` only

Kimchi 1.1.37 has four hook loaders (`src/cli.ts:707-731`). The one that fits
`ai.hooks` is kimchi-hooks: it reads `.kimchi/hooks.json` and `hooks.local.json`
in the Claude shape, timeouts in seconds, from a trusted project only, and never
writes them (`src/extensions/kimchi-hooks/definition.ts:25-37`). So devenv
writes the shared groups followed by `ai.kimchi.hooks` (typed over Kimchi's own
20 events) into `.kimchi/hooks.json`, rendered by `lib/ai/hooks.nix`'s `render`,
the same one Claude's settings use. It takes the default facts and lands as a
symlink. PermissionRequest is not a Kimchi event and the reader skips unknown
events silently, so the factory leaves it out. Home Manager has no lifecycle
sink it can own. A configured pi package's `hooks/hooks.json` would make Home
Manager own `packages` in harness `settings.json` and clobber `kimchi install`.
The opt-in Claude Code hook adapter (`extensions.claude-code-hook-adapter`,
`defaultEnabled: false`, `src/resources/definitions.ts:75-80`) reads
`~/.claude/settings.json`
(`src/extensions/claude-code-hook-adapter/definition.ts:25-28`), which Claude's
own delivery already writes. The policy row is `absent` with that reason. Both
shared-pool exclusions are silent, because `ai.hooks` composes with
`ai.kimchi.hooks` and nothing Kimchi-scoped can withdraw it: a warning would
repeat on every activation (the root-pool rule in the ai-module fanout
fragment). A non-empty `ai.kimchi.hooks` still warns on Home Manager. Locked by
`module-kimchi-hooks`.

The bash-hook directory (`harness/hooks/bash`, `.kimchi/hooks/bash`) is
deliberately not a sink: those scripts filter or rewrite the bash tool only, a
different contract from lifecycle events. If a user enables Kimchi's opt-in
Claude Code hook adapter, a shared hook that also reaches
`.claude/settings.json` fires twice.

## Normalized pool capability boundary

The app record's `supportedPools` is exactly `agents`, `context`,
`environmentVariables`, `hooks`, `mcpServers`, `settings`, and `skills`. Kimchi
has no native path-scoped rules, LSP, or shell-selection landing key. Those
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

Kimchi takes a flat, always-injected user `harness/AGENTS.md` or project-root
`AGENTS.md` (orientation tier, like Codex). It has **no** path-scoped steering
(no Claude `rules/` or Kiro `steering/` equivalent), so the scoped-fragment
transforms do not apply to it.

## Shared prep

`mkPrep` (top-level `let`) builds the wrapped launcher from the builder's
`launcherEnvironment` plus Kimchi's typed variables, the credential export and,
on devenv, the exact-cwd guard. The one `installPackage` callback calls it; the
delivery function computes its own filtered settings and context entry, because
it never installs the package. The wrapper stays a local `symlinkJoin` rather
than `lib.ai.mkLauncher`: its `postBuild` uses a continued line, and moving it
would change the wrapper's store path.

## Source packaging

The package builds upstream's Bun executable and its Go proxy helper from the
same pinned release. That source is pinned once, as `extraction.kimchiSource` in
`sources.json`, because the extractor reads the same tree; a second copy of the
URL and hash could drift from it. `pnpmDeps` and `proxyHelper.goModules` have
independent hashes pinned beside it. `mkUpdateScript` records the version alone
(`platforms = {}`); its `extraExtract` first refreshes the extraction pins and
`extracted.json`, then `mkGoUpdateExtract` derives the new Go floor before
rebuilding the helper vendor hash and runs the shared pnpm hash fixer. The
standalone dependency fixers also participate in input-bump repairs. The source
checkout reports version `0.0.0`, so upstream's `set-version.js` runs before
compiling and staging the resources.

Upstream's `bin/` and `share/kimchi/` layout remains intact. Generic ELF
rewriting and stripping are disabled to preserve Bun's compiled module graph.
The install check requires the exact release version, a runnable helper, and the
theme, export, and bundled-skill assets. Linux and Darwin builds run in CI. The
source-build switch itself does not alter discovery or configuration behavior.

## Immutable skill discovery

The Nix patch returns individual bundled skill directories directly to Pi's
resource inventory. Pi supports those paths and resolves supporting files
relative to SKILL.md, so no temporary copy or exit cleanup is needed. Upstream's
copy preserved the store's 0555 directory modes, causing EACCES during recursive
cleanup. Filtering still omits bundled names supplied by stronger roots and now
recognizes symlinked skill directories, including broken-link tolerance.
