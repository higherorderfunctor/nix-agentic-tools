# JSON passthrough upstreams

Passthrough groups serve non-chat JSON APIs independently of OpenAI
compatibility. The same PR supplies `POST /v1/passthrough` and its consumer; the
config/auth portion alone is not a deployable feature. Keep the PR draft until
the route, conductor integration and measured settings extraction pass CI
together.

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

The path may be rooted (`/inference/v1/decision`) or relative. Absolute URLs,
network-path references (`//host/path`), queries and fragments are refused. The
base must contain a hostname and no userinfo, query or fragment. Diagnostics
name the field and group/key index without printing the supplied URL or
credential. Invalid groups fail both management parsing and optional startup
loading.

The route accepts a JSON object containing `model: "decision"`; it rejects
streaming. The route consumer in this PR forwards the original JSON bytes,
rewriting only the top-level model value when an alias selects a different
upstream model. Responses remain unchanged. Envelope options (`unwrap`,
`usage-path`, `error-in-200`) are a separate extension and are not declared by
this config/auth implementation.

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

Synthesis includes the group path, models and policy in a change fingerprint. A
path change preserves credential identity and replaces stale auth attributes;
disabling a group removes its synthesized auths. Management's
`/v8/management/config/api-keys/passthrough` projection exposes each live key's
`auth_index`, usable with management `api-call` and `$TOKEN$` substitution. Auth
indexes are projection metadata and are not accepted credential settings.

The carried `patches/passthrough-provider.patch` applies after `key-allowlist`
and `zai-tool-shims` with zero fuzz. `cliproxyapi-passthrough` runs its config,
synthesis/alias/allowlist and management tests through the shared Go CI check.
`cliproxyapi-extracted` and `cliproxyapi-settings` gate measured schema and
rendered settings. Regenerate extracted facts remotely on the draft PR before
readiness.
