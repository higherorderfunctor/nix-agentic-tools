## ai.proxy runtimes: how each harness consumes the resolved endpoint

> **Last verified:** 2026-10-17 — Claude uses `redact.assign` and the shared
> reader through `apiKeyHelper` for file, command and concat references, and
> clears inherited API keys, bearer tokens, custom headers and
> Bedrock/Vertex/Foundry switches in settings, and suppresses the inherited
> API-key descriptor before Claude starts. Codex, Kimchi, Kiro and Copilot omit
> `proxy` from `surfaceSupport` and warn through the generated warning cases.

### Claude (packages/claude-code/lib/proxy.nix)

A settings `env` beats the process env, so the endpoint travels through settings
files. `render` writes `env.ANTHROPIC_BASE_URL` (the origin; Claude appends
`/v1/messages`) and one strict `apiKeyHelper`. That helper calls `redact.assign`
with the selected file, command or concat reference, then prints the resolved
key with a constant `printf` format. Its shell source carries only reference
paths and concat's literal parts; the secret stays in the shared reader's stdout
and the helper's shell variable. Resolution failures abort the helper before it
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
applying settings env. A blank in settings cannot suppress it. A selected proxy
therefore installs a launcher through `lib.ai.mkLauncher` that unsets the
descriptor before exec; without a selection the package stays unchanged. An
explicit `ai.claude.package = null` keeps settings delivery and warns that the
caller must unset the descriptor when launching an unmanaged Claude.

Any selection also sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and
`DISABLE_AUTOUPDATER` at `mkDefault`.

The endpoint lands in `native.settings`, so the settings.json the backend
already writes (user on Home Manager, project on devenv). The proxy leaves are
at ordinary priority, so a consumer's own value for one is a definition
conflict.

### Codex (`packages/chatgpt-codex/lib/proxy.nix`)

One provider table per endpoint: `base_url` is the origin plus `/v1`, `name` is
the provider id (Codex refuses to load a provider without one),
`wire_api = "responses"` and `requires_openai_auth = false`. `true` would send a
ChatGPT login's token to the proxy. `plain` becomes `experimental_bearer_token`.
`file` and `helper` become command-backed `auth` (`cat <path>`, or the helper),
which Codex re-runs every five minutes and after a 401. Never `env_key`: tool
subprocesses inherit it, and Home Manager's launcher environment does not reach
devenv's.

- **Home Manager** writes `model_provider = "ai-proxy"` and
  `[model_providers.ai-proxy]` into user config.toml, plus the overridable
  defaults `features.plugins = false` and `analytics.enabled = false`, which
  stop plugin sync and usage metrics from reaching other hosts. A devenv shell
  inherits the user file with no devenv configuration.
- **devenv** cannot use project config: Codex strips `model_provider` and
  `model_providers` from project layers. Its launcher passes
  `-c model_providers.ai-proxy-devenv={…}` and
  `-c model_provider=ai-proxy-devenv`, the highest layer, baked in as
  `--add-flag`s. The quieting defaults go to the trusted project's config.toml.
- **A separate id on devenv is load-bearing.** Codex deep-merges layers per key,
  so session flags reusing `ai-proxy` would add their auth fields to the user
  table, and `auth` beside `experimental_bearer_token` fails to load.
- No `[profiles.*]` or `profile`: the pinned Codex rejects both.

`chatgpt-codex-proxy` runs the pinned binary against loopback mock proxies in
the build sandbox. It covers each Home Manager key form, the devenv url form,
and Home Manager plus devenv with different key forms.

### Kimchi, Kiro, Copilot

Kimchi and Kiro omit `proxy` from `surfaceSupport`. They receive the standard
unsupported-surface warning, not a silent drop. Copilot is out of scope and
warns the same way. `ai-warnings-delivery` generates those cases from the
records on both backends.

### Checks

`packages/claude-code/checks/claude-proxy.nix` covers Claude on both backends:
key forms, precedence (quiet defaults yield, a consumer's proxy leaf conflicts,
nothing selected writes nothing, a selection does not warn), and the per-runtime
override. Its runtime check executes each generated helper with shell
metacharacters and multiline key contents, checks failure output for leaks, and
asserts inherited API-key and bearer variables are cleared. It also runs the
pinned CLI through both backends' installed launchers against a loopback capture
server with an inherited readable API-key descriptor, and checks that both
`x-api-key` and `Authorization` contain only the selected proxy key.
