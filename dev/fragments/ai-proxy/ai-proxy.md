## ai.proxy: local CLIProxyAPI for AI harnesses

> **Last verified:** 2026-10-21 — instance-routed runtimes publish their own key
> and allowlist entry; key references are claimed across runtimes.

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
  `proxy`, declares `ai.<runtime>.proxy` (the root's selection options plus
  `allow`) and `ai.<runtime>.normalized.proxy`. The callbacks get it as
  `normalized.proxy` and `resolvedProxy`. Enabled runtimes publish their client
  key and claim.

### Selection and the resolved endpoint

A selection is `url` + `key` for a proxy configured by hand, or `instance` +
`key` for one this flake runs. `instance` names an `ai.cliproxyapi.instances`
entry (`packages/cliproxyapi/modules/instances.nix`) and resolves through
`packages/ai-module/lib/instances.nix`'s `select` to `http://127.0.0.1:<port>`;
`url` and `instance` are mutually exclusive. A selection without a key, a key
without a selection, or an instance that is missing or disabled fails as an
assertion at either scope, outside the runtime enable gate; such an instance
resolves to null. A selection without a key is rejected because the harness
would send its own login token, if any, to the proxy. The instances are read as
`config.ai.cliproxyapi.instances or {}`, since an evaluation without the owner
module (the factory harness) has none.

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

### Runtime keys and the allowlist

A runtime routed through an instance publishes its key and `allow` rules at
`ai.internal.proxyClients.<runtime>`. The instance adds that key to
`access.api-keys` and maps `allow` to its `access.key-allowlist` entry. The
launcher presents the same key through `normalized.proxy`; CPA fails closed for
each listed key (see `cliproxyapi-key-allowlist.md`).

The instance reads published clients. A runtime must not define the instance:
that would make a misspelled name look valid, and checking existence from the
definition would recurse.

`allow` uses CPA's generated credential-rule type. Claude and Codex default to
their own OAuth provider; another runtime must set `allow` when it routes
through an instance. It applies to either root or runtime selection. Narrow it
by `ids` or name a hand-written credential block.

Refused at evaluation, inside the enable gate:

- One key reference on two runtimes: each claims `proxy-client-key` through
  `ai.<runtime>.claims`. A root instance selection therefore serves one enabled
  runtime. Evaluation cannot compare secret values; if distinct references
  resolve to one key, CPA refuses startup or keeps the old config on reload.
- A runtime key also listed by hand in `access.api-keys`, or given a
  hand-written `access.key-allowlist` entry: a second owner could widen or
  contradict its rules. Counting runtime clients first ensures a shared key
  reports the claim rather than a hand-written-entry error.

A `url` selection and a disabled runtime publish nothing. A hand-written key of
some other client stays allowed, but once any runtime routes through the
instance the allowlist is set, so that key needs its own hand-written entry.

### Checks

`checks/ai-proxy/module-eval.nix` covers selection validation, redacted key
refusal and the per-runtime override through a test runtime that declares
`proxy`, each with the instance case on both backends.
`module-ai-proxy-instance-clients` checks the derived access list, claims,
runtime endpoints, and routing refusals on both backends. Unsupported runtimes
are covered by `ai-warnings-delivery`. `checks/ai-factory/factory-eval.nix`
carries `proxy` in its every-surface request set.
`packages/claude-code/checks/claude-proxy.nix` checks settings and runs the
file, command and concat helpers on both backends.
`packages/chatgpt-codex/checks/chatgpt-codex-proxy.nix` checks Codex's provider
settings and session flags, runs the reference helpers, and sends requests
through the pinned Codex to loopback proxies on both backends.
