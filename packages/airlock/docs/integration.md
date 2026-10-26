# airlock configuration and Claude integration

> **Last verified:** 2026-10-25 — managed OAuth uses client-scoped fake tokens;
> M08 adds usage selection and quota reports, while M10 verifies real-service
> classifier/remote-control routing and pinned Claude's signed `cch` identity;
> the separately enabled control listener serves strict usage APIs, static
> assets, and bounded WebSocket views; shutdown drains upgraded sockets and
> closes the control reader before the storage owner closes.

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

`providers.<id>` holds a `claude`, `codex`, or `zai` preset and optional
protocol-keyed endpoint overrides. Rust expands each preset once: Claude
Anthropic resolves to `https://api.anthropic.com`; z.ai Anthropic to
`https://api.z.ai/api/anthropic`; z.ai OpenAI to
`https://api.z.ai/api/coding/paas/v4`. The Codex preset names no inference
endpoint; it is eligible only for an explicitly selected usage fetch.
`credentials.<id>` names a provider, auth mode, and optional provider account
ID. `usage.credentials` selects additional credentials for out-of-band quota
collection. Active Claude and z.ai group credentials are collected
automatically; Codex remains inert unless selected. `groups.<id>` names one
protocol, its first-party intercept hosts, a primary credential, and members
with exact model IDs. A client grants whole groups. The primary owns undeclared
models; non-primary members need explicit IDs. Duplicate model IDs within a
group are invalid.

Configuration validation caps the report projection before route/model copies:
at most 64 usage credentials, 256 client/group/member routes, and 8,192 copied
model IDs. An oversized config is rejected by `check-config` and serve alike.
The collector projects credential identity and its sole owner without allocating
report routes or model lists.

Client tokens and file-backed credentials use `redact.types.secretFile`; the
service launcher writes each value to a 0600 runtime file and renders only its
absolute path. A managed OAuth credential has no file. Its active route must be
a Claude-preset Anthropic primary, granted to exactly one client, with
`platform.claude.com` intercepted. Unsupported managed routes and active OpenAI
fail before secret loading. Endpoint overrides may include a port for local
tests.

The usage collector reads each selected file-backed credential from its rendered
runtime file, or the current real managed OAuth access token from SQLite. It
never reads Claude's home files or refreshes OAuth itself. The same option shape
and secret delivery apply in Home Manager and devenv. Usage reports list every
granted client/group/model route for a credential, including which primary owns
undeclared models. Collection still runs once per credential.

## Control listener

The dedicated dashboard listener and bounded subscription protocol are
documented in `docs/control.md`.

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

## Offline feature preservation

Evidence levels: **verified offline** uses a loopback fake; **source contract**
identifies a pinned-client shape with limited offline exercise;
**live-unverified** needs the operator's real account or device. No row claims
real provider behavior.

