## ai.proxy: local CLIProxyAPI for AI harnesses

> **Last verified:** 2026-10-14 — root and per-runtime selection, the resolved
> endpoint, Home Manager services and registry, the run-time lookup, and the
> Codex integration (user config.toml provider on Home Manager, launcher session
> flags on devenv). Kimchi, Kiro and Copilot warn.

`ai.proxy` points a harness at a locally hosted CLIProxyAPI so the harness holds
only the proxy's client key, never an upstream credential. The proxy holds the
logins. `ai.mcpServers.<name>.proxy` (lib/ai/mcpProxy.nix) is an unrelated MCP
credential proxy.

### Shape

- Library: `lib/ai/proxy/default.nix` (exported as `lib.ai.proxy`). Options,
  validation, `resolve`, the registry contract, `templates` and the run-time
  lookup `renderProgram` all live there. `render.jq` is the run-time half.
- Configuration: `lib/ai/proxy/module.nix`, imported by `sharedOptions.nix`. It
  holds root assertions, Home Manager units, the registry file and the Darwin
  warning.
- `proxy` is a key of `sharedSurfaceOptions`, so every enabled runtime whose
  record omits the `proxy` pool gets the standard decomposition warning.
  `delivery-warnings.nix` counts only a client SELECTION as a request:
  `instances` alone defines services that no runtime consumes.
- `mkBackendTransform.nix`, for a record listing `proxy` in `supportedPools`,
  declares `ai.<runtime>.proxy` (same selection options as the root) and
  `ai.<runtime>.normalized.proxy`. The callbacks get it as `normalized.proxy`
  and `resolvedProxy`.

### Selection and the resolved endpoint

A selection is `instance`, or `url` + `key`. Both at once, a url without a key,
or a key without a url fail as assertions at either scope, outside the runtime
enable gate. A url without a key is rejected because the harness would send its
own login token, if any, to the proxy.

A per-runtime selection that selects anything replaces the root selection WHOLE.
Fields never mix across levels. The resolved value is null,
`{instance = "<name>";}`, or `{endpoint = {url; key};}`. The endpoint has the
same shape as a registry entry. `url` is the origin only: Claude uses it as is
and Codex appends `/v1`, so a path would be doubled for one of them.

### One renderer per integration

The `instance` form is looked up at RUN time (shell entry or launch), never at
evaluation: the registry may be hand-written, and a devenv evaluation cannot see
Home Manager's. An integration writes ONE function, `endpoint -> native config`,
and uses it twice:

- at evaluation, on `resolvedProxy.endpoint`;
- through `lib.ai.proxy.templatesFile pkgs "<name>" render`, which applies it to
  one placeholder endpoint per key form (`@AI_PROXY_URL@`, `@AI_PROXY_KEY@`).

At run time, `ai-proxy-render [--lines] INSTANCE TEMPLATES` reads the registry,
validates the entry, picks the template for its key form, substitutes the
placeholders, and prints compact JSON. With `--lines` it prints one argv element
per line. A shell-entry hook captures the output with `out="$(…)"`. A launcher
does the same, then `mapfile -t args <<<"$out"`.

Placeholders are substituted with no escaping into whatever the integration
rendered: a JSON string, a TOML string or a shell word. That is safe only
because `patterns` holds every url and key value to a charset with no quote,
space, `$`, backslash or newline. Both forms are validated against the same
table, at evaluation and in `render.jq`. Do not widen a pattern without adding
escaping to every placeholder context.

### Registry contract

The registry is `${XDG_CONFIG_HOME:-~/.config}/ai-proxy/instances.json`. It is
one object mapping instance name → `{url, key}`, where `key` is exactly one of
`plain`, `file` or `helper`. Home Manager writes it declaratively
(`xdg.configFile`, no activation script) from `ai.proxy.instances`. Its format
is the public contract, because a hand-run proxy writes its own entry.

### Home Manager services (config-parity exception)

`ai.proxy.instances` is declared on both backends. devenv rejects a non-empty
value with an assertion. This exception was approved by the operator on
2026-10-14: devenv has no user-service lifecycle, and it inherits the
user-global registry anyway. Linux only: there is no launchd writer in the repo,
so Darwin warns, emits no units, and still writes the registry.

- CLIProxyAPI v8 reads client keys only as plaintext (`access.api-keys`) and
  rewrites its own config. The unit therefore renders a private copy into its
  `StateDirectory` (`$XDG_STATE_HOME/ai-proxy/<name>`) on every start. It
  appends the client key to any keys in `settings`, and defaults
  `oauth.auth-dir` there. JSON is YAML, so `jq` writes it. The key reaches `jq`
  through its environment, never argv.
- `host` and `port` are lifted out of `settings` because the registry and the
  unique-port assertion read them at evaluation. They are written back into
  `settings.server`, so a value set in both places is a definition conflict.
- A blank or wildcard host binds every interface (CLIProxyAPI's default for
  `""`) and fails evaluation. Another single address, such as a sandbox bridge,
  is allowed.
- The example keys `your-api-key-{1,2,3}` put CLIProxyAPI in a safe mode that
  turns its API off, so they are rejected.

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
  stop plugin sync and usage metrics from reaching other hosts. That file is
  written at evaluation, so an `instance` must be one Home Manager declares in
  `ai.proxy.instances`. It resolves to the same `registryEntry` the registry
  gets in the same generation; an undeclared name fails an assertion. A devenv
  shell inherits the user file with no devenv configuration.
- **devenv** cannot use project config: Codex strips `model_provider` and
  `model_providers` from project layers. Its launcher passes
  `-c model_providers.ai-proxy-devenv={…}` and
  `-c model_provider=ai-proxy-devenv`, the highest layer. The `url` form is
  baked in as `--add-flag`s. The `instance` form runs `ai-proxy-render --lines`
  at each launch, and a failed lookup aborts the launch. The quieting defaults
  go to the trusted project's config.toml.
- **A separate id on devenv is load-bearing.** Codex deep-merges layers per key,
  so session flags reusing `ai-proxy` would add their auth fields to the user
  table, and `auth` beside `experimental_bearer_token` fails to load.
- No `[profiles.*]` or `profile`: the pinned Codex rejects both.

`chatgpt-codex-proxy` runs the pinned binary against loopback mock proxies in
the build sandbox. It covers each Home Manager key form, both devenv forms, Home
Manager plus devenv with different key forms, and a missing instance aborting
the launch.

### Kimchi, Kiro, Copilot

Kimchi and Kiro are deferred. They receive the standard unsupported-surface
warning, not a silent drop. Copilot is out of scope and warns the same way.
Research and the per-harness permutation map are operator working files, outside
the repository.

### Checks

`checks/ai-proxy/module-eval.nix` covers selection validation, the per-runtime
override through a test runtime, units and registry, instance validation,
Darwin, devenv rejection, the unsupported warnings, an executed start script
against a stub proxy, and `ai-proxy-render` end to end.
`checks/ai-factory/factory-eval.nix` carries `proxy` in its every-surface
request set. `packages/chatgpt-codex/checks/chatgpt-codex-proxy.nix` holds the
Codex checks.
