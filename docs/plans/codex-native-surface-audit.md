# Codex 0.146.0 native-surface audit

> Last verified: 2026-08-02 against `pkgs.ai.chatgpt-codex` 0.146.0 and the
> current official OpenAI Codex manual (commit `2eb54cef` — CX-012).

## Scope and decision rule

This is the CX-012 expose/defer ledger for Codex surfaces that do not have an
obvious cross-runtime mapping. It complements the artifact and mutation probes
in `codex-configuration-probes.md`; the completed reverse CLI-command coverage
audit is recorded separately in `codex-reverse-coverage-audit.md`.

A surface gets a dedicated Nix option or materializer when its structure is
stable, mistakes need early diagnostics, or it lives outside the existing
typed/freeform `config.toml` boundary. Stable config keys that already
round-trip losslessly through `ai.codex.settings` remain in that native escape
hatch until typing adds meaningful safety. Runtime databases, credentials,
interactive installation state, deprecated inputs, and concepts with no Codex
equivalent are intentionally not generated.

## Decision ledger

| Surface                                                         | Native contract                                                                                                                                     | Decision                                                | Rationale                                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Public process environment                                      | Codex reads `CODEX_HOME`, `CODEX_SQLITE_HOME`, installer variables, auth/token variables, CA paths, and `RUST_LOG` from its own process environment | Exclude from `ai.environmentVariables`                  | The shared pool wraps the AI CLI process. Most Codex variables are state-root selectors, shell-scoped diagnostics, or secrets; they should use normal Home Manager/devenv environment facilities or credential handling.                                                           |
| Spawned-command environment                                     | `[shell_environment_policy]` filters and sets variables inherited by commands Codex launches                                                        | Keep in `ai.codex.settings` freeform                    | This is not semantically equivalent to wrapping Codex itself. Mapping the shared environment pool here would unexpectedly expose values to model-generated commands.                                                                                                               |
| LSP servers                                                     | No LSP-server registration key, config file, or CLI command appears in the current public manual or pinned recursive help                           | Explicitly exclude Codex from `ai.lspServers`           | Codex may use editor intelligence internally, but it exposes no consumer-configurable native LSP surface. Silent fanout would be dishonest.                                                                                                                                        |
| Named profiles                                                  | `$CODEX_HOME/<name>.config.toml`, selected only by `--profile`; names allow letters, numbers, hyphens, and underscores                              | Expose as typed `ai.codex.profiles.<name>` in HM/devenv | Profiles are stable declarative TOML layers outside base `settings`. HM links them directly; devenv safely materializes repository declarations into the native user lookup location before shell entry.                                                                           |
| TUI theme, keymap, status line, notifications, and presentation | `[tui]` settings; `/theme`, `/keymap`, and `/statusline` can persist user choices                                                                   | Keep in `ai.codex.settings` freeform                    | These are user preferences, not cross-runtime semantics or security boundaries. The writable HM leaf reconciler lets native editors coexist with any explicitly declared Nix leaves. Theme names and key actions can evolve independently of the package sidecar.                  |
| History, logs, feedback, analytics, and OTel                    | Config keys control persistence, diagnostics, and telemetry; the resulting files are runtime state                                                  | Keep controls freeform; never generate resulting state  | Users can declare policy without Nix owning transcripts, databases, logs, or telemetry output. Project config already rejects machine-local `notify` and `otel`.                                                                                                                   |
| Model providers and tuning                                      | `[model_providers]`, provider/auth indirection, model catalog, verbosity, compaction, and review-model keys                                         | Keep freeform                                           | The schema is large and provider-extensible. Existing TOML accepts it losslessly; credential values must remain environment/keyring indirections rather than store literals. Model and reasoning defaults remain typed because they participate in aggregate fanout.               |
| Compact/model instruction prompts                               | `compact_prompt`, `experimental_compact_prompt_file`, `model_instructions_file`, and related tuning keys                                            | Keep freeform                                           | These are model/runtime-specific prompt overrides with no portable semantics. File paths can already be supplied as store paths through native settings.                                                                                                                           |
| Custom prompt files                                             | `$CODEX_HOME/prompts/*.md`, invoked as `/prompts:<name>`                                                                                            | Do not expose                                           | The official manual marks custom prompts deprecated and directs reusable workflows to skills, which this module already materializes globally and per project.                                                                                                                     |
| Plugins and marketplaces                                        | `codex plugin` and `/plugins` mutate installed-plugin, marketplace, cache, and enablement state under CODEX_HOME                                    | Leave runtime-owned                                     | Installation is interactive/account/workspace dependent and may include connector auth. Nix may still declare plugin-related feature or policy tables through freeform settings, but it must not overwrite the native installation database without a stable lock/source contract. |
| Apps/connectors policy                                          | `[apps]` and plugin MCP policy tune enabled tools and approvals                                                                                     | Keep freeform                                           | The tables are Codex-native and fast-moving; typed MCP servers already cover direct server declarations. App installation/auth remains outside Nix ownership.                                                                                                                      |
| Memories and goals                                              | Feature/config controls plus SQLite-backed runtime records                                                                                          | Keep controls freeform; leave records runtime-owned     | The data is generated personal/session state. Nix can enable behavior but must not synthesize memory or goal databases.                                                                                                                                                            |
| Desktop, Windows, and computer-use settings                     | `[desktop]`, `[windows]`, and `computer_use.windows` keys                                                                                           | Keep freeform                                           | Platform-specific settings are faithfully representable in TOML but do not justify portable options in a Linux-first cross-runtime schema.                                                                                                                                         |
| Auth, sessions, history, caches, SQLite, and hook/plugin trust  | Mutable files and databases under CODEX_HOME or the OS credential store                                                                             | Never generate                                          | These are credentials or native runtime state. The narrow exceptions are already documented: HM reconciles user `config.toml` leaves and reserves native-written `rules/default.rules`.                                                                                            |
| System/admin requirements                                       | `/etc/codex/config.toml`, `requirements.toml`, and managed policy                                                                                   | Defer outside the user/project module                   | These are host or organization policy surfaces, not Home Manager user preferences or trusted-project devenv config. A future system module would need stronger authority and conflict semantics.                                                                                   |
| Session-only CLI controls                                       | Images, working directory, remote app-server address, bypass flags, resume/fork/archive operations, and `codex exec` output controls                | Do not persist                                          | They describe one invocation or an operation. Promoting them to durable settings would duplicate CLI behavior and create precedence ambiguity.                                                                                                                                     |

