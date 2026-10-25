# airlock configuration and Claude integration

> **Last verified:** 2026-10-25 — a managed Claude primary exchanges fake OAuth
> tokens through both generated launchers; storage scopes the pair to one
> client.

## Nix configuration

`modules/instances.nix` is one module for Home Manager and devenv, through
`packages/ai-module/lib/instances.nix`. Each instance is the `ai.services` entry
`airlock-<name>` running `airlock serve --config "$AIRLOCK_CONFIG"`; the helper
claims its port and service name.

`settings` mirrors Rust's `RawConfig`: the render renames `stateDir` to
`state_dir`, `unknownHosts` to `unknown_hosts`, and client `token` to
`token_file`, while omitting null `preset` and managed OAuth `file`. Rust checks
IDs, references, URLs, protocols, primary and model ownership for direct JSON
and Nix output. `airlock-config-roundtrip` feeds rendered settings to
`check-config`; raw structs deny unknown fields.

`providers.<id>` holds a `claude` or `zai` preset and optional protocol-keyed
endpoint overrides. Rust expands each preset once: Claude Anthropic resolves to
`https://api.anthropic.com`; z.ai Anthropic to `https://api.z.ai/api/anthropic`;
z.ai OpenAI to `https://api.z.ai/api/coding/paas/v4`. No Codex endpoint is
asserted yet. `credentials.<id>` names a provider and auth mode. `groups.<id>`
names one protocol, its first-party intercept hosts, a primary credential, and
members with exact model IDs. A client grants whole groups. The primary owns
undeclared models; non-primary members need explicit IDs. Duplicate model IDs
within a group are invalid.

Client tokens and file-backed credentials use `redact.types.secretFile`; the
service launcher writes each value to a 0600 runtime file and renders only its
absolute path. A managed OAuth credential has no file. Its active route must be
a Claude-preset Anthropic primary, granted to exactly one client, with
`platform.claude.com` intercepted. Unsupported managed routes and active OpenAI
fail before secret loading. Endpoint overrides may include a port for local
tests.

## Harness selection

Claude selects an instance through
`ai.claude.proxy = { instance = "<airlock instance>"; clientKey = "<client>"; }`.
CPA and airlock instance names share one claim group, so a name resolves to one
owner. Only Claude supports airlock; another runtime selecting it fails
evaluation. On Linux the jail is required; config-only and non-Linux surfaces
warn and get no launcher.

At launch Claude reads its client's `token_file` from the service-rendered
config, exports a percent-encoded `HTTPS_PROXY`, and clears other proxy
variables. Its route overlay blanks the CPA base URL and `apiKeyHelper`. Picker
IDs come only from the selected client's granted Anthropic group intercepting
`api.anthropic.com`, including explicit primary declarations. Home Manager
writes those rows to user settings; devenv passes them in its `--settings`
overlay. Only the managed settings scope loads (user on Home Manager, project on
devenv), so another scope cannot override the route; managed admin policy is
outside this contract. The jail gets system roots plus the current `ca.pem` as a
read-only bundle over `/etc/ssl/certs/ca-certificates.crt`, rebuilt per launch.
A missing token, config, roots, or CA fails the launch without CPA or direct
fallback.

For a file-backed primary, Claude receives a fixed fake environment token. For
managed OAuth, its launcher clears `CLAUDE_CODE_OAUTH_TOKEN`, so Claude's native
credential store drives login and refresh. The harness stores only the fake
pair. It keeps nonessential traffic and claude.ai connectors enabled.

## Managed primary OAuth

Airlock intercepts `POST /v1/oauth/token` and `POST /v1/oauth/token/revoke` on
`platform.claude.com`. The authenticated CONNECT client and configured primary
determine ownership. Initial authorization-code parameters pass through
unchanged. A refresh or revoke must present that client's current fake refresh
token; airlock substitutes the real token before forwarding. Exchange and
replacement are serialized per configured primary. Another primary can exchange
while one provider stalls. Upstream connection, response headers, and token body
share a 30-second deadline; cancellation drops the pending exchange without
changing the stored mapping.

A successful exchange must contain a real access token usable as a bearer header
and positive `expires_in`. The initial exchange also requires a refresh token. A
present refresh token or refresh lifetime with an invalid type fails closed.
Airlock stores the real pair and client-owned fake mapping in one transaction
before returning provider-shaped JSON with fake tokens. The fake access lifetime
is one hour or the real remaining lifetime, whichever is shorter. Expiry starts
when the upstream request begins, including response and storage delay; airlock
rejects a token that has expired before acknowledgement and reports lifetimes
remaining after the durable commit. A refresh response without a new refresh
token retains both old refresh tokens. Its known expiry stays as a cap when the
response supplies a new refresh lifetime; a supplied lifetime fills an unknown
expiry. Airlock returns only the remaining refresh lifetime to Claude. Returned
account, organization, and scope fields pass through. On upstream OAuth failure,
the status and recognized OAuth error code pass through; arbitrary error
descriptions are dropped because an upstream could echo a credential. Only a
successful upstream revoke retires the mapping.

On regular managed requests to the primary API host, Airlock accepts only the
current unexpired fake access token for the authenticated client and sends the
real access token in a sensitive Authorization header. Unknown, expired, or
retired fakes fail locally. A storage or clock failure returns 503 rather than
an authentication failure. Other paths on `platform.claude.com` are refused, as
are path variants of `create_api_key`; that endpoint would return a real
provider credential. Token JSON is bounded and held in zeroizing buffers. A
parse or durable-store failure never returns a real token pair.

The generated `airlock-claude-native-oauth` check runs the pinned Claude binary
through both Home Manager and devenv launchers against a loopback fake upstream.
It proves native authorization-code login from an empty credential store, native
refresh, fake-pair persistence, and profile and Messages use inside an isolated
network namespace without real provider access. Operator browser login and an
expiry-boundary observation remain separate live checks before the operator
switches to it.
