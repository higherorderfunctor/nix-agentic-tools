## ai.proxy: selecting a proxy for AI harnesses

> **Last verified:** 2026-10-29 — proxy owners register instances in
> `ai.internal.proxyInstances`, with or without named clients; set root fields
> copy down by priority and are withdrawn for a runtime selecting the other
> form; the selected instance's backend picks the one lowering a runtime runs,
> and a runtime without it fails an assertion. Upstream credentials are in
> `packages/cliproxyapi/docs/cliproxyapi-providers.md`.

`ai.proxy` selects a registered proxy instance or an external CLIProxyAPI
endpoint for a harness. The selected instance's backend determines how that
harness consumes the endpoint. `ai.mcpServers.<name>.proxy`
(lib/ai/mcpProxy.nix) is an unrelated MCP credential proxy.

### Shape

- Library: `lib/ai/proxy/default.nix`. Options, the registry, validation,
  `resolve` and `forRuntime`, which binds a runtime's lowering to its assertion,
  live there. It names no proxy owner but one: an external `url` has no registry
  entry, so it lowers as `cliproxyapi`, named once in `externalBackend`.
- `sharedOptions.nix` registers the root option and `ai.internal.proxyInstances`
  and asserts the root selection.
- `proxy` is a key of `sharedSurfaceOptions`, so it is a delivery-policy surface
  and every enabled runtime whose `surfaceSupport` omits `proxy` gets the
  standard decomposition warning. Claude and Codex declare support; the other
  runtimes warn rather than dropping a selection silently.
- `mkBackendTransform.nix`, for a record whose `surfaceSupport` declares
  `proxy`, declares `ai.<runtime>.proxy` with the root's selection options and
  `ai.<runtime>.normalized.proxy`. The callbacks get it as `normalized.proxy`
  and `resolvedProxy`. Harness selection publishes no keys, rules or claims;
  these belong to the selected instance's named entries.

### Registry

A proxy owner adds each instance to `ai.internal.proxyInstances.<name>` by
ordinary module merge: `{backend; enable; url; clients;}`. `backend` is the
owner's name (`ai.<backend>`). `clients.<clientKey> = {...}` holds the
attributes that backend's lowering reads for each named client; an owner whose
instances have no clients leaves `clients` null, and its instances are selected
by name alone. The owner also claims each name in `ai.claims.proxy-instance`
(`ai.<owner>.claims.proxy-instance`), so two owners registering one name fail
evaluation through the claims registry. The registry is internal: a root option
would count as a consumer surface and fan out. CLIProxyAPI's instance entries
and client routes are described in
`packages/cliproxyapi/docs/cliproxyapi-client-keys.md`.

### Selection and the resolved endpoint

A selection is `url` + `key` for a CPA configured by hand, or `instance` for a
registered instance; `url` and `instance` are mutually exclusive. An instance
that declares clients needs `clientKey` naming one of them; a clientless
instance refuses one. Unregistered or disabled instances, unknown or unwanted
client keys, and incomplete selections fail as assertions at either scope,
outside the runtime enable gate. An external selection without a key is rejected
because the harness would send its own login token, if any, to the proxy.

Each set root field copies down to `ai.<runtime>.proxy` at `mkDefault`, so a
runtime value wins field by field: root `instance = "a"` with
`ai.claude.proxy.instance = "b"` gives Claude `b` with the root's `clientKey`. A
runtime opts out of an inherited selection with `instance = null` (or
`url = null` for an external one); the fields it leaves behind are ignored,
since an unselected runtime is checked only on the fields it changed. A runtime
selection equal to the root's is asserted once, at `ai.proxy`. A runtime that
selects the other form (`instance` under a root `url`, or `url` under a root
`instance`) inherits none of the root's fields of that form, so switching forms
clears nothing by hand; within one form the per-field override still applies. An
unset root field adds no definition, so a profile module's own `mkDefault`
runtime value meets no conflict. `copyDown` keeps the form test inside each
copy's `mkIf`, which reads the runtime's other selector only while the root's is
null, so no copy reads itself back.

The resolved value is null or `{backend; url;}` plus the selected client's
attributes when the instance declares clients; an external selection resolves to
`{backend = "cliproxyapi"; key; url; credentials = [];}`. `url` is the origin
only: each runtime appends its own protocol path, so a path would be doubled.
Each runtime's proxy library keeps `lowerings.<backend>` and calls
`forRuntime <runtime> lowerings` once for both `lower` and `assertions`. Only
the selected backend's lowering runs; an unsupported backend lowers to nothing
and fails an assertion naming it.

An external `key` or an instance client entry's `key` requires
`redact.types.redacted`: `redact.file`, `redact.command` or `redact.concat` with
a reference. It authenticates access to the proxy's upstream subscriptions, so
cleartext has no harmless use here. Root and per-runtime `key` options refuse
cleartext at entry with that type. `normalized.proxy` declares only `backend`
and `url` and passes the selected client's attributes through unchecked.

References remain unresolved during evaluation. A consuming runtime must use
`redact.assign` when its launcher or credential helper starts and escape the
resolved value for its destination format. A key's contents cannot be
charset-checked at evaluation; never substitute the runtime value unescaped into
JSON, TOML or shell source. The `url` pattern validates only the proxy origin.

### Checks

`module-ai-proxy-instance-clients` checks generated blocks, named routes, exact
OAuth account placeholders, rules and refusals on both backends. The native
allowlist check covers account matching and hot-added logins.
`module-ai-proxy-z-ai-credential` checks vendor defaults and overrides on both
backends, including client routing and the preserved model list.
`module-service-instances-runtime-providers` sends Anthropic and Responses
requests through the packaged CPA, including a Codex CLI client key routed to a
chat-only upstream credential and an unauthorized-model negative control. The
other proxy checks cover selection, key references and runtime delivery.
