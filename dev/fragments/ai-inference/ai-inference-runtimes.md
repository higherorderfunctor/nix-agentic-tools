## ai.settings.inference runtimes: how each harness consumes the resolved endpoint

> **Last verified:** 2026-10-29 — each runtime's inference library
> (`packages/<owner>/lib/inference.nix`) holds one lowering per backend (only
> `cliproxyapi`, which also lowers external selections) and asserts on any
> other; lowerings derive native values at `mkDefault`. Claude's helper and
> launcher keep inherited credentials away from the proxy; Codex uses
> command-backed provider auth; Kimchi, Kiro and Copilot warn.

### Claude (packages/claude-code/lib/inference.nix)

A settings `env` beats the process env, so the endpoint travels through settings
files. The `cliproxyapi` lowering writes `env.ANTHROPIC_BASE_URL` (the origin;
Claude appends `/v1/messages`) and one strict `apiKeyHelper`.
`lib/ai/inference/key-helper.nix`, shared with Codex, calls `redact.assign` with
the selected file, command or concat reference, then prints the resolved key
with a constant `printf` format. Its shell source carries only reference paths
and concat's literal parts; the secret stays in the shared reader's stdout and
the helper's shell variable. Resolution failures abort the helper before it
returns a key.

Both `env.ANTHROPIC_API_KEY` and `env.ANTHROPIC_AUTH_TOKEN` are written blank.
Settings merge per key across scopes, so an inherited token or a lower-scope key
would otherwise accompany the helper's proxy key. An explicit
`ANTHROPIC_API_KEY` value also prompts interactive Claude, and declining sends
the claude.ai login instead (blank suppression probed on Claude Code 2.1.296).
`env.ANTHROPIC_CUSTOM_HEADERS` is blank for the same reason: Claude forwards
inherited custom headers, which can carry a credential.
`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and
`CLAUDE_CODE_USE_FOUNDRY` are blank because an inherited switch sends model
traffic past the proxy; the live check measures both on the pinned CLI. Claude
Code 2.1.302 reads and caches `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` before
applying settings env. A blank in settings cannot suppress it. A `cliproxyapi`
selection therefore installs a launcher through `lib.ai.mkLauncher` that unsets
the descriptor before exec; the flag is the `cliproxyapi` lowering's
`launcherFlags`, so another backend's lowering adds none unless it asks, and
without a selection the package stays unchanged. An explicit
`ai.claude.package = null` keeps settings delivery and warns that the caller
must unset the descriptor when launching an unmanaged Claude.

The `cliproxyapi` lowering also sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
and `DISABLE_AUTOUPDATER` at `mkDefault`, and defaults
`settings.disableClaudeAiConnectors` to `true` to disable claude.ai connectors.
A lowering returns `settings` and optional `launcherFlags`; nothing outside it
adds Claude settings for a selection.

The endpoint lands in `native.settings`, so the settings.json the backend
already writes (user on Home Manager, project on devenv). Every derived leaf is
a `mkDefault`, so a consumer's own value for one, such as
`env.ANTHROPIC_BASE_URL`, wins without `mkForce`.

Each declared API-key model of each routed upstream credential
(`normalized.settings.inference.credentials`) becomes one `modelPicker.options`
row, `{model; description = "<credential> through CLIProxyAPI";}`, labelled with
its id. `replaceBuiltInOptions` stays unset: Claude Code 2.1.306's picker
builder returns the built-in lineup plus each new row unless that flag is
`=== true`, and its schema says unset adds the rows after the built-ins. The
same schema says `modelPicker` is honored only from managed, `--settings`/SDK
and user settings, never a project checkout. So Home Manager writes the rows to
user settings, where a consumer's own `modelPicker.options` list replaces the
derived rows, and devenv's launcher adds `--settings <store file>` holding only
`modelPicker`. Since the highest scope that defines `modelPicker` wins outright,
that devenv session shows the credential rows instead of any user picker rows.

A row for a non-Anthropic id such as `glm-5.3` is listed and selectable in
2.1.306 (read from the bundle; the live TUI render was not observed). The row
schema has no model-name pattern, and the builder keeps a row unless its check
`H0o` fails, which is `One` (a retired Claude id) or `Xr` (the availability
allowlist) or `MF` (a first-party-only lookup that returns null off
`api.anthropic.com`); none rejects such an id. Gateway discovery keeps only ids
matching `/(claude|anthropic)/i`, which is why rows use `modelPicker` and not
discovery. Selecting a row passes validation before the server probe, so it
works while the proxy is down. A consumer `availableModels` that omits the id,
or a matching `deniedModels`, hides the row. Claude's handling of the unknown id
once selected (context window, effort defaults) is not covered; `behavesAs` is
the lever and the rows leave it unset.

### Codex (`packages/chatgpt-codex/lib/inference.nix`)

One provider table per endpoint: `base_url` is the origin plus `/v1`, `name` is
the provider id (Codex refuses to load a provider without one),
`wire_api = "responses"` and `requires_openai_auth = false`. `true` would send a
ChatGPT login's token to the proxy. Every key becomes command-backed `auth`
through a strict helper that calls `redact.assign` and prints the resolved key
with a constant `printf` format. File, command and concat references share the
reader's failure checks; no resolved key is interpolated into shell or TOML.
Never `env_key`: tool subprocesses inherit it, and Home Manager's launcher
environment does not reach devenv's.

- **Home Manager** writes `model_provider = "ai-inference"` and
  `[model_providers.ai-inference]` into user config.toml, each leaf a
  `mkDefault` that a consumer's `native.settings` value overrides. A devenv
  shell inherits the user file with no devenv configuration.
- **devenv** cannot use project config for providers: Codex strips
  `model_provider` and `model_providers` from project layers. Its launcher
  passes `-c model_providers.ai-inference-devenv={…}` and
  `-c model_provider=ai-inference-devenv`, the highest layer, baked in as
  `--add-flag`s. With `ai.codex.package = null` nothing carries them, so devenv
  warns whenever the lowering produced session flags.
- **Models.** Codex's `auth.command` provider fetches
  `<base_url>/models?client_version=`, which CPA answers in Codex's catalog
  shape (every registered model, unfiltered by client key), merged into the
  bundled list. Client routes still constrain requests. No per-credential
  profiles are written. `model_catalog_url` stays unset: it would replace the
  bundled list and empty the picker whenever CPA is down.
- **Availability tooltip.** The `cliproxyapi` lowering defaults
  `tui.model_availability_nux."gpt-6.1-sol" = 4` on both backends. Codex
  0.163.0's pinned source (`83086188`, `tui/src/app/startup_prompts.rs`)
  suppresses the startup availability tooltip once that model's shown count
  reaches four. Its bundled catalog announces only `gpt-6.1-sol`; the extracted
  catalog omits `availability_nux`, so this is a static default for that pin,
  not a claim about CPA's catalog. Consumers can override the count; other
  tooltips remain enabled.
- **A separate id on devenv is load-bearing.** Codex deep-merges layers per key,
  so session flags reusing `ai-inference` could inherit incompatible user auth
  fields, such as `experimental_bearer_token`, beside the proxy's `auth`.

`chatgpt-codex-inference` runs the pinned binary against loopback mock proxies
in the build sandbox. It covers all three reference forms on both backends, Home
Manager plus devenv precedence, and a legacy user bearer token beside a devenv
provider, with inherited `OPENAI_API_KEY`, `CODEX_API_KEY` and `auth.json`
credentials that must appear in no request header. It also executes the helpers
directly with quotes, multiline values and shell metacharacters, and checks
failure output for leaks.

### Kimchi, Kiro, Copilot

Kimchi, Kiro and Copilot do not consume `inference` in
`surfaceSupport.settings.fields`. They receive the standard unsupported-setting
warning for a populated selection, and their normalized inference stays at the
library default. `ai-warnings-delivery` generates those cases from the records
on both backends.

### Checks

`packages/claude-code/checks/claude-inference.nix` covers Claude on both
backends: key forms, precedence (quiet defaults and proxy leaves yield to a
consumer's value, nothing selected writes nothing, a selection does not warn),
and the per-runtime override. Its runtime check executes each generated helper
with shell metacharacters and multiline key contents, checks failure output for
leaks, and asserts inherited API-key and bearer variables are cleared. It also
runs the pinned CLI through both backends' installed launchers against a
loopback capture server with an inherited readable API-key descriptor, and
checks that both `x-api-key` and `Authorization` contain only the selected proxy
key.
