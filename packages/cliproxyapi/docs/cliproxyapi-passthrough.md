# JSON passthrough upstreams

<!-- cspell:words httptest -->

Passthrough groups serve non-chat JSON APIs independently of OpenAI
compatibility. `POST /v1/passthrough` uses the auth conductor for credential
selection and execution.

```yaml
config-version: 8
api-keys:
  passthrough:
    - name: decision-free
      base-url: https://upstream.example
      path: /inference/v1/decision
      priority: 30
      request-retry: 0
      disable-cooling: false
      models:
        - name: upstream-model
          alias: decision
      keys:
        - api-key: <runtime secret>
```

`name`, HTTP(S) `base-url`, `path`, nonempty `models` and nonempty keyed `keys`
are required, including for disabled groups. Each model has `name` and optional
`alias`; keys have only `api-key`. `disabled: true` prevents credential
synthesis. Names are unique after trimming and lowercase normalization. Internal
provider identity is always `passthrough-<lowercase-name>`, including when the
supplied name already starts with `passthrough-`. Distinct groups may share a
base URL and API key; their aliases resolve within the selected group, using its
config index and identity rather than the first matching URL.
`registry.IsPassthroughProvider` recognizes passthrough provider keys.

The path may be rooted (`/inference/v1/decision`) or relative. Absolute URLs,
network-path references (`//host/path`), queries and fragments are refused. The
base must contain a hostname and no userinfo, query or fragment. Diagnostics
name the field and group/key index without printing the supplied URL or
credential. Invalid groups fail both management parsing and optional startup
loading. Unknown fields in a group, key or model entry are refused with
`api-keys.passthrough[N]: unknown or invalid field`.

The route accepts a JSON object containing `model: "decision"`; it rejects
streaming, empty models and non-boolean streaming flags. The executor rewrites
the top-level `model` with CPA's `helps.SetStringIfDifferent` when an alias
selects a different upstream model; the rest of the request is forwarded as
sent.

Client access uses CPA's existing client-key middleware. Allowlist rules grant a
specific internal provider and `kind: apikey`, optionally narrowed by credential
ID or base URL:

```yaml
access:
  api-keys: [client-key]
  key-allowlist:
    - api-key: client-key
      credentials:
        - provider: passthrough-decision-free
          kind: apikey
```

Once an allowlist exists, an unlisted client selects no credential. Config
synthesis supplies the API key and `config:` source required by the existing
allowlist; a file-backed API key does not inherit this grant. Higher group
priority wins among eligible credentials. `request-retry`, `disable-cooling` and
`request-scoped-errors` use native semantics; the route consumer uses the auth
conductor for in-request failover and cooldown rather than another retry loop.
In particular, `request-retry: 0` disables additional retry rounds; it still
permits selection of another eligible credential within the request. The route
fixture uses `SetRetryConfig(0, 0, 0)` (zero rounds, zero wait, unlimited
alternative credentials), group `request-retry: 0`, and
`disable-cooling: false`. It exercises priorities 30/20/10, two free credentials
returning 429 and 404, a paid credential returning 503, then a final successful
credential. The next client request skips the cooled credentials.

Disabling a group removes its synthesized auths. Management's
`/v8/management/config/api-keys/passthrough` projection exposes each live key's
`auth_index`, usable with management `api-call` and `$TOKEN$` substitution. Auth
indexes are projection metadata and are not accepted credential settings.

Models are registered internally for conductor eligibility, but excluded from
all public registry catalog projections even when no allowlist exists. An alias
also registered by a chat credential remains visible with that chat metadata.
Provider filtering works in both directions: the passthrough route selects only
raw groups, and chat, messages, responses and other protocols exclude them. The
executor also rejects chat entry or exit protocols, streaming and token
counting. The raw route bypasses model routers and plugin body transformations,
preserving the existing request context, access identity, lifecycle and
selected-auth capture.

Responses retain their bytes. A top-level `usage` object may contain nonnegative
integer `input_tokens` and `output_tokens`; missing usage records zero tokens.
Present malformed counters fail as 502. Native usage reporting preserves the
original requested alias, selected upstream model and authenticated client key.
The fixture reads the generic management usage queue for two different client
keys sharing one alias; failed attempts carry zero tokens.

Local mock upstreams use `httptest` random bound ports. The HTTP transport dials
those ports while retaining production-shaped default-port URLs and Host headers
without a port. This exercises path joining, Host routing, auth headers and
exact request/response bytes; it does not prove privileged port binding or live
upstream behavior.

The carried `patches/passthrough-provider.patch` applies after `key-allowlist`
and `zai-tool-shims` with zero fuzz. `cliproxyapi-passthrough` runs its config,
synthesis/alias/allowlist, management, executor, handler, registry and conductor
tests through the shared Go CI check. `cliproxyapi-extracted` and
`cliproxyapi-settings` gate measured schema and rendered settings.