| Feature                                           | Offline evidence                                                                                                                                                                                                                                                                                                                                                                                                 | Remaining boundary                                                                                                                                                                                                                         |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Generated launcher and CONNECT identity           | Verified offline by `airlock-claude-launch`, `airlock-claude-selection`, `airlock-claude-native-settings`, and config/module checks. These prove generated launchers/settings and CONNECT behavior; `airlock-claude-native-oauth` additionally drives pinned Claude through a Python fake CONNECT proxy.                                                                                                         | Real browser login and each operator device remain live-unverified.                                                                                                                                                                        |
| Actual service and launcher composition           | Verified offline by `airlock-claude-composite-routes` on Home Manager and devenv: the generated service launcher starts the real Airlock package, NSS maps the DNS endpoint to loopback, and a generated client drives both Messages comparisons plus all six remote-control calls through each generated Claude launcher.                                                                                       | The client is generated, the upstream is fake, and the check proves route composition rather than pinned-client behavior, real provider semantics, or an end-to-end `/rc` session. Pinned-client and real-provider checks remain separate. |
| Managed OAuth login, refresh, storage, and expiry | Verified offline by `airlock-claude-native-oauth`, managed OAuth and expiry unit tests, and `managed_primary_collection_uses_replaced_real_token_and_refuses_expiry`; the native check uses generated launchers with a mocked Airlock service.                                                                                                                                                                   | Operator login, an expiry-boundary observation, and account notices remain live-unverified.                                                                                                                                                |
| Profile, bootstrap, and Messages                  | Verified offline by `airlock-claude-native-oauth` against `/api/oauth/profile`, `/api/claude_cli/bootstrap`, and `/v1/messages`; the current pinned client retains the signed first-party `cch` billing block, and the check uses the generated launchers with a mocked Airlock service.                                                                                                                         | Full bootstrap schema, entitlement gating, and real account behavior remain live-unverified.                                                                                                                                               |
| Usage routes and account semantics                | Verified offline: `/api/oauth/usage` primary routing in `tests/intercept.rs`; `fake_provider_transport_is_bound_to_host_path_auth_and_budgets` and typed collector parser tests for Claude, z.ai and explicit Codex; `read_only_json_contract_keeps_header_age_and_request_usage_separate` for report JSON; `delegate-routing-usage-runtime` for consumer selection. The CLI read-only wiring is source-checked. | Correlating `extra_usage` and `wattle_ember` with the real account page remains live-unverified.                                                                                                                                           |
| Model routing and listing                         | Verified offline: exact Claude/GLM selection, undeclared-model primary ownership, late/chunked models, and `/v1/models` pagination/errors stay on their selected routes.                                                                                                                                                                                                                                         | The actual first-party returned model set and picker experience remain live-unverified.                                                                                                                                                    |
| Inference and ToolSearch                          | Verified offline for body bytes, primary/z.ai attribution, headers, SSE first-event flush, and ToolSearch cancellation; M08's `primary_headers_do_not_change_zai_usage_attribution_or_body_bytes` and `toolsearch_sse_flushes_first_event_and_keeps_usage` cover usage accounting.                                                                                                                               | Real tool approval quality and provider behavior remain live-unverified.                                                                                                                                                                   |
| Auto-mode client classifier                       | Verified offline in gateway tests: exact `auto-mode-classifier-2026-07-16` and classifier-prefix drift route GLM bodies to primary, with a fixed-reason warning for drift; ordinary `dangerous-tool-use-2026-09-03` GLM traffic routes to z.ai. `airlock-claude-composite-routes` repeats the exact-versus-ordinary comparison through the real service and both generated launchers.                            | The exact beta remains a source contract for the separate client classifier. Real classifier verdicts and persistence after a client update remain live-unverified.                                                                        |
| Server dangerous-tool-use safeguard               | Source contract: the GLM main request may carry `dangerous-tool-use-2026-09-03` and embedded safeguard context; Airlock leaves its body and model route unchanged.                                                                                                                                                                                                                                               | What z.ai does with that safeguard remains an operator live check.                                                                                                                                                                         |
| Remote Control bridge API                         | Verified offline in the gateway tests for the six measured bridge, poll, ack, stop, delete, and offline methods: all preserve method, path, body bytes, and primary routing on one CONNECT connection. The composite check repeats that family through the real service and both generated launchers.                                                                                                            | Complete endpoint set, WebSocket/SSE/heartbeat semantics, trust-device enrollment, feature gating, and an end-to-end `/rc` run remain live-unverified.                                                                                     |
| Streaming, cancellation, upgrades, and errors     | Verified offline for HTTP/1 and HTTP/2 streams, first SSE event timing, upgrade relays, half-close cancellation, selected-provider failure, and malformed/oversized requests. M08's `stalled_usage_sink_does_not_delay_first_or_last_response_bytes` and queue-loss tests cover collector isolation.                                                                                                             | Real network latency and provider failure variety remain live-unverified.                                                                                                                                                                  |

Operator cutover still requires the live checks in the matrix's boundaries.

## Managed primary OAuth

The token exchange, refresh, and revoke boundary is documented in
`docs/oauth.md`.