## Profiles: shared declaration, scope-specific delivery

Profiles are the only new materializer from this audit. Codex 0.134.0 removed
legacy `[profiles.<name>]` tables and the top-level `profile` selector. Current
Codex instead layers a standalone user file between base user config and trusted
project config when the operator passes `--profile`.

`ai.codex.profiles` uses the same typed/freeform Codex settings schema in both
backends. Home Manager writes one static `${configDir}/<name>.config.toml` per
declared profile. The file is not part of mutable base-config reconciliation
because no native writer shares it.

Placing the same file beside project `.codex/config.toml` would be inert, while
changing CODEX_HOME would fork auth, sessions, logs, and caches. Devenv instead
materializes each repository-declared store file into the existing user
CODEX_HOME before shell entry. Its ownership ledger is keyed by Git common
directory, so linked worktrees share lifecycle state; it updates and prunes only
its own symlinks and rejects conflicting external content.

There is deliberately no `defaultProfile` option because upstream no longer
supports a persistent selector; use `codex --profile <name>`.

## Cross-runtime boundary corrections

The audit corrected the shared option descriptions so they name their real
consumers:

- `ai.lspServers` fans out to Claude, Copilot, and Kiro, not Codex.
- `ai.environmentVariables` fans out to Copilot and Kiro. Claude uses its native
  settings environment, while Codex process variables belong in ordinary Home
  Manager/devenv environment configuration.

These exclusions prevent a declaration from appearing universal while an enabled
runtime silently receives nothing. Codex's freeform `shell_environment_policy`
remains available, but it is intentionally not used as a lossy translation
target.

## Evidence

- The pinned recursive CLI sidecar includes `--profile` and the `codex plugin`
  command tree, but no LSP command or setting schema.
- The current configuration reference documents profile files, TUI settings,
  environment policy, providers, observability, memories, apps, plugins, and
  platform-specific settings as TOML-compatible native keys.
- The current environment-variable reference separates process-scoped auth,
  state-location, installer, TLS, and diagnostic variables from
  `[shell_environment_policy]` child-process controls.
- The current custom-prompts guide marks the surface deprecated in favor of
  skills.
- The current plugins guide requires native install/manage flows and notes
  account, workspace, connector-auth, and surface-availability constraints.

## Official sources

- [Configuration reference](https://developers.openai.com/codex/config-reference)
- [Advanced configuration](https://developers.openai.com/codex/config-advanced)
- [Environment variables](https://developers.openai.com/codex/config-environment-variables)
- [Custom prompts](https://developers.openai.com/codex/custom-prompts)
- [Plugins](https://developers.openai.com/codex/plugins)
