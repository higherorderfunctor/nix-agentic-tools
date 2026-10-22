## ai.proxy: local CLIProxyAPI for AI harnesses

> **Last verified:** 2026-10-22 — instance-routed runtimes publish claimed keys
> and provider-scoped allowlist rules; Claude and Codex offer enabled providers
> in their model pickers.

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
  `allow` and `providers`) and `ai.<runtime>.normalized.proxy`. The callbacks
  get it as `normalized.proxy` and `resolvedProxy`. Inside the runtime's enable
  gate it publishes the runtime's client and key claim.

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
resolved value is null or `{key; providers; url;}`. `url` is the origin only:
each runtime appends its own protocol path, so a path would be doubled.

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
`access.api-keys` and maps `allow` plus one rule per enabled provider to its
`access.key-allowlist` entry. The launcher presents the same key through
`normalized.proxy`; CPA fails closed for each listed key (see
`cliproxyapi-key-allowlist.md`).

The instance reads published clients. A runtime must not define the instance:
that would make a misspelled name look valid, and checking existence from the
definition would recurse.

`allow` uses CPA's generated credential-rule type. Claude and Codex default to
their own OAuth provider; another runtime must set `allow` or enable a provider
when it routes through an instance. `allow` and `providers` apply whichever
scope selects. Set `allow = []` to drop the own login; a rule can narrow it by
`ids` or name a hand-written credential block.

### Providers

`ai.cliproxyapi.instances.<n>.providers.<name>` supplies a key, models and base
URLs for the `anthropic`, `chat` or `responses` API. The API table in
`packages/cliproxyapi/lib/providers.nix` lowers each to CPA's credential family;
the settings list joins provider blocks with hand-written blocks. A runtime
enables one through `ai.<runtime>.proxy.providers.<name>.enable`; its optional
`api` defaults to its record's `proxyApi` (Claude `anthropic`, Codex
`responses`). The generated allowlist rule names the selected block's provider
and base URL.

CPA trims base URLs with Go's `strings.TrimSpace`, which Nix cannot reproduce
for every Unicode space. Provider URLs are printable ASCII, hand-written URLs in
their family must have printable edges, and blocks in that family cannot share
the provider's URL. These checks make CPA's exact match agree with Nix's.
Provider names are plain ASCII words so Go and Nix normalize them alike and
Codex can use them as profile file names.

`normalized.proxy.providers` is `[{name; models;}]`: Claude turns it into
`/model` picker rows and Codex into `-p` profiles (`ai-proxy-runtimes.md`).

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

`module-ai-proxy-instance-clients` checks generated blocks, claims, rules and
refusals on both backends. `module-service-instances-runtime-providers` sends
Anthropic and Responses requests through the packaged CPA. The other proxy
checks cover selection, key references and runtime delivery.
