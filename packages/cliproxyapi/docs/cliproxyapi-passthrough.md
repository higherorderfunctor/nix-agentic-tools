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
      unwrap: result
      usage-path: result.usage
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
sent. Without `unwrap`, responses are returned unchanged. With `unwrap`, the
selected object is returned as its original JSON span.

Envelope options apply per group, so one alias can fail over between plain and
wrapped APIs. `unwrap` and `usage-path` are nonempty dot-separated object-key
paths whose segments start with a letter or `_` and contain letters, digits, `_`
and `-`; arrays, wildcards and query syntax are refused. `usage-path` defaults
to top-level `usage` and always refers to the original response, before unwrap.
An explicitly configured missing usage path fails as 502; missing default usage
records zero tokens. An unwrap selecting anything other than an object,
malformed JSON and malformed present usage counters fail as 502. HTTP non-2xx
failures keep their status without envelope parsing.

For example, a plain System One-shaped response is
`{"model":"upstream-model","answers":[],"usage":{"input_tokens":7,"output_tokens":3}}`.
A Cloudflare-shaped response wraps that same object in `result`, alongside
`success`, `errors` and `messages`; its group sets `unwrap: result` and
`usage-path: result.usage`. Cloudflare reports failures, including an exhausted
free allocation (HTTP 429), as non-2xx statuses, which native failover handles.
These shapes are exercised using generic fixture identifiers; no vendor-specific
executor is involved.

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

Responses without unwrap retain their bytes. The selected `usage` object may
contain nonnegative integer `input_tokens` and `output_tokens`; missing default
usage records zero tokens. Present malformed counters fail as 502. Native usage
reporting preserves the original requested alias, selected upstream model and
authenticated client key. The fixture reads the generic management usage queue
for two different client keys sharing one alias; failed attempts carry zero
tokens.

Local mock upstreams use `httptest` random bound ports. The HTTP transport dials
those ports while retaining production-shaped default-port URLs and Host headers
without a port. This exercises path joining, Host routing, auth headers and
exact request/response bytes; it does not prove privileged port binding or live
upstream behavior. An envelope fixture retries from a plain 429 group through a
wrapped credential that also returns 429 to another credential on the same
alias; a second request skips both cooled credentials. Each attempt rewrites the
model from the original client body and publishes one native usage record, with
tokens only on success.

The carried `patches/passthrough-provider.patch` applies after `key-allowlist`
and `zai-tool-shims` with zero fuzz. `cliproxyapi-passthrough` runs its config,
synthesis/alias/allowlist, management, executor, handler, registry and conductor
tests through the shared Go CI check. `cliproxyapi-extracted` and
`cliproxyapi-settings` gate measured schema and rendered settings.

## Named Nix credentials

Both Home Manager and devenv lower `credentials.<name>.apiKey.apis.passthrough`
through the shared API table. Declare models on this API as nonempty
`{ name; alias?; }` objects; the credential-wide string `models` fallback
belongs to chat, Anthropic and Responses only. `apiKey.priority` applies to the
group.

```nix
credentials.decision-free.apiKey = {
  apis.passthrough = {
    base-url = "https://api.cloudflare.com";
    models = [{ alias = "decision"; name = "clef"; }];
    path = redact.concat [
      "/client/v4/accounts/"
      (redact.file "/run/secrets/cloudflare-account-id")
      "/ai/run/@cf/cloudflare/clef"
    ];
    unwrap = "result";
    usage-path = "result.usage";
  };
  key = redact.file "/run/secrets/upstream-key";
  priority = 30;
};
clientKeys.decisions = {
  key = redact.file "/run/secrets/decision-client-key";
  routes = [{ credential = "decision-free"; }];
};
```

`base-url` and `path` accept literal public values or redact references,
including concatenations. Supply secret account identifiers through references.
Direct typed `settings.api-keys.passthrough` supports the same URL references,
and allowlist `base-urls` elements accept them while retaining nonempty-list and
null refusal. The shared secrets engine resolves references at service start; no
secret value is read during evaluation. CPA validates resolved URLs and paths
without printing them. Literal paths reject absolute URLs and `//` references
and permit rooted components such as `/inference/v1/decision`.

Named rules use `provider = "passthrough-<lowercase-name>"`, `kind = "apikey"`
and the selected base URL reference. Free and paid groups may share that URL;
their distinct names keep each rule scoped to its group. Nix checks lowercase
name collisions between named credentials. CPA checks all group names at
startup, including raw settings blocks. Existing families retain their
shared-base-URL refusal.

Passthrough routes retain their client key and CPA allowlist rules but
contribute no credential to `inferenceInstances` or a harness's normalized
credentials or model picker. A client can use the same key directly with
`POST /v1/passthrough`. No vendor defaults, delegate-routing families or model
lists are added.

`cliproxyapi-passthrough-module` covers both module backends, literal lowering,
secret URL render/substitution, path refusal, model shape, normalized
duplicates, nonempty merged lists and inference fanout. It also loads a
synthetic rendered config through CPA in CI.
