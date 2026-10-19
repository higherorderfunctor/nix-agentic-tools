## ai.proxy: local CLIProxyAPI for AI harnesses

> **Last verified:** 2026-10-18 — root and per-runtime `url` or `instance` +
> redacted `key` selection, resolved directly into null or `{key; url;}` at
> `ai.<runtime>.normalized.proxy`; an `instance` names an
> `ai.cliproxyapi.instances` entry and resolves to its loopback origin; Claude
> and Codex consume references through credential helpers using `redact.assign`.
> Other runtimes declare no proxy support and warn through delivery policy.

`ai.proxy` points a harness at a locally hosted CLIProxyAPI so the harness holds
only the proxy's client key, never an upstream credential. The proxy holds the
logins. `ai.mcpServers.<name>.proxy` (lib/ai/mcpProxy.nix) is an unrelated MCP
credential proxy.

### Shape

- Library: `lib/ai/proxy/default.nix`. Options, validation and `resolve` live
  there.
- `sharedOptions.nix` registers the root option and asserts the root selection.
- `proxy` is a key of `sharedSurfaceOptions`, so it is a delivery-policy surface
  and every enabled runtime whose `surfaceSupport` omits `proxy` gets the
  standard decomposition warning. Claude and Codex declare support; the other
  runtimes warn rather than dropping a selection silently.
- `mkBackendTransform.nix`, for a record whose `surfaceSupport` declares
  `proxy`, declares `ai.<runtime>.proxy` (same selection options as the root)
  and `ai.<runtime>.normalized.proxy`. The callbacks get it as
  `normalized.proxy` and `resolvedProxy`.

### Selection and the resolved endpoint

A selection is `url` + `key` for a proxy configured by hand, or `instance` +
`key` for one this flake runs. `instance` names an `ai.cliproxyapi.instances`
entry (`packages/cliproxyapi/modules/instances.nix`) and resolves through
`packages/ai-module/lib/instances.nix`'s `select` to `http://127.0.0.1:<port>`;
`key` is the same reference the instance lists in `settings.access.api-keys`,
`redacted` on both sides. `url` and `instance` are mutually exclusive. A
selection without a key, a key without a selection, or an instance that is
missing or disabled fails as an assertion at either scope, outside the runtime
enable gate; such an instance resolves to null. A selection without a key is
rejected because the harness would send its own login token, if any, to the
proxy. The instances are read as `config.ai.cliproxyapi.instances or {}`, since
an evaluation without the owner module (the factory harness) has none.

A per-runtime selection that selects anything (a `url` or an `instance`)
replaces the root selection WHOLE. Fields never mix across levels: a runtime
`key` alone leaves the root selection in force and fails its own assertion. The
resolved value is null or `{key; url;}`. `url` is the origin only: each runtime
appends its own protocol path, so a path would be doubled.

`key` requires `redact.types.redacted`: `redact.file`, `redact.command` or
`redact.concat` with a reference. It authenticates access to the proxy's
upstream subscriptions, so cleartext has no harmless use here. Root and
per-runtime options use the same type as the normalized endpoint.

References remain unresolved during evaluation. A consuming runtime must use
`redact.assign` when its launcher or credential helper starts and escape the
resolved value for its destination format. A key's contents cannot be
charset-checked at evaluation; never substitute the runtime value unescaped into
JSON, TOML or shell source. The `url` pattern validates only the proxy origin.

### Checks

`checks/ai-proxy/module-eval.nix` covers selection validation, redacted key
refusal and the per-runtime override through a test runtime that declares
`proxy`, each with the instance case on both backends. The unsupported-runtime
warnings are `ai-warnings-delivery`'s generated cases, driven by its `proxy`
sample (the url form). `checks/ai-factory/factory-eval.nix` carries `proxy` in
its every-surface request set. `packages/claude-code/checks/claude-proxy.nix`
checks settings and runs the file, command and concat helpers on both backends.
`packages/chatgpt-codex/checks/chatgpt-codex-proxy.nix` checks Codex's provider
settings and session flags, runs the reference helpers, and sends requests
through the pinned Codex to loopback proxies on both backends.
