# Kimchi CLI — server-side HTTP surface

This is a census of every network endpoint the Kimchi CLI can reach, what each
one is for, how its target is changed, and what stops working if it is
unreachable. It describes **1.1.37**. The 1.1.37 source tree is the one the
package pins (identified by its NAR hash against
`extraction.kimchiSource.hash`); the 1.1.30 to 1.1.36 release trees were fetched
by tag for bisecting, and the hashes of 1.1.30–1.1.33 and 1.1.36 match the pins
this repository recorded for those versions. The 1.1.21 to 1.1.30 history rests
on the earlier trees 1.1.21 through 1.1.27 and 1.1.29, the shipped 1.1.30 binary
(`kimchi-1.1.30/bin/kimchi` and its sibling `share/kimchi/bin/proxy-helper`),
and a 2026-09-21 scrape of the documentation site, which was not repeated.

Every endpoint claim below is cited to a file and line in a named version.
Unprefixed citations such as `src/models.ts:31` are the **1.1.37** tree; a
version prefix such as `30: src/…` names another, and marks a row that no longer
exists at 1.1.37. `B30:L…` and `B36:L…` index the strings dumps of the 1.1.30
and 1.1.36 binaries and are used only where no source citation exists: the
vendored SDKs and the upstream harness in section 6, and the vendored memory
library of section 2.2. The harness citations still describe 1.1.37 because the
bundled `@earendil-works/pi-*` packages are 0.85.1 at 1.1.30 and 1.1.37 alike,
Kimchi's `pi-ai` patch is byte-identical across that range, and its
`pi-coding-agent` patch changed only how `AgentSession` assembles messages.

## 1. Hosts

| Host                                                       | Role                                                                                                                                  | Default base URL                                                                                                                                                                                                                                                 | Repoint mechanism                                                                                                                                                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `llm.kimchi.dev`                                           | Inference gateway, plus a small control plane at the root: model metadata, model router (through 1.1.36), web search, credits, budget | `https://llm.kimchi.dev` (`src/regions.ts:28`, used when `llmEndpoint` is unset at `src/models.ts:20`) and `https://llm.kimchi.dev/openai/v1` (`src/regions.ts:86-88`, the `llmEndpoint` default at `src/config.ts:595`) — see section 4.6 for why there are two | the region (section 4.10); then config key `llmEndpoint` in `~/.config/kimchi/config.json`, or a trusted project `.kimchi/config.json`, for everything except web search and the experimental pool                        |
| `app.kimchi.dev`                                           | Remote-workspace control plane under `/api`, account identity, and the browser login page at `/cli-auth`                              | `https://app.kimchi.dev/api` (`src/regions.ts:81-83`, consumed at `src/sandbox/cloud/http.ts:5-8` and `src/api/me.ts:20-24`; the Go helper's own copy at `tools/proxy-helper/pkg/cast/cast.go:203`); web app `https://app.kimchi.dev` (`src/regions.ts:27`)      | the region; env `KIMCHI_REMOTE_ENDPOINT` overrides the API base (the **whole** base including `/api`), env `KIMCHI_WEB_APP_URL` the login page (`src/config.ts:655-662`). The Go helper ignores the region — section 4.10 |
| `<workspace>.remote.kimchi.dev`                            | Per-workspace worker: sessions, git identity, secrets, and the agent/terminal WebSocket                                               | none — the host arrives as the `uri` field of the workspace record and is parsed by `src/sandbox/cloud/uri.ts:3-29`                                                                                                                                              | none; server-assigned                                                                                                                                                                                                     |
| `api.cast.ai`                                              | Telemetry ingest, usage analytics, and API-key validation in the setup wizard                                                         | `https://api.cast.ai` (`src/regions.ts:29`; paths built at `:105-116`, analytics base at `src/extensions/stats/api.ts:26`)                                                                                                                                       | the region; for telemetry only, config keys `telemetry.endpoint` and `telemetry.metricsEndpoint` win over it (`src/config.ts:520-521`). Analytics and validation follow the region and nothing else                       |
| `llm.eu.kimchi.dev`, `app.eu.kimchi.dev`, `api.eu.cast.ai` | The EU counterparts of the three rows above, new in 1.1.35. Every path on those rows exists under the EU host too                     | `src/regions.ts:31-37`                                                                                                                                                                                                                                           | env `KIMCHI_REGION=eu`, or `region: "eu"` in the global config file, which login writes. The login picker offers EU only with experimental features on (`src/regions.ts:74-78`)                                           |
| `api.github.com`, `github.com`, `registry.npmjs.org`       | Release lookup, checksums, binary archives, and a plugin version check                                                                | `src/update/github.ts:8-9`, `src/integrations/constants.ts:12`                                                                                                                                                                                                   | none exposed; constructor options exist but no production call site passes them                                                                                                                                           |

`app.kimchi.dev/api` and `api.cast.ai` front the same `ai-optimizer` service
under different path conventions, which is why both serve
`/ai-optimizer/v1beta/*`. The Go helper's package is literally `pkg/cast` with
`DefaultEndpoint = "https://app.kimchi.dev/api"`
(`tools/proxy-helper/pkg/cast/cast.go:203`), and its symbols are
`github.com/castai/kimchi/tools/proxy-helper/pkg/cast.*`.

**`api.kimchi.dev` does not exist.** Zero occurrences in every source tree from
1.1.21 to 1.1.37 and zero in either binary. It appears only on one documentation
page, spelled with an unhyphenated `aioptimizer` service segment that appears in
no artifact of any version.

## 2. Capabilities

Columns are the same in every table. `Repoint` says exactly how the target is
changed: a config-file key, an environment variable, `region` where the only
choice is between the hosts of section 1 (section 4.10), or `source change`
where the target is a hard-coded constant. Every `https://` URL below is the
default US host. Rows whose `Endpoint` is `—` are real findings, not gaps; they
are explained in section 2.8.

### 2.1 Ordinary model access

| Capability                              | What the server does                                                    | What comes back                                   | Endpoint                                                                                                                                                                 | Repoint                                                                                                                                                                                                                                                                                                                                                                                                                       | If disabled                                                                                                                     |
| --------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Hosted inference — OpenAI wire          | Runs the model explicitly named in the request.                         | Generated response, tool-call requests or stream. | `POST https://llm.kimchi.dev/openai/v1/chat/completions` (`src/models.ts:31`, provider row `:252-260`)                                                                   | config `llmEndpoint`, else region                                                                                                                                                                                                                                                                                                                                                                                             | The agent loop has no model to call. Only a locally discovered or user-added provider row still answers.                        |
| Hosted inference — Anthropic wire       | Runs the named model, for catalog rows whose `provider` is `anthropic`. | Generated response, tool-call requests or stream. | `POST https://llm.kimchi.dev/anthropic/v1/messages?beta=true` (`src/models.ts:35`, selected at `:265-269`; the `?beta=true` suffix is the vendored SDK's, `B30:L272989`) | config `llmEndpoint`, else region                                                                                                                                                                                                                                                                                                                                                                                             | Anthropic-provider catalog rows become uncallable. OpenAI-wire rows are unaffected.                                             |
| Hosted inference — experimental pool    | Runs the named model on a separate pool.                                | Same as the ordinary wire.                        | `POST https://llm.kimchi.dev/experimental/openai/v1/chat/completions` (`src/regions.ts:96-98`, read at `src/models.ts:385` and `src/environment-models.ts:28`)           | region only — **not** `llmEndpoint`. A source change through 1.1.34                                                                                                                                                                                                                                                                                                                                                           | Models behind `--enable-experimental-features` disappear. Off by default.                                                       |
| Provider proxy                          | Relays the request to the selected external provider/model.             | That provider's response, relayed back.           | `—` (note a)                                                                                                                                                             | —                                                                                                                                                                                                                                                                                                                                                                                                                             | Nothing. It is not a separate call.                                                                                             |
| Model / provider catalog                | Lists available models, capabilities and limits.                        | Metadata; no generated answer.                    | `GET https://llm.kimchi.dev/v1/models/metadata?include_in_cli=true` (`src/models.ts:27-28`)                                                                              | config `llmEndpoint` on the startup path (`src/cli.ts:441-443,471-473`) and the browser/API-key login flow (`src/extensions/login/flow.ts:210`); **region only** for in-TUI login, `setup-tools`, the setup wizard and ACP, which pass no endpoint (`src/extensions/login/index.ts:37`, `src/commands/setup-tools.ts:96`, `src/commands/_helpers.ts:112`, `src/setup-wizard/steps/done.ts:20`, `src/modes/acp/server.ts:506`) | No Kimchi provider rows are written. One startup path reuses a cached `models.json`; the other registers nothing (section 4.5). |
| API-key validation — model-refresh path | Answers the catalog request, or refuses with 401.                       | The catalog body; a 401 means the key is bad.     | same as the row above (`src/models.ts:350-352`)                                                                                                                          | **region only** — the sole caller passes no endpoint (`src/extensions/login/index.ts:32`), so `src/models.ts:18-19` falls back to the region                                                                                                                                                                                                                                                                                  | In-TUI Kimchi login accepts any string as a key.                                                                                |
| Session auto-naming                     | Runs one small fixed model over the first turn's text.                  | A short session title.                            | `POST {llmEndpoint}/chat/completions` (`src/extensions/session-name.ts:136`, model `deepseek-v4-flash-0731` at `:19`, renamed from `deepseek-v4-flash` in 1.1.32)        | config `llmEndpoint`, consumed raw; else the region's `/openai/v1` base                                                                                                                                                                                                                                                                                                                                                       | Sessions keep a deterministic locally generated name. Failure is caught at `src/extensions/session-name.ts:172`.                |

Auth on every row: `Authorization: Bearer <KIMCHI_API_KEY>`, added by the
provider row's `authHeader: true` **in addition to** whatever the vendored SDK
sets natively, so the Anthropic path carries both a Bearer and an `X-Api-Key`.
Every row also sends `User-Agent: kimchi/<version>` and
`X-Provider-Type: <upstream>` (`src/models.ts:247-260`).

Since 1.1.34 the catalog can also carry backend-routed virtual models, any
`kimchi-dev` id starting with `auto`. They go out on the OpenAI wire row under
their virtual id, and the backend names the concrete model in the response
(`src/extensions/auto-model/constants.ts:26-38`). They are not a separate
endpoint.

Usage tags travel in the request **body** as `payload.tags`, gated on
`model.provider.startsWith("kimchi-dev")`. The documentation describes `X-Tags`
and `X-LiteLLM-Tags` request headers (`docs/model-apis-tags.md:43-56`); the CLI
sends neither.

### 2.2 Additional calls — when the feature is used

| Capability                | What the server does                                                         | What comes back                                         | Endpoint                                                                                                                                                                                                                                                                                                               | Repoint                                                                                                                        | If disabled                                                                                                                                                         |
| ------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Auto model recommendation | Ranks models for a prompt; the CLI then calls a selected model.              | Model IDs and scores; no answer yet.                    | `POST https://llm.kimchi.dev/v1/route` (`30: src/extensions/router/router-client.ts:44-53`; base `30: src/extensions/router/router-config.ts:9,17`)                                                                                                                                                                    | env `KIMCHI_ROUTER_ENDPOINT`                                                                                                   | Auto model selection stops. Explicitly named models still run. **Removed in 1.1.37** — section 4.3.                                                                 |
| `web_search`              | Handles a search query and its options. Underlying search engine is unknown. | Titles, URLs and snippets.                              | `POST https://llm.kimchi.dev/v1/search` (`src/regions.ts:101-103`, sole use `src/extensions/web-search/execute-handler.ts:63-65`)                                                                                                                                                                                      | region only — **not** `llmEndpoint`. A source change through 1.1.34                                                            | The `web_search` tool stops working. Nothing else changes.                                                                                                          |
| `web_fetch`               | Nothing. The CLI contacts the target site itself.                            | The page, converted to markdown locally.                | `—` (note b)                                                                                                                                                                                                                                                                                                           | not applicable                                                                                                                 | The `web_fetch` tool stops working.                                                                                                                                 |
| Memory — embeddings       | Embeds stored facts and recall queries with a fixed open-weight model.       | One vector per input.                                   | `POST {llmEndpoint}/embeddings` — the vendored mem0 library builds an OpenAI client with `baseURL: config.baseURL` and calls `embeddings.create` (`B36:L567839-567844`); that `baseURL` is `config.llmEndpoint` (`src/extensions/memory/embedder.ts:101-117`, `backend.ts:271-287`); model `bge-m3` at `backend.ts:24` | config `llmEndpoint`, consumed raw; else the region's `/openai/v1` base. `memoryEmbedding.model`/`.dims` change the model only | Recall and `memory_search` return nothing. Memory is opt-in and experimental, new in 1.1.33 — see below.                                                            |
| Memory — model check      | Lists the models the key may call.                                           | Model ids.                                              | `GET {llmEndpoint}/models` (`src/extensions/memory/backend.ts:100-116`), once per capture-worker start, skipped when `memoryExtraction.model` is set                                                                                                                                                                   | same                                                                                                                           | The worker assumes `deepseek-v4-flash-0731` is served.                                                                                                              |
| Memory — fact extraction  | Runs a fixed model over a slice of the conversation at temperature 0.        | A JSON list of durable facts.                           | `POST {llmEndpoint}/chat/completions` (`src/extensions/memory/capture-worker.ts:265-300`, body tagged `memory:extraction` at `:290`; model at `backend.ts:59`)                                                                                                                                                         | same                                                                                                                           | Nothing new is remembered. The session itself is unaffected; capture runs in a detached worker.                                                                     |
| Auto entitlement gate     | Looks up the authenticated user once at startup.                             | User ID and profile fields; the `email` domain decides. | `GET https://app.kimchi.dev/api/v1/me` (`30: src/extensions/router/auto-default-gate.ts:87` → `30: src/api/me.ts:33`; warmed at `30: src/cli.ts:340`)                                                                                                                                                                  | env `KIMCHI_REMOTE_ENDPOINT`                                                                                                   | The gate fails closed: Auto is not offered, not discoverable, and an explicit `--model kimchi-dev/auto` throws. New in 1.1.29, **removed in 1.1.37** — section 4.3. |

Through 1.1.36, `/v1/route` authenticated with `X-API-Key`, not a Bearer
(`30: src/extensions/router/router-client.ts:49`) — the only Kimchi endpoint
that did. Its body was `{query}` and nothing else; its timeout was 5 s and it
had no retry wrapper. Inbound `Authorization` and `X-API-Key` headers are both
dropped by an allowlist filter that admits only `X-Session-Id`,
`X-Conversation-Id`, `X-Turn-Index`, `X-Parent-Session-Id` and `traceparent`
(`src/extensions/telemetry/provider-headers.ts:3-9`).

`/v1/search` passes no `retry` option, so it inherits `DEFAULT_MAX_RETRIES = 10`
from `src/utils/http.ts:7`, and since 1.1.33 the retryable set includes the
Cloudflare origin failures 520–522 as well as 524 (`src/utils/http.ts:1-3`). Its
response is validated only for an object carrying an array `sources`
(`src/extensions/web-search/execute-handler.ts:92-96`); the server also returns
an `answer` field that the response type does not declare and the formatter
never reads, so it is discarded before the model sees it.

`web_fetch`'s SSRF guard is string and prefix matching with **no DNS
resolution** (`src/extensions/web-fetch/url-validator.ts:1-6`): scheme check,
localhost aliases, cloud metadata hosts, IPv4 private prefixes, `172.16/12`,
IPv6 loopback, `fc`/`fd`.

The three memory rows fire only after
`kimchi resources enable extensions.memory` or `KIMCHI_ENABLE_RESOURCES`: the
resource is marked experimental and `defaultEnabled: false`
(`src/resources/definitions.ts:124-132`), and was so from its first release.
Once enabled, what leaves the machine is the conversation itself. A detached
worker is spawned on compaction, at shutdown, and after every 10 new user
messages (`src/extensions/memory/capture.ts:24-31`, `index.ts:356`,
`config.ts:73`), and it sends user messages and up to 1,000 characters of each
assistant reply to the extraction model. The PII redactor runs on the extracted
facts before they are stored (`src/extensions/memory/capture-worker.ts:1093`),
not on the text sent for extraction. Facts and their vectors are stored locally
in SQLite; there is no remote memory store. `KIMCHI_MEMORY_CAPTURE=off` stops
capture but not recall (`src/extensions/memory/capture.ts:25,42-44,155`).

Every write goes in with `infer: false` (for instance
`src/extensions/memory/capture-worker.ts:1102`), so the vendored library's own
LLM client is configured but never called. While memory is enabled a second
process-wide `fetch` wrapper adds a `memory:embedding` tag to the body of
`/embeddings` requests whose origin matches `llmEndpoint`, and to nothing else
(`src/extensions/memory/backend.ts:133-150`).

### 2.3 Account, billing and reporting

| Capability                             | What the server does                                        | What comes back                                                          | Endpoint                                                                                                                                                                               | Repoint                                         | If disabled                                                                                      |
| -------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Authentication — browser login         | Validates credentials and access.                           | Access granted or denied; the key is handed back to a loopback callback. | `GET https://app.kimchi.dev/cli-auth?callback=<urlenc>&state=<32-byte hex>` (`src/cli-auth/index.ts:67`, base `:48`; browser navigation, note c)                                       | env `KIMCHI_WEB_APP_URL`, else region           | Browser login is unavailable. A key must come from `KIMCHI_API_KEY` or the config file.          |
| ↳ callback receiver                    | Nothing remote — a transient local server receives the key. | The API key, in a query parameter.                                       | `GET http://127.0.0.1:<ephemeral>/callback?token=…&state=…` (`src/cli-auth/callback-server.ts:5,135,155`)                                                                              | not applicable                                  | Browser login cannot complete.                                                                   |
| API-key validation — setup-wizard path | Validates the pasted key.                                   | The supported-provider list, or an error.                                | `GET https://api.cast.ai/v1/llm/openai/supported-providers` (`src/regions.ts:106-108`, read at `src/auth/validator.ts:41`; callers `src/setup-wizard/steps/auth.ts:44,111`)            | region only. A source change through 1.1.34     | The wizard cannot check a key before writing it.                                                 |
| Account identity                       | Looks up the authenticated user.                            | User ID and profile fields.                                              | `GET https://app.kimchi.dev/api/v1/me` (`src/api/me.ts:34,38-42`)                                                                                                                      | env `KIMCHI_REMOTE_ENDPOINT`, else region       | Telemetry events lose `userId` and `userEmail`. Through 1.1.36 the Auto gate also failed closed. |
| Credits status                         | Reports balance, tier and credit state.                     | Billing and allowance information.                                       | `GET https://llm.kimchi.dev/v1/credits` (built by `src/extensions/billing/status.ts:164-167`)                                                                                          | config `llmEndpoint`, derived; else region      | The status line and the `/budget` table show no spend figures. No request is gated either way.   |
| Budget status                          | Reports configured budgets and spend against them.          | Budget entries; a 404 means "no budget configured".                      | `GET https://llm.kimchi.dev/v1/budget` (same builder; 404 handling `src/extensions/billing/status.ts:223-226`)                                                                         | config `llmEndpoint`, derived; else region      | Same as credits.                                                                                 |
| Spend enforcement                      | Applies configured spending limits to requests.             | Requests proceed or are restricted.                                      | `—` (note d)                                                                                                                                                                           | —                                               | Nothing client-side exists to disable. Enforcement is the gateway's and is visible only in-band. |
| Usage analytics — analytics            | Aggregates usage, costs and productivity measurements.      | Reports and metrics.                                                     | `GET https://api.cast.ai/ai-optimizer/v1beta/analytics?startTime&endTime&inferUserFromApiKey=true` (`src/extensions/stats/api.ts:51-62`, base `:26`)                                   | region only. A source change through 1.1.34     | `kimchi stats` returns nothing.                                                                  |
| Usage analytics — productivity         | Aggregates the same data per metric.                        | Metric series.                                                           | `GET https://api.cast.ai/ai-optimizer/v1beta/productivity-metrics?from&to&inferUserFromApiKey=true[&provider_name][&metric_names][&session_id]` (`src/extensions/stats/api.ts:67-103`) | region only                                     | `kimchi stats` returns nothing.                                                                  |
| Usage analytics — timeseries           | Declared by the client; never invoked.                      | Time series.                                                             | `GET https://api.cast.ai/ai-optimizer/v1beta/productivity-metrics:generateTimeseries?…` (`src/extensions/stats/api.ts:106-139`, note e)                                                | region only                                     | Nothing. No caller exists at any version.                                                        |
| Compute quota usage                    | Reports workspace allowances and usage.                     | Limits and usage information.                                            | `GET https://app.kimchi.dev/api/ai-optimizer/v1beta/organizations/{orgId}/quotas:usage` (`src/sandbox/cloud/quota.ts:27`)                                                              | env `KIMCHI_REMOTE_ENDPOINT`, else region       | The workspace picker shows no quota figures. This is compute quota, not spend.                   |
| Telemetry — logs                       | Receives client-generated events and logs.                  | Acknowledgement; no model answer.                                        | `POST https://api.cast.ai/ai-optimizer/v1beta/logs:ingest` (`src/extensions/telemetry/transport.ts:97-131`, default `src/config.ts:520` from `src/regions.ts:110-112`)                 | config `telemetry.endpoint`, else region        | No usage events leave the machine. No functional loss.                                           |
| Telemetry — metrics                    | Receives client-generated metrics.                          | Acknowledgement; no model answer.                                        | `POST https://api.cast.ai/ai-optimizer/v1beta/metrics:ingest` (`src/extensions/telemetry/transport.ts:149-201`, default `src/config.ts:521` from `src/regions.ts:114-116`)             | config `telemetry.metricsEndpoint`, else region | Same as logs.                                                                                    |

The credential is a Cast AI platform key — the login helper's own return
annotation names the shape, `castai_v1_…` (`src/cli-auth/index.ts:39`), and the
redactor pattern `/castai_v1_[A-Za-z0-9_-]{8,}/g`
(`src/extensions/pii-redaction/redactor.ts:68`) matches it. The same credential
authenticates `llm.kimchi.dev`, `app.kimchi.dev/api` and `api.cast.ai`. The
client treats a key as valid in one region only: switching region at login
discards the saved key and forces a fresh one
(`src/extensions/login/flow.ts:376-378`).

Browser login issues **zero** CLI-originated HTTP requests: browser → loopback
callback → write key. Validation is skipped deliberately, with the reason stated
in place — the token was just created by the backend, and a separate validation
round trip may hit a different environment
(`src/setup-wizard/steps/auth.ts:78-80`).

Unlike every other first-party call, the two billing endpoints use raw `fetch`
with a 5 s `AbortSignal.timeout` and no retry; any throw or non-`ok` response
returns `undefined` (`src/extensions/billing/status.ts:177-187,213-227`).

`telemetry.headers` in the config file replaces the derived
`Authorization: Bearer` outright (`src/config.ts:495-502`), which is the only
way to send telemetry somewhere with different auth.

### 2.4 Remote execution

Three planes, three base URLs, two credentials. The handshake order is stated in
`src/sandbox/cloud/auth.ts:46-51` and pinned call-by-call at
`auth.test.ts:83-104`: verify key → upsert workspace → resume → exchange token.
A read-only ownership probe runs verify → get → exchange, with no upsert and no
resume (`src/sandbox/cloud/auth.ts:133-141`).

**Control plane**, base `https://app.kimchi.dev/api`
(`src/sandbox/cloud/http.ts:5-8`: `KIMCHI_REMOTE_ENDPOINT`, else the region).
All calls carry `Authorization: Bearer <KIMCHI_API_KEY>` and a 30 s default
timeout.

| Capability                                     | What the server does                                                 | What comes back                                                                                                                                     | Endpoint                                                                                                                                                                                                                                                                           | Repoint                                   | If disabled                                                               |
| ---------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------- |
| Workspace authentication — org lookup          | Authorizes the key and names the org it belongs to.                  | `{organizationId}`, and a `userID` the client never reads.                                                                                          | `POST {control}/ai-optimizer/v1beta/workspace-tokens:verifyKey` (`src/sandbox/cloud/keys.ts:9`; no body at all, `:10-20`)                                                                                                                                                          | env `KIMCHI_REMOTE_ENDPOINT`, else region | All remote execution stops at the first step.                             |
| Workspace authentication — token mint          | Issues a connection token scoped to one workspace.                   | `{token, expireTime?}`.                                                                                                                             | `POST {control}/ai-optimizer/v1beta/workspace-tokens:exchange` (`src/sandbox/cloud/auth.ts:236`, body `{workspaceId}` at `:245`)                                                                                                                                                   | env `KIMCHI_REMOTE_ENDPOINT`, else region | The worker plane, both WebSockets and the ssh tunnel are all unreachable. |
| Workspace lifecycle — list                     | Lists workspaces for the org.                                        | Workspace IDs, resources and status.                                                                                                                | `GET {control}/ai-optimizer/v1beta/organizations/{org}/workspaces?page.limit=200&clientType=harness[&page.cursor=…]` (`src/sandbox/cloud/workspaces.ts:27-32`, 10-page cap at `:9-10`)                                                                                             | env `KIMCHI_REMOTE_ENDPOINT`, else region | The remote-session picker is empty.                                       |
| Workspace lifecycle — get                      | Returns one workspace record.                                        | Status, resources, and the worker `uri`.                                                                                                            | `GET {control}/ai-optimizer/v1beta/organizations/{org}/workspaces/{id}` (`src/sandbox/cloud/auth.ts:152`)                                                                                                                                                                          | env `KIMCHI_REMOTE_ENDPOINT`, else region | Ownership probes fail.                                                    |
| Workspace lifecycle — create / update / rename | Creates or updates a workspace, idempotently.                        | The full workspace record, including `uri`; since 1.1.34 its sizes are read from `spec.resources` only (`src/sandbox/cloud/workspaces.ts:144-157`). | `PUT {control}/ai-optimizer/v1beta/organizations/{org}/workspaces/{id}` (`src/sandbox/cloud/auth.ts:188-212`; since 1.1.34 a create carries `spec: {resources, dependencies, egressPolicy}` from `kimchi_workspace.yaml` at `:203-208`, replacing the top-level `resources` field) | env `KIMCHI_REMOTE_ENDPOINT`, else region | No new workspaces can be created.                                         |
| Workspace lifecycle — delete                   | Deletes a workspace.                                                 | Nothing.                                                                                                                                            | `DELETE {control}/ai-optimizer/v1beta/organizations/{org}/workspaces/{id}` (`src/sandbox/cloud/workspaces.ts:97`)                                                                                                                                                                  | env `KIMCHI_REMOTE_ENDPOINT`, else region | Workspaces can only be removed elsewhere.                                 |
| Workspace lifecycle — resume                   | Wakes a hibernated workspace by scaling its pod back to one replica. | Nothing the client reads on success.                                                                                                                | `POST {control}/ai-optimizer/v1beta/organizations/{org}/workspaces/{id}:resume` (`src/sandbox/cloud/auth.ts:92`, body `{}` at `:101`)                                                                                                                                              | env `KIMCHI_REMOTE_ENDPOINT`, else region | Connecting to a hibernated workspace fails; see section 4.4.              |
| Workspace quotas                               | Reports workspace allowances and usage.                              | Limits and usage information.                                                                                                                       | `GET {control}/ai-optimizer/v1beta/organizations/{org}/quotas:usage` (`src/sandbox/cloud/quota.ts:27`)                                                                                                                                                                             | env `KIMCHI_REMOTE_ENDPOINT`, else region | The picker shows no quota figures. Presentational only.                   |

**Workspace worker**, base `https://<workspace-host>`, derived from the control
plane's `uri` by rewriting `wss://` to `https://`
(`src/sandbox/worker/client.ts:169-181`; anything that is not a `ws`, `wss`,
`http` or `https` scheme throws). Auth: `Authorization: Bearer <connectToken>`.

| Capability                      | What the server does                                                                       | What comes back                           | Endpoint                                                                                                                                                                                                                                                                  | Repoint                     | If disabled                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------- |
| Workspace readiness             | Reports whether the workspace gateway has attached and traffic is routable.                | 2xx or not; no body.                      | `GET {worker}/api/startupcompletedz` (`src/sandbox/cloud/readiness.ts:51`; semantics `:89-91`; 1.5 s poll, 10-minute budget `:10-12`)                                                                                                                                     | none — server-assigned host | Every remote connection times out at the readiness gate.                                |
| Session management — list       | Lists sessions in the workspace.                                                           | A map keyed by session name.              | `GET {worker}/api/session?clientType=harness` (`src/sandbox/worker/sessions.ts:5-9`)                                                                                                                                                                                      | none                        | The session picker is empty.                                                            |
| Session management — get        | Returns one session.                                                                       | Session status; 404 means it is gone.     | `GET {worker}/api/session/{name}` (`src/sandbox/worker/sessions.ts:11-14`)                                                                                                                                                                                                | none                        | Reattach cannot verify a session.                                                       |
| Session management — create     | Creates a session, optionally cloning a repository and accepting an uploaded history file. | 201 and the session record.               | `POST (multipart) {worker}/api/session/{name}` (`src/sandbox/worker/sessions.ts:16-29` → `client.ts:113-118`); since 1.1.32 a cloud subagent's session also carries `tags.parent_session_id`, the local session id (`src/extensions/agents/manager/agent-manager.ts:463`) | none                        | No remote session can start. This is the only genuine HTTP upload in the whole surface. |
| Session management — delete     | Deletes a session.                                                                         | Nothing.                                  | `DELETE {worker}/api/session/{name}` (`src/sandbox/worker/sessions.ts:31-33`)                                                                                                                                                                                             | none                        | Sessions accumulate.                                                                    |
| Git identity — global           | Sets the workspace's git user.                                                             | Nothing.                                  | `PUT {worker}/api/gitidentity` (`src/sandbox/worker/git-identity.ts:18`, body `{user:{name?,email?}}`)                                                                                                                                                                    | none                        | Remote commits carry no identity.                                                       |
| Git identity — per host, create | Registers a git identity for one host.                                                     | The identity; 409 when it already exists. | `POST {worker}/api/gitidentity/{host}` (`src/sandbox/worker/git-identity.ts:35`, 409 retried as PUT at `:61-68`)                                                                                                                                                          | none                        | Remote git against that host is unauthenticated.                                        |
| Git identity — per host, update | Updates an existing per-host identity.                                                     | The identity.                             | `PUT {worker}/api/gitidentity/{host}` (`src/sandbox/worker/git-identity.ts:44`)                                                                                                                                                                                           | none                        | Same.                                                                                   |
| Secret provisioning             | Stores a named secret for the workspace.                                                   | Nothing.                                  | `PUT {worker}/api/secrets` (`src/sandbox/worker/secrets.ts:15-24`; value is base64-encoded, not encrypted, `:19`)                                                                                                                                                         | none                        | The worker's credential helper has no token to serve to git.                            |

**Streams and transfer.**

| Capability                  | What the server does                                                    | What comes back                                           | Endpoint                                                                                                                                                              | Repoint                                                                                                                                                                                                                     | If disabled                                                                      |
| --------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Remote agents / cloud tasks | Runs the agent harness, tools and subsequent model requests remotely.   | Progress, task results and file changes.                  | `wss://<workspace-host>/session/{name}/connect`, ACP JSON-RPC framing (`src/sandbox/worker/acp-client.ts:462-466`)                                                    | none                                                                                                                                                                                                                        | `/remote-run` and the `dispatch_to_cloud_agent` tool stop working.               |
| `/teleport`                 | Starts a remote terminal/agent session using transferred local context. | An interactive, persistent remote terminal.               | same URL, raw-byte PTY framing (`src/extensions/teleport/overlay/tab-manager.ts:117`)                                                                                 | none                                                                                                                                                                                                                        | `/teleport` and `/terminal` stop working.                                        |
| SSH / rsync tunnel          | Splices raw bytes for an ssh `ProxyCommand`.                            | The ssh stream.                                           | `wss://<workspace-host>:443/ssh` (`tools/proxy-helper/cmd/proxy/proxy.go:50`; port flag defaults to 443 at `:209` and the CLI never passes it, `src/ssh-proxy.ts:68`) | none for the host; env `KIMCHI_PROXY_HELPER` repoints the helper binary, not the target. The helper's own control-plane handshake reads `KIMCHI_REMOTE_ENDPOINT` and otherwise the US host, never the region — section 4.10 | File sync and `/terminal` stop working.                                          |
| Project transfer            | Receives files or clones a repository; supports transfers back.         | Remote working tree or downloaded files.                  | `—` (note f)                                                                                                                                                          | —                                                                                                                                                                                                                           | File sync stops; remote sessions can still clone server-side.                    |
| Server-side clone           | The workspace clones the repository itself.                             | A populated remote working tree.                          | `—` (note f) — `details.git` on the session-create body (`src/sandbox/worker/types.ts:15-21`)                                                                         | —                                                                                                                                                                                                                           | Every remote session must be populated by rsync instead.                         |
| Harness config sync         | Nothing remote — rsync copies a fixed allowlist.                        | A populated `~/.config/kimchi/harness/` in the workspace. | `—` (note f)                                                                                                                                                          | —                                                                                                                                                                                                                           | Remote sessions start with default settings, keybindings, themes and model list. |

Secrets are named `git-token-${host.replace(/[^A-Za-z0-9_-]/g,"_")}`
(`src/extensions/teleport/provisioning/git-provision.ts:31-33`) and written
before the identity, so the first git operation never races a missing secret.
The worker's credential helper serves the token to git on demand; the token is
never sent over the ssh channel.

The wire difference between `/teleport` and remote-run is exactly three fields:
the session-create body is `{agentMode:"PTY", cwd:<sessionCwd>}` versus
`{agentMode:"ACP", yolo:true}` with no `cwd`; `details.git.targetDirectory` is
the repository basename versus `""`; and the WebSocket payload is raw bytes
versus ACP JSON-RPC. `/teleport` additionally uploads local session history as
the `sessionFile` multipart part.

### 2.5 Self-hosted model infrastructure

| Capability                           | What the server does                                                     | What comes back                                                                    | Endpoint                                                                                                                                                                                                        | Repoint              | If disabled                                                |
| ------------------------------------ | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ---------------------------------------------------------- |
| Model deployment                     | Runs models on your Kubernetes infrastructure.                           | A callable model endpoint.                                                         | `—` (note g) — no endpoint is documented and none exists in any tree or binary                                                                                                                                  | —                    | Nothing in the CLI. It has no client for this.             |
| Autoscaling / hibernation            | Adjusts replicas and sleeps or wakes model deployments.                  | Available capacity and lifecycle events.                                           | `—` (note g) — console UI only                                                                                                                                                                                  | —                    | Nothing in the CLI.                                        |
| Configured fallback                  | Sends requests to a configured fallback when the primary is unavailable. | An answer from the fallback model.                                                 | `—` (note h) — a `params.fallbacks` field plus an `anthropic-beta: server-side-fallback-2026-07-01` header on the Anthropic wire row of section 2.1                                                             | —                    | Not separately disableable; the decision is the gateway's. |
| Hosted-model catalogue for a cluster | Lists the models deployed on one cluster.                                | A model list.                                                                      | `GET {host unresolved}/ai-optimizer/v1beta/organizations/{organizationId}/clusters/{clusterId}/hosted-models` — documented only (`docs/hosted-model-deployments.md:97`), zero occurrences in any tree or binary | —                    | Nothing in the CLI.                                        |
| In-cluster inference proxy           | Serves inference inside the cluster.                                     | Generated response.                                                                | `POST http://castai-ai-optimizer-proxy.castai-agent.svc.cluster.local:443/openai/v1/chat/completions` — documented only (`docs/hosted-model-deployments.md:107,113`)                                            | —                    | Nothing in the CLI.                                        |
| What the CLI actually sees           | Lists available models, capabilities and limits.                         | `is_serverless` is the only signal, and it does not mark a self-hosted deployment. | the catalog `GET` of section 2.1                                                                                                                                                                                | config `llmEndpoint` | Covered in section 2.1.                                    |

There is no client code for the hosted-model surface at any version. Zero hits
across the 1.1.21, 1.1.27, 1.1.30 and 1.1.37 trees for `hosted-model`,
`hostedModel`, `clusterId`, `scaleToZero`, `aioptimizer` or
`castai-ai-optimizer-proxy`.

The documentation asserts at `docs/hosted-autoscaling.md:23` that "All scaling
configuration is also available programmatically through the Kimchi API" and
links to a page whose only HTTP block is the catalogue `GET` above. **That
assertion is a broken cross-reference; the mutation endpoints are not documented
anywhere and must not be constructed by inference.**

The documented in-cluster proxy carries two conflicting auth headers for the
same call across two pages — `X-API-Key` on one, `Authorization: Bearer` on the
other.

`is_serverless` does not distinguish hosted from local. Kimchi hard-codes it
`true` in both places it manufactures metadata locally — for discovered local
models (`src/ollama.ts:443`) and when reconstructing from a cached `models.json`
(`src/models.ts:297`), so the real value is lost on every cache round trip. It
also steers model selection, not just display order: `resolveModelRole`
(`src/integrations/models.ts:125-179`) resolves the `main`/`coding`/`sub` roles
exclusively from serverless models.

### 2.6 Local and loopback surfaces

Listed because several read as remote paths in a raw index, and because they are
the only surfaces that are reachable without leaving the machine. The login
callback receiver of section 2.3 also binds loopback.

| Capability                       | What the server does                                    | What comes back                    | Endpoint                                                                                                                                                                                                   | Repoint                                                                                              | If disabled                                                                                                                        |
| -------------------------------- | ------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Local model discovery — list     | Lists locally installed models.                         | Model names and tags.              | `GET {ollamaHost}/api/tags` (`src/ollama.ts:247`, 2 s timeout, no auth)                                                                                                                                    | env `OLLAMA_HOST`, else `KIMCHI_OLLAMA_HOST`, else `http://localhost:11434` (`src/ollama.ts:19,125`) | No locally discovered models are registered. Failure is already silent by design.                                                  |
| Local model discovery — probe    | Returns one model's context length and capabilities.    | A metadata blob.                   | `POST {ollamaHost}/api/show` (`src/ollama.ts:193`, body `{name}`, concurrency 4 at `:25`)                                                                                                                  | same                                                                                                 | Discovered models fall back to the tag entry's defaults.                                                                           |
| Local inference                  | Runs the named local model.                             | Generated response or stream.      | `POST {ollamaHost}/v1/chat/completions` (provider row `src/ollama.ts:398-400`)                                                                                                                             | same                                                                                                 | Local models become uncallable. No Kimchi credential is attached to this row; its `apiKey` is the sentinel `ollama-no-key-needed`. |
| Local llama.cpp router mode      | Loads, unloads and lists models on a local server.      | Model state.                       | `GET/POST http://127.0.0.1:8080/{models,models?reload=1,models/load,models/unload,models/sse,props}` (`B30:L441346`, default base `B30:L441739`)                                                           | upstream harness setting                                                                             | Router mode is unavailable. This belongs to the upstream harness, not to Kimchi.                                                   |
| Provider OAuth callback receiver | Nothing remote — receives a provider's OAuth redirect.  | An authorization code.             | `GET http://localhost:<ephemeral>/auth/callback` (`B30:L625221`)                                                                                                                                           | not applicable                                                                                       | Provider OAuth logins cannot complete.                                                                                             |
| MCP-App host server              | Serves the app bridge and resources to a local MCP app. | SSE events, static assets.         | `/events`, `/health`, `/app-bridge.bundle.js`, `/resource/…`, `/sandbox`, `/favicon.ico` on `127.0.0.1` (`B30:L523857-524606`)                                                                             | not applicable                                                                                       | MCP apps do not render.                                                                                                            |
| MCP-App proxy server             | Relays tool calls and UI intents from an MCP app.       | Tool results, UI acknowledgements. | `POST /proxy/tools/call` and `POST /proxy/ui/{consent,context,message,open-link,download-file,request-display-mode,generated-tool-call-intent,heartbeat,complete}` on `127.0.0.1:0` (`B30:L523543-524460`) | not applicable                                                                                       | MCP apps cannot call tools.                                                                                                        |
| Local MCP WebSocket              | Carries MCP traffic to a locally launched server.       | MCP messages.                      | `ws://127.0.0.1:<lockfile.port>/mcp` (`B30:L623297`)                                                                                                                                                       | lockfile-assigned                                                                                    | That MCP server is unreachable.                                                                                                    |
| Fixed-port local probe           | Answers a liveness probe.                               | A TCP accept.                      | `127.0.0.1:24543` (`B30:L524848`)                                                                                                                                                                          | not applicable                                                                                       | The probe reports unavailable.                                                                                                     |

Both MCP-App servers validate a per-session token on every route and answer any
non-POST with 404.

Locally discovered models join the `builder`, `reviewer` and `explorer` role
pools and deliberately not `orchestrator`, `planner`, `judge` or `researcher`
(`src/ollama.ts:463-492`).

There is no telemetry endpoint for the device-identity module.
`src/posthog-device.ts` only mints and persists a device UUID; no ingest host
appears in it.

### 2.7 Distribution and self-update

| Capability            | What the server does                                  | What comes back                                  | Endpoint                                                                                                                    | Repoint                                                                                                  | If disabled                                                                  |
| --------------------- | ----------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Latest release lookup | Returns the newest release.                           | Tag and URL.                                     | `GET https://api.github.com/repos/getkimchi/kimchi/releases/latest` (`src/update/github.ts:8,41,89`)                        | source change — constructor options exist but no call site passes them (`src/update/workflow.ts:80,205`) | `kimchi update` cannot find a new version. A packaged install is unaffected. |
| Release by tag        | Returns one release.                                  | Tag and URL.                                     | `GET https://api.github.com/repos/getkimchi/kimchi/releases/tags/{tag}` (`src/update/github.ts:110`)                        | source change                                                                                            | Pinned-version updates fail.                                                 |
| Canary release        | Returns the canary release.                           | Tag and URL.                                     | `GET https://api.github.com/repos/getkimchi/kimchi/releases/tags/canary` (`src/update/github.ts:134`)                       | source change                                                                                            | Canary updates fail.                                                         |
| Checksums             | Serves the release checksum file.                     | `checksums.txt`.                                 | `GET https://github.com/getkimchi/kimchi/releases/download/{tag}/checksums.txt` (`src/update/github.ts:169`)                | source change                                                                                            | Updates abort before download.                                               |
| Binary archive        | Serves the release archive.                           | `kimchi_{os}_{arch}.tar.gz` (`.zip` on Windows). | `GET https://github.com/getkimchi/kimchi/releases/download/{tag}/{asset}` (`src/update/github.ts:191`, name built at `:69`) | source change                                                                                            | Self-update cannot install.                                                  |
| Plugin version check  | Reports the published version of the opencode plugin. | Registry metadata.                               | `GET https://registry.npmjs.org/…` (`src/integrations/constants.ts:12`)                                                     | source change                                                                                            | The plugin version check is skipped.                                         |

Homebrew installations are detected and self-update is refused.

### 2.8 Notes on the rows with no endpoint

Each of these is a finding, not a missing cell.

**(a) Provider proxy.** There is no relay endpoint. The choice of upstream
provider is made at catalog ingest, not at request time: the base-path family
picks the wire protocol (`src/models.ts:265-269`), the catalog `slug` goes on
the wire verbatim as `model`, and `X-Provider-Type: <upstream>`
(`src/models.ts:249`) is attribution rather than routing. The
`kimchi-dev/<provider>` identifiers are local map keys.

**(b) `web_fetch`.** The CLI fetches the target origin itself, either through a
local Playwright browser (`src/extensions/web-fetch/page-fetcher.ts:125-128`) or
native `fetch` with one `Accept` header and no `Authorization` (`:267-278`).
HTML-to-markdown conversion is local. Nothing is sent to a Kimchi host. Note
that the global fetch patch of section 4.2 still stamps a user-agent on these
requests.

**(c) Browser login.** The `/cli-auth` URL is opened in a browser; the CLI
issues no HTTP request of its own. The URL is assembled from a template literal,
so a quoted-string search of the binary does not find it.

**(d) Spend enforcement.** No endpoint gates, blocks or pre-flights a request.
Every consumer of the billing snapshot outside
`src/extensions/billing/status.ts` is presentational, and the list is short and
checkable: `src/extensions/ui.ts:407`, `src/extensions/tips/index.ts:152`,
`src/extensions/billing/tips.ts:11`, `src/components/status-line.ts`,
`src/extensions/billing/command.ts`. Enforcement happens at the gateway and is
observable in-band; see section 4.8.

**(e) Timeseries.** The method is declared on the stats client and has zero
callers at every version — `handleStatsCommand` invokes only `generateAnalytics`
(`src/extensions/stats/index.ts:79`) and `getProductivityMetrics` (`:97`). The
server route is probably live: `src/extensions/stats/types.ts:1-4` says the
types are based on actual API responses, and the request type is a transcription
of a server message the client never sends.

**(f) Project transfer, server-side clone, harness config sync.** There is no
`/v1/files`, no `/v1/artifacts` and no upload endpoint on either Kimchi plane.
Transfer is `rsync -az --progress --stats --partial` over real `ssh` with
`ProxyCommand kimchi --ssh-proxy %h`
(`src/extensions/teleport/provisioning/proxy-command.ts:19-27`), remote spec
`sandbox@<host>:<path>`. Default rsync excludes cover `.env`, `.env.*`, `.envrc`
and `.kimchi/`. Server-side clone is a field on the session-create body, not a
call. Harness config sync rsyncs `~/.config/kimchi/harness/` with a hard
allowlist: `settings.json`, `keybindings.json`, `themes/`, `models.json`.

**(g) Model deployment and autoscaling.** Resolved as absence in both the CLI
and the documentation. See section 2.5.

**(h) Configured fallback.** `upstream.compat` is copied wholesale from the
vendored catalogue rather than field-picked (`src/models.ts:213-215,230`, pinned
by `models.test.ts:200-205`), so `params.fallbacks` and the server-side-fallback
beta header do ship — to `https://llm.kimchi.dev/anthropic`, where the decision
is made. No client retry path ever switches models; both retry stacks re-issue
the identical request.

## 3. Repoint mechanisms

Surfaces whose target is settable without touching code:

| Surface                                                                                                                                        | Mechanism                     | Key or variable                                                                                                               | Implementation                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Every first-party host except the workspace worker                                                                                             | environment, then config file | `KIMCHI_REGION` (`us` or `eu`), else `region` in the **global** `~/.config/kimchi/config.json`; unknown values count as unset | `src/config.ts:450-454`, `:589`; hosts at `src/regions.ts:23-38`. New in 1.1.35 — section 4.10                                                                                 |
| Inference, startup and login-flow catalog, credits, budget, session naming, memory (section 2.1 lists the catalog refreshes it does not reach) | config file, over the region  | `llmEndpoint` in `~/.config/kimchi/config.json`, or a trusted project `.kimchi/config.json`                                   | `src/config.ts:570-595`; normalized at `src/models.ts:18-25`; billing derives its base at `src/extensions/billing/status.ts:164-167`                                           |
| Auto model router (through 1.1.36)                                                                                                             | environment                   | `KIMCHI_ROUTER_ENDPOINT`                                                                                                      | `30: src/extensions/router/router-config.ts:9,17`. **Removed in 1.1.37**: nothing reads the variable any more — section 4.3                                                    |
| Remote control plane and account identity                                                                                                      | environment, over the region  | `KIMCHI_REMOTE_ENDPOINT` — the whole base including `/api`                                                                    | `src/config.ts:660`, consumed at `src/sandbox/cloud/http.ts:5-8` and `src/api/me.ts:20-24`; the Go helper reads it on its own at `tools/proxy-helper/pkg/cast/cast.go:213-218` |
| Browser login page                                                                                                                             | environment, over the region  | `KIMCHI_WEB_APP_URL`                                                                                                          | `src/config.ts:659`, used at `src/cli-auth/index.ts:48,67`                                                                                                                     |
| Telemetry logs ingest                                                                                                                          | config file, over the region  | `telemetry.endpoint`                                                                                                          | `src/config.ts:473-523`, default `:520`                                                                                                                                        |
| Telemetry metrics ingest                                                                                                                       | config file, over the region  | `telemetry.metricsEndpoint`                                                                                                   | `src/config.ts:473-523`, default `:521`                                                                                                                                        |
| Telemetry auth header                                                                                                                          | config file                   | `telemetry.headers` — replaces the derived Bearer outright                                                                    | `src/config.ts:495-502`                                                                                                                                                        |
| Local model host                                                                                                                               | environment                   | `OLLAMA_HOST`, else `KIMCHI_OLLAMA_HOST`                                                                                      | `src/ollama.ts:19,125`                                                                                                                                                         |
| Proxy-helper binary (not its target)                                                                                                           | environment                   | `KIMCHI_PROXY_HELPER`                                                                                                         | `src/ssh-proxy.ts`                                                                                                                                                             |
| Bun fetch HTTP traffic, as an ordinary forward proxy                                                                                           | environment                   | `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`                                                                                     | `KIMCHI_PROXY` / `KIMCHI_NO_PROXY` are inert under Bun and apply only to Node-hosted runs (`1.5.0 src/http/proxy.ts:25-35`). Unrelated to model routing                        |

Surfaces that follow the region but cannot be sent to an arbitrary host without
a source change, with the size of the change:

| Surface                            | What to change                                                               | Size                                                                                                                                                                                                                                                                            |
| ---------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `web_search`                       | `searchUrl` at `src/regions.ts:101-103`                                      | **one line.** One use, at `src/extensions/web-search/execute-handler.ts:64`. The module reads no environment variable and no config key other than `loadConfig().apiKey` (`:100`)                                                                                               |
| Experimental inference pool        | `experimentalOpenAiBaseUrl` at `src/regions.ts:96-98`                        | one line. Through 1.1.34 it was two literals that had to agree                                                                                                                                                                                                                  |
| Setup-wizard key validation        | `keyValidationUrl` at `src/regions.ts:106-108`                               | one line. The validator function already accepts an `endpoint?` option (`src/auth/validator.ts:13`); both callers pass none (`src/setup-wizard/steps/auth.ts:44,111`)                                                                                                           |
| Usage analytics — all three routes | `castApiUrl` in `REGIONS` (`src/regions.ts:29,36`)                           | one line per region. The client constructor already accepts `baseUrl?` (`src/extensions/stats/api.ts:17,26`); the single construction site passes only the key (`src/extensions/stats/index.ts:16-22`), and the exported `createStatsClient` (`api.ts:145-147`) is never called |
| A third region                     | one entry in `REGIONS` (`src/regions.ts:23-38`)                              | one object literal. Region ids come from its keys, so validation, the picker and `kimchi config region` pick it up                                                                                                                                                              |
| Release lookup, checksums, archive | `DEFAULT_API_BASE` and `DEFAULT_DOWNLOAD_BASE` at `src/update/github.ts:8-9` | two lines, and not region-aware. The client accepts `apiBase`/`downloadBase` options; neither call site passes them (`src/update/workflow.ts:80,205`)                                                                                                                           |
| Plugin version check               | `NPM_REGISTRY_BASE_URL` at `src/integrations/constants.ts:12`                | one line, not region-aware                                                                                                                                                                                                                                                      |

Two things that are **not** repoint mechanisms:

- Hand-editing a Kimchi provider's `baseUrl` in `models.json`.
  `readExistingProviders` (`src/models.ts:331-348`) drops and regenerates every
  `kimchi-dev*` and `kimchi-experimental` row on each refresh, preserving only
  user-added providers. The edit is erased on the next successful catalog fetch.
- `KIMCHI_LLM_ENDPOINT`. Nothing reads it. Through 1.1.34 it was the name of a
  module constant (`30: src/config.ts:11`), never an environment variable, and
  1.1.35 removed even that. Exporting it accomplishes nothing.

## 4. Behavior that is not visible from the endpoint list

These determine whether a call fires at all.

### 4.1 Remote execution inverted from opt-in to opt-out in 1.1.22

At 1.1.21 the extension did not even register without the variable set, and the
runner tested for its mere presence:

```ts
// 21: src/extensions/remote-run/index.ts:15
if (!process.env.KIMCHI_REMOTE_RUN) return;
// 21: src/extensions/remote-run/runner.ts:23
return !!process.env.KIMCHI_REMOTE_RUN;
```

From 1.1.22 onward the polarity is reversed:

```ts
// src/extensions/remote-run/runner.ts:24,35-39
const DISABLE_VALUES = new Set(["0", "false"]);
export function isRemoteRunEnabled(): boolean {
  if (isInSandboxCluster() || isWindows()) return false;
  const value = process.env.KIMCHI_REMOTE_RUN?.trim().toLowerCase();
  if (value === undefined || value === "") return true;
  return !DISABLE_VALUES.has(value);
}
```

Unset now means **enabled**. Only `"0"` and `"false"` disable it,
case-insensitively after trimming. The legacy opt-in values `1` and `true` are
still read as enabled, so a pre-existing opt-in setting keeps working and hides
the change. Everything in section 2.4 is reachable by default from 1.1.22.

Since 1.1.23 the model can reach it too:
`src/extensions/remote-run/dispatch-tool.ts:27` registers a model-callable
`dispatch_to_cloud_agent` tool, registered whenever remote run is enabled and
the session is not headless (`index.ts:30-42`). The module states its own threat
model — an in-tool consent dialog exists so that model initiative, including
indirect prompt injection, cannot launch remote compute on its own, and the tool
is suppressed under `--print` because a headless session has no human to answer.

### 4.2 The global fetch patch fires on any host, and stamps every request

`installGlobalFetchInstrumentation` replaces `globalThis.fetch` process-wide.
Two behaviors follow from it.

```ts
// src/http/instrument-fetch.ts:85-87
function isModelCompletionFetch(input: RequestInfo | URL): boolean {
  return /\/chat\/completions(?:$|[?#])/.test(requestUrl(input) ?? "");
}
```

The match is on the **path of any URL**, and the only other gate is
`response.ok` (`:77`). The hook attached at `src/cli.ts:639-643` is a billing
refresh, which fires `GET /v1/credits` and `GET /v1/budget` against
`llm.kimchi.dev` — so a completion served by a different provider entirely,
including a locally hosted one, still produces two Kimchi billing GETs.

The same patch sets `user-agent: kimchi/<version>` on **every outbound request
in the process** that does not already carry one (`:72-73`). That includes MCP
HTTP transports and `web_fetch`.

### 4.3 Auto: a client router gated to `@cast.ai` (1.1.29–1.1.36), then a backend-routed model

Everything down to the 1.1.37 paragraph describes code that no longer exists,
and its citations carry the `30:` prefix.

`30: src/extensions/router/auto-default-gate.ts` is absent from the 1.1.21,
1.1.25, 1.1.26 and 1.1.27 trees and present from 1.1.29 through 1.1.36 (checked
by `ls` in each). It calls `getMe` (`:87`) and compares the domain after the
last `@` for exact equality (`:66-71`), so `user@sub.cast.ai` does not match and
neither does `user@notcast.ai`.

It gates four things, not just the default:

| Consumer                                                      | Effect when the gate says no                  |
| ------------------------------------------------------------- | --------------------------------------------- |
| `30: src/extensions/router/model-discovery.ts:10`             | Auto is not discoverable as a model           |
| `30: src/extensions/orchestration/model-roles-command.ts:350` | Auto is absent from the model-roles command   |
| `30: src/cli.ts:574`                                          | an explicit `--model kimchi-dev/auto` throws  |
| `30: src/extensions/router/index.ts:101`                      | Auto is never resolved as the session default |

`isExperimentalFeaturesEnabled()` is an alternative satisfier for the first two
but not for the other two. For an account that does not match, `POST /v1/route`
never fires at all. For an account that matches, Auto becomes the persisted
default without the user choosing it, and `/v1/route` fires.

From 1.1.34 through 1.1.36 the client router shared the session with its
replacement: `36: src/cli.ts:744-747` registers both the router and a new
`auto-model` extension that recognizes backend-routed catalog ids and reads the
concrete pick back from the response (`36: src/extensions/auto-model/index.ts`).

**1.1.37 removed all of this.** The release deletes `src/extensions/router/`
outright, and with it `POST /v1/route`, `KIMCHI_ROUTER_ENDPOINT` (last read at
`36: src/extensions/router/router-config.ts:16`) and the `@cast.ai` gate. No
replacement variable or config key exists. Auto is now a model the backend
routes itself: any `kimchi-dev` catalog model whose id starts with `auto` is
sent as that id to the ordinary inference wire of section 2.1, and the backend
reports the concrete pick in the response `model` field
(`src/extensions/auto-model/constants.ts:35`, `isAutoRoutedModel`). Its target
therefore moves with `llmEndpoint`, like every other inference call.

What changes for a reader is when Auto takes over. With no client gate, a fresh
main session installs `kimchi-dev/auto` as the persisted default model once per
install for **every** account whose catalog advertises `auto`, writes the
`autoDefaultApplied` marker, and tells the user
(`1.5.0 src/extensions/auto-model/index.ts:269-291`). The backend catalog is now
the only thing deciding who gets it. `getMe` is back to its two telemetry
callers (`src/extensions/telemetry/pre-session.ts:44`,
`src/extensions/telemetry/session-context.ts:339`), and nothing warms it at
startup for Auto any more.

**1.5.1 made it every launch, not once.** The marker is retired: a fresh main
session deletes `autoDefaultApplied` from the harness `settings.json`
(`1.5.1 src/extensions/auto-model/index.ts:104`), and on an account whose
catalog advertises `auto` it rolls a non-Auto model back to `kimchi-dev/auto`
and persists it on every fresh main session
(`1.5.1 src/extensions/auto-model/index.ts:270-303`). Only a launch-time
`--model`, `--provider`, `--multi-model` or `--models`, or a per-session
`/model`, avoids it. The network surface is unchanged: Auto still rides the
ordinary inference wire.

### 4.4 Connecting wakes a hibernated workspace, with no prompt

`:resume` is not a lifecycle command the user invokes. It is step three of every
remote authentication, and the reason is stated in place:

```ts
// src/sandbox/cloud/auth.ts:74-77
 * Hibernation is a replica-count state (the operator scales the sandbox pod
 * to 0 on inactivity); the workspace upsert only refreshes DB metadata and
 * never touches replicas, so it CANNOT wake a hibernated workspace — only
 * this RPC can (it scales the pod back to 1).
```

So attaching to a remote workspace costs capacity by waking a pod,
automatically. The read-only ownership probe is the one path that skips it
(`src/sandbox/cloud/auth.ts:133-141`).

The rejection the client swallows is narrower than it looks: it accepts any 4xx
whose body contains `"not suspended"` (`:117-119`), and the server's actual
answer is a 400 carrying
`{"message":"resume workspace: workspace is not suspended"}`
(`auth.test.ts:319-320`). Other 400s — for instance workspace creation being
disabled — propagate, and a failed resume aborts before the token exchange.

A related surprise on the same plane: a 429 does not always mean quota
exhausted. `src/sandbox/cloud/http.ts:43-51` parses
`{"message":"quota exceeded: …"}`, but `http.test.ts:93-103` pins a second 429
shape with no such prefix, returned for a validation failure on the user's own
workspace resource request.

### 4.5 A local model server is probed at every startup

Both startup paths probe it. The path with an API key present at launch calls
`discoverOllamaProvider` (`src/environment-models.ts:33`); the path without
calls `injectOllamaProvider` (`src/cli.ts:450` and `:478`). Failure is silent by
design (`src/ollama.ts:5-9`), so the probe leaves no trace when nothing is
listening. Host precedence is `$OLLAMA_HOST`, then `$KIMCHI_OLLAMA_HOST`, then
`http://localhost:11434` (`src/ollama.ts:19,121,125`).

Only one of the two startup paths writes `models.json`. With `KIMCHI_API_KEY`
present at launch, providers are registered in memory only and nothing is
persisted — the comment gives the reason, that the shared cache belongs to the
config account rather than to the override (`src/environment-models.ts:17`).

### 4.6 `llmEndpoint` carries two incompatible shapes

One config key, two legal shapes written by two code paths, and nothing
reconciles them. The table uses the US hosts; the EU region behaves the same
with `llm.eu.kimchi.dev`.

| Stored value                       | How it gets there                                                                                                              | Models and inference                                                                                      | Session auto-naming and memory                                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| unset                              | fresh install, or browser login, which deletes any stored value (`src/extensions/login/flow.ts:397` → `src/config.ts:887-898`) | correct — the region's root (`src/models.ts:20`)                                                          | correct — the `src/config.ts:595` default already carries `/openai/v1`                        |
| `https://llm.kimchi.dev`           | API-key login default; press Enter (`src/extensions/login/flow.ts:353,363,486-488`, `src/login-command-patch.ts:257,277`)      | correct                                                                                                   | `https://llm.kimchi.dev/chat/completions`, `/embeddings` and `/models` — the sub-path is lost |
| `https://llm.kimchi.dev/openai/v1` | the user pastes back the value the key reports by default                                                                      | `…/openai/v1/openai/v1`, `…/openai/v1/anthropic` and `…/openai/v1/v1/models/metadata` — all three doubled | correct                                                                                       |

`normalizeKimchiEndpoint` (`src/models.ts:18-25`) fixes only a missing scheme
and trailing slashes; it never strips a sub-path, and
`chatCompletionsApi`/`anthropicMessagesApi`/`modelsMetadataApi`
(`src/models.ts:27-36`) each append their own.
`src/extensions/session-name.ts:136` and the three memory calls of section 2.2
assume the suffix is already present. The only consumer that tolerates both is
the billing base builder, which strips a trailing `/openai/v1`
case-insensitively (`src/extensions/billing/status.ts:164-168`). The test suite
pins only the working shape, which is why the divergence survived.

Two consequences worth stating plainly. First, no value satisfies both the chat
consumer and the metadata consumer, so a single custom base cannot be correct
for every call. Second, reading `models.json` is not sufficient to know where
inference goes: a project-scoped `llmEndpoint` installs an in-memory `baseUrl`
override on the `kimchi-dev` provider (`src/extensions/login/index.ts:19,45-47`)
while the persisted file still shows the gateway URL, and a test pins that
intent — `models.json` is a global file and a project-local `llmEndpoint` must
never be written into it (`models.test.ts:765`).

A stored `llmEndpoint` also outranks the region for every consumer above, so
`KIMCHI_REGION=eu` on top of an API-key login made in the US region still sends
inference, the startup catalog fetch, billing, session naming and memory to
`llm.kimchi.dev`, while web search and the experimental pool follow the region.
Not every catalog fetch honors it: in-TUI login's key validation and model
refresh, `setup-tools`, the setup wizard and ACP pass no endpoint and go to the
region's host even when `llmEndpoint` points at a proxy (section 2.1). Section
4.10 has the rest of that split.

Since 1.1.27 a project-scoped value is read only from a trusted project
(`src/config.ts:6,570`, `isProjectScopeAllowed`; zero occurrences in the 1.1.21
`config.ts`). That closes a path by which a cloned repository could silently
repoint every prompt, and it also means a per-repository override is inert in an
untrusted directory. The region is deliberately not project-scoped at all
(`src/config.ts:588-589`).

### 4.7 Telemetry is on by default and the wizard does not ask

The default is `const defaultEnabled = true` (`src/config.ts:505`).

`promptTelemetry` has no prompt. The entire function is a notice followed by an
unconditional write:

```ts
// src/setup-wizard/steps/telemetry.ts:13-19
note(
  "Kimchi collects usage data … No prompt content or code is collected.",
  "Usage telemetry",
);
writeTelemetryEnabled(true);
```

There is no prompt object and no branch, and the step is unconditional in the
wizard. Re-running `kimchi setup` therefore re-enables telemetry a user
previously turned off. `kimchi setup-tools` does **not** do this — it honours an
existing explicit choice (`src/commands/setup-tools.ts:77-86`). That asymmetry
is easy to miss.

Opting out emits one final attributed event by design:
`src/commands/config.ts:55-68` writes `false`, then forces the in-memory flag
back to `true` with a comment saying why, so the `config_changed` event still
ships, carrying the account UUID and a top-level `userEmail`.

The payload carries a non-OTLP top-level `userEmail`
(`src/extensions/telemetry/transport.ts:112,188`), populated from `/v1/me`.
Every log record carries `client: "pi"` — the upstream harness name. File paths
are SHA-256-hashed to 12 characters; user messages contribute length only; error
messages are truncated to 300 characters.

Free-text now flows through it and did not at 1.1.21.
`src/extensions/telemetry/feedback.ts` is absent from the 1.1.21, 1.1.25, 1.1.26
and 1.1.27 trees and present from 1.1.29 on. It clamps a user-authored reason to
`MAX_REASON_LENGTH = 300` (`:53,60-61`) and ships it as `answer_value` with a
`reason_truncated` flag. At 1.1.21 the survey emitter could only send a lookup
from a fixed option list and dropped the event on a miss.

Telemetry fan-out to other tools is a configuration surface, not a call Kimchi
makes: `kimchi setup-tools` writes the two ingest URLs plus a bearer header into
`~/.claude/settings.json` (`src/integrations/claude-code.ts:33-45`) and into an
opencode plugin config. The HTTP call is then made by those tools. Since 1.1.35
those are the region's ingest URLs, and removal recognizes either region's
(`src/integrations/constants.ts:7-10`).

Two additions since 1.1.30 ride the same default-on channel. From 1.1.34 every
gated tool decision emits a `claude_code.tool_decision` record carrying the tool
name, the provider's tool-call id, accept or reject, and where the decision came
from — enums only, no arguments
(`src/extensions/telemetry/handlers/permissions.ts:60-81`). From 1.1.34 the
feedback event also names the concrete model a routed request resolved to, as
`routing_model` (`src/extensions/telemetry/feedback.ts:37,96`); the
`auto_model_used` boolean ran alongside it until 1.1.37 removed it.

The vendored memory library has its own telemetry: mem0 3.1.8 posts sampled
events to `https://us.i.posthog.com/i/v0/e/` unless `MEM0_TELEMETRY` is
`"false"` (`B36:L577835`, `B36:L579601`). Kimchi sets that variable to `"false"`
before every import of the library, but only when it is unset, so an explicit
value wins (`src/extensions/memory/backend.ts:319-323`). With memory off the
library is never loaded.

### 4.8 Spend exhaustion has two distinct server outcomes

The two are kept apart deliberately, and the reason is in the type:

```ts
// src/extensions/billing/status.ts:19-21
// "exhausted" is a hard stop (the server refuses the request); "rate-limited" still
// serves, just slower. Kept apart so the tip surfaces the second as a warning rather
// than an error — for a free-tier user a zero balance is a steady state, not a failure.
```

So `billing_status: exhausted` **or** `has_credits: false` means the gateway
refuses the request; `remaining <= 0` with credits otherwise intact means the
slow lane. Client-side nothing is gated either way, but enforcement is visible
in-band: `src/llm-gateway-error.ts` parses a first-class `budget_exhausted`
verdict out of the inference response (`:2`, `:21` non-retryable with exit code
1, `:97`, `:223`), deliberately outranking generic provider billing wording
(`:221-222`). The sibling `rate_limit` verdict carries an absolute UTC reopen
deadline that the CLI parses (`:146-161`).

Warnings come from two producers, not one. The credits threshold is
`LOW_CREDITS_THRESHOLD_USD = 5` (`:74`, used at `:370`); budget warnings fire at
90% and 100% via `budgetStatus` (`:669`), and a soft organization-scoped cap
deliberately never reaches the exhausted state even above 100%.

The same error module documents the rest of the gateway's protocol: HTTP 410 for
model retirement, parsed into replacement, alternatives and docs hints
(`:117-144`); eleven reason codes with a retryable, infrastructure and exit-code
policy table (`:1-32`), where infrastructure failures exit 74; and upstream
shapes such as `Hosted_vllmException` leaking through (`:101-102`).

### 4.9 Two more that changed when the router fired (through 1.1.36)

Both describe the client router that 1.1.37 deleted; they stay because a reader
of an older pin still needs them.

**Auto's routing POST is not issued where it is staged.** The
`before_agent_start` handler ends at `stageAutoRoutingAttempt` and fetches
nothing (`30: src/extensions/router/index.ts:164`); the fetch runs inside the
Auto provider when the model request starts (`30: api-provider.ts:134`). Two
consequences: the routing call is aborted by the same signal as the model
request, and "one POST per session" holds only on success — every failure path
resets the state to unresolved (`30: router/index.ts:165-168`) and
`before_agent_start` re-arms on unresolved (`:152-157`), so a session whose
router keeps failing issues one POST per user turn indefinitely.

**What is in that POST is the whole prompt, unredacted by default.**
`prepareRouterQuery` redacts only when `getRedactionConfig().enabled`
(`30: src/extensions/router/router-query.ts:17`), and the default is disabled —
precedence is `KIMCHI_REDACTION_ENABLED`, then `redaction.enabled` in the config
file, then `false` (`src/extensions/pii-redaction/config.ts:33-48`, unchanged at
1.1.37). A test pins that a former token budget was removed, so the whole prompt
goes (`30: router-query.test.ts:45-51`). Images become a marker rather than an
upload.

### 4.10 Region selection, new in 1.1.35, and the one component it misses

`src/regions.ts` calls itself the single source of truth for every external
endpoint (`:1-3`). The region is `KIMCHI_REGION` when that names a region, else
`region` in the global config file, else `us` (`src/config.ts:450-454`). Login
writes it next to the key (`src/config.ts:891`), and `kimchi config region` only
reports it; changing region means logging in again
(`src/commands/config.ts:105-130`). The picker offers EU only with experimental
features on, but the gate is on selection alone: a stored `region: "eu"` or
`KIMCHI_REGION=eu` resolves either way (`src/regions.ts:62-78`). The same
comment says EU endpoints are not generally available yet.

The region is the default for every first-party host except the workspace
worker, and each surface has its own override on top of it:

| Surface                                                                            | What wins over the region                                                                                 |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Inference, startup and login-flow catalog, credits, budget, session naming, memory | config `llmEndpoint` (in-TUI login, setup and ACP catalog refreshes follow the region only — section 2.1) |
| Control plane, account identity, quota                                             | env `KIMCHI_REMOTE_ENDPOINT`                                                                              |
| Browser login page, and every billing or key link shown to the user                | env `KIMCHI_WEB_APP_URL`                                                                                  |
| Telemetry ingest                                                                   | config `telemetry.endpoint` / `telemetry.metricsEndpoint`                                                 |
| Web search, experimental pool, setup-wizard key validation, `kimchi stats`         | nothing                                                                                                   |

Resolution is memoized, keyed on `KIMCHI_REGION` and the global config file's
modification time and size, so a login made by another process is picked up
(`src/config.ts:619-652`).

**The ssh and rsync tunnel does not follow the region.** `runProxy` hands the Go
helper only the API key (`src/ssh-proxy.ts:64-70`), and the helper runs its own
handshake — verify key, find the workspace, exchange a token — against
`KIMCHI_REMOTE_ENDPOINT` or else the hard-coded US base
(`tools/proxy-helper/pkg/cast/cast.go:203,213-218`,
`tools/proxy-helper/cmd/proxy/proxy.go:203`). `tools/` is byte-identical from
1.1.21 to 1.1.37. So for an EU account every TypeScript control-plane call goes
to `app.eu.kimchi.dev/api`, while `/sync`, `/terminal` and rsync transfer
authenticate against `app.kimchi.dev/api` with an EU key, which the client
itself treats as valid in its own region only. Exporting
`KIMCHI_REMOTE_ENDPOINT=https://app.eu.kimchi.dev/api` covers both, because the
helper inherits the environment. Whether the US host actually refuses an EU key
is unresolved (section 7).

## 5. Version behavior, 1.1.21 through 1.1.37

### 1.1.21 to 1.1.30: the endpoint surface is frozen

`diff -rq` of the 1.1.21 tree against the 1.1.30 tree:

```
IDENTICAL  src/api                    IDENTICAL  src/extensions/billing
IDENTICAL  src/auth                   IDENTICAL  src/extensions/stats
IDENTICAL  src/cli-auth               IDENTICAL  src/extensions/web-search
IDENTICAL  src/http                   IDENTICAL  src/extensions/web-fetch
IDENTICAL  src/sandbox                IDENTICAL  src/integrations
IDENTICAL  src/ollama.ts              IDENTICAL  src/ssh-proxy.ts
IDENTICAL  tools                      IDENTICAL  src/update/github.ts
```

Byte-identical, not merely equivalent. `src/update` differs only in
`settings.ts`, which carries no endpoint. **Zero endpoints were added, removed
or rehosted across that range.** The single literal that moved is `/v1/me`, and
the two extra occurrences are the entitlement gate of section 4.3.

### 1.1.31 to 1.1.37: rehosted by region, one path removed, three added

The same comparison against 1.1.37 leaves `src/http`, `src/ollama.ts`,
`src/ssh-proxy.ts`, `src/update/github.ts`, `src/extensions/web-fetch` and
`tools` byte-identical; every other directory above changed. Endpoint-literal
counts over `src/` and `tools/`:

| Literal             | 1.1.21 | 1.1.30 | 1.1.37 |
| ------------------- | ------ | ------ | ------ |
| `llm.kimchi.dev`    | 91     | 91     | 86     |
| `app.kimchi.dev`    | 35     | 35     | 30     |
| `api.cast.ai`       | 32     | 32     | 29     |
| `remote.kimchi.dev` | 39     | 39     | 39     |
| `api.kimchi.dev`    | 0      | 0      | 0      |
| `/v1/me`            | 9      | 11     | 11     |
| `llm.eu.kimchi.dev` | 0      | 0      | 17     |
| `app.eu.kimchi.dev` | 0      | 0      | 13     |
| `api.eu.cast.ai`    | 0      | 0      | 20     |

The counts are plain substring matches. The unchanged `/v1/me` total at 1.1.37
is a coincidence, not the gate surviving: the two gate literals left with the
router (section 4.3), and two unrelated matches came in — `/v1/messages` in a
comment at `src/models.ts:202` and `/v1/metrics` at
`src/extensions/telemetry/handlers/permissions.test.ts:11`. A delimited
`/v1/me\b` count is 9.

The US counts fell because the per-module constants were folded into
`src/regions.ts`, not because a US endpoint went away. The only host literals in
non-test source that 1.1.37 has and 1.1.30 lacks are the three EU hosts. The
path-shaped literals that changed are `/v1/route` (gone) and `/embeddings`,
`models` and a relative `chat/completions` (the memory calls of section 2.2).

### What did change is when calls fire

Each landing below was bisected directly against the trees named in the scope
note.

| Change                                                                                                       | Landed     | Why it matters                                                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------ | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `isRemoteRunEnabled` rewritten from opt-in to opt-out                                                        | **1.1.22** | the whole of section 2.4 becomes reachable without a setting — section 4.1                                                                                                                         |
| `dispatch_to_cloud_agent`, a model-callable tool that reaches remote compute                                 | **1.1.23** | the model, not only the user, can start a remote run — section 4.1                                                                                                                                 |
| `/v1/models/metadata` response schema rewritten                                                              | **1.1.23** | same URL, method and auth; the body changed — below                                                                                                                                                |
| MCP OAuth tokens moved to the OS keychain                                                                    | 1.1.26     | credential storage, not an endpoint change                                                                                                                                                         |
| Project `.kimchi/config.json` gated on project trust                                                         | **1.1.27** | a per-repository `llmEndpoint` no longer applies in an untrusted directory — section 4.6                                                                                                           |
| `@cast.ai` account gate on Auto, a third `/v1/me` caller                                                     | **1.1.29** | decides whether `/v1/route` ever fires — section 4.3                                                                                                                                               |
| Free-text survey capture shipped to `logs:ingest`                                                            | **1.1.29** | user-authored prose now leaves the machine — section 4.7                                                                                                                                           |
| Auto-default-applied marker written to `settings.json`                                                       | 1.1.30     | cosmetic                                                                                                                                                                                           |
| Session-naming model renamed to `deepseek-v4-flash-0731`                                                     | 1.1.32     | same endpoint and trigger — section 2.1                                                                                                                                                            |
| Cloud subagent sessions tagged with the local session id                                                     | 1.1.32     | `tags.parent_session_id` on the worker session-create body — section 2.4                                                                                                                           |
| Memory extension: embeddings, model list and fact extraction against `llmEndpoint`                           | **1.1.33** | opt-in and experimental, but once on it sends conversation text to the gateway from a detached worker — section 2.2                                                                                |
| Cloudflare 520–522 added to the shared retryable set                                                         | 1.1.33     | every `fetchWithRetry` caller retries those too, `/v1/search` up to 10 times — section 2.2                                                                                                         |
| Backend-routed `auto*` catalog models, alongside the client router                                           | **1.1.34** | Auto can be served without `/v1/route` — section 4.3                                                                                                                                               |
| Workspace create sends `spec: {resources, dependencies, egressPolicy}`; responses read only `spec.resources` | **1.1.34** | a request and response change on a surviving endpoint — section 2.4                                                                                                                                |
| `claude_code.tool_decision` telemetry per gated tool decision; feedback names the routed model               | **1.1.34** | more default-on events, enums and model ids only — section 4.7                                                                                                                                     |
| Region registry, `KIMCHI_REGION`, EU hosts                                                                   | **1.1.35** | every first-party host but the worker moves with the region; web search, the experimental pool, key validation and stats can be repointed at all; the Go ssh helper does not follow — section 4.10 |
| Client-side router, `/v1/route`, `KIMCHI_ROUTER_ENDPOINT` and the gate removed                               | **1.1.37** | Auto becomes a backend-routed catalog model and the default for any account whose catalog advertises it — section 4.3                                                                              |

Two request or response changes touch a surviving endpoint. The 1.1.34
workspace-create `spec` is described in section 2.4. The 1.1.23 metadata rewrite
is the other:

```diff
-	status?: "active" | "sunset" | "deprecated"
-	replacement?: string
+	deprecated_at?: string
+	sunset_at?: string
+	replacement_model?: string
+	alternatives?: ModelAlternative[]
+	deprecation_note?: string
```

Deprecation state is now derived from the new fields rather than read from
`status`. A catalog response written to the pre-1.1.23 schema is parsed without
error from 1.1.23 on and classified as having no deprecation state at all, so a
model marked `status: "sunset"` in such a response would be offered as active.

One boundary to keep: the analysis in section 6 of the vendored SDK surface, and
the `?beta=true` suffix on the Anthropic wire, describe the harness version
bundled by 1.1.27, 1.1.30 and 1.1.37 (`@earendil-works/pi-*` 0.85.1). The 1.1.21
tree bundles 0.84.1. Neither package is present in any Kimchi tree, so section 6
must not be back-dated to 1.1.21. Kimchi's patches against the harness touch
nothing in the Anthropic transport at any of those versions.

## 6. Looks first-party but is not

This section exists so that the exclusion is not re-derived. Roughly 150 path
literals in the binary belong to vendored dependencies, have zero call sites,
and are unreachable from any Kimchi code path. The reasoning is short: Kimchi
rebinds the base URL for exactly two SDK entry points —
`chat.completions.create` and `beta.messages.create` — and `src/entry.ts:55`
sets `KIMCHI_DISABLE_BUILTIN_PROVIDERS = "1"` unconditionally at entry, so the
harness's static provider table is switched off process-wide rather than merely
uncalled. The one documented re-registration is an OpenAI OAuth provider
(`src/extensions/login/index.ts:15-17`).

### Vendored SDK resource tables

| Paths                                                                                                                                                                                                                | Owner                                            | Why it is not Kimchi                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/v1/messages` (non-beta), `/v1/messages/count_tokens`                                                                                                                                                               | Anthropic SDK                                    | the harness only ever calls `beta.messages.create`                                                                                                                                                                                                             |
| `/v1/messages/batches*`, `/v1/models`, `/v1/models/{id}`, `/v1/files`, `/v1/complete`, `/v1/skills`, `/v1/organizations/*`                                                                                           | Anthropic SDK                                    | no first-party caller                                                                                                                                                                                                                                          |
| `/v1/agents`, `/v1/dreams`, `/v1/memory_stores/*`, `/v1/vaults`, `/v1/user_profiles`                                                                                                                                 | Anthropic SDK beta                               | no first-party caller                                                                                                                                                                                                                                          |
| `/v1/tunnels`, `/v1/tunnels/{certificates,reveal_token,rotate_token}`                                                                                                                                                | Anthropic SDK beta                               | the worst trap in the corpus — it reads exactly like the ssh tunnel of section 2.4, which has no REST surface at all                                                                                                                                           |
| `/v1/environments/*` including `/work`, `/heartbeat`, `/stop`, `/archive`                                                                                                                                            | Anthropic SDK beta                               | second worst — reads exactly like a remote-workspace lifecycle API. The real one is the control plane of section 2.4                                                                                                                                           |
| `/v1/deployments*`, `/v1/deployment_runs*` including `/pause`, `/unpause`                                                                                                                                            | Anthropic SDK beta                               | `pause`/`unpause` reads like hibernate and wake. The real wake is the `:resume` row of section 2.4                                                                                                                                                             |
| `/deployments/{model}{path}`                                                                                                                                                                                         | the Azure-flavoured client inside the OpenAI SDK | a second `/deployments` false positive, identifiable by its `api-key` header                                                                                                                                                                                   |
| `/responses`, `/responses/compact`, `/embeddings`, `/batches`, `/files`, `/uploads`, `/moderations`, `/images/*`, `/audio/*`, `/assistants`, `/threads`, `/vector_stores`, `/evals`, `/realtime/*`, `/fine_tuning/*` | OpenAI SDK                                       | `buildModelsConfig` never emits `api: "openai-responses"` (`src/models.ts:256,269`), so even the responses transport is unreachable                                                                                                                            |
| `/organization/{costs,usage/*,spend_alerts,users,invites,roles,audit_logs,admin_api_keys}`                                                                                                                           | OpenAI SDK                                       | the tempting false positives for account and billing. Kimchi's rebinding covers the inference surfaces only                                                                                                                                                    |
| `https://api.openai.com/v1` as the default LLM base, the Together and LM Studio embedders, and PostHog at `https://us.i.posthog.com/i/v0/e/` (`B36:L577835`)                                                         | mem0 OSS 3.1.8, bundled since 1.1.33             | Kimchi passes its own `baseURL` for the embedder and LLM (`src/extensions/memory/backend.ts:271-296`), writes with `infer: false` so the LLM client is never called, and switches the PostHog telemetry off unless the user set `MEM0_TELEMETRY` (section 4.7) |

### Upstream harness

| Endpoint                                                                                                                  | Owner                                                                 |
| ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `GET https://pi.dev/api/latest-version`, `/api/report-install`, `/api/installer/releases/{v}/package[-lock].json`         | harness self-update and telemetry                                     |
| `GET https://pi.dev/api/models/providers/{builtinId}`                                                                     | harness model catalog. **Never issued for `kimchi-dev`** — see below  |
| `GET https://radius.pi.dev/v1/config`, `/v1/oauth`, `/v1/oauth/device`, `/v1/oauth/token`                                 | harness gateway and its OAuth                                         |
| `POST https://radius.pi.dev/v1/artifacts?visibility=organization&title=Pi+session`, `POST https://radius.pi.dev/messages` | harness session sharing and messaging                                 |
| `POST {proxyUrl}/api/stream`                                                                                              | harness proxy provider. Dormant — no Kimchi call site sets `proxyUrl` |

`GET https://pi.dev/api/models/providers/kimchi-dev` is **refuted**, and it is
the most plausible-looking wrong answer in the corpus. The remote-catalog
wrapper is applied only to the harness's builtin providers (`B30:L431747`),
whose 43 entries contain no `kimchi-dev`; the near-miss entry has the id
`kimi-coding`. The `|| provider.id === "kimchi-dev"` clause inside that filter
is defensive and unreachable, which is exactly what makes it look like a wiring.
`src/entry.ts:55` is the kill switch above it.

Kimchi itself implements no OAuth 2 flow. Every `/v1/oauth*` path in the binary
belongs to the harness gateway or to a vendored provider SDK — including
`auth.kimi.com`, which is a near-miss for a name-based classifier and is not
Kimchi.

### Not endpoints at all

- Roughly 32 slash commands that read as HTTP paths in a raw index: `/sync`,
  `/terminal`, `/remote-sessions`, `/teleport`, `/ferment`, `/compact`,
  `/share`, `/model`, `/login`, `/budget`, `/stats`, `/tags`. The contiguous
  block at `B30:L453205-453334` is the command registry. This is the single
  easiest false positive in the corpus.
- `/$bunfs/root/*` — the single-file-executable virtual filesystem.
- `/api/hello`, `/api/users/:id` — runtime documentation examples.
- `https://example.com/mcp`, `http://dummy.com`, `https://studio.kimchi.dev/mcp`
  — documentation and test placeholders. The last appears once, in an import
  test fixture as a user-supplied connector URL.
- `/SKILL.md`, `/package.json`, `/properties`, `/children`, `/128` — filenames,
  JSON-pointer fragments and icon sizes.
- `hostedModels` — a type-only field on the analytics response
  (`src/extensions/stats/types.ts:44`), erased at build. The analytics response
  does carry per-model usage counts and the CLI discards them; that is a usage
  tally, not an inventory.

### Implemented in the worker client, never called

Five routes are fully typed, tested and exported from the worker barrel, have
zero production callers at every version, and are consequently absent from the
shipped bundle.

| Method | Path                      | Source                                  |
| ------ | ------------------------- | --------------------------------------- |
| GET    | `/api/status`             | `src/sandbox/worker/status.ts:5`        |
| GET    | `/api/gitidentity` (list) | `src/sandbox/worker/git-identity.ts:22` |
| GET    | `/api/gitidentity/{host}` | `src/sandbox/worker/git-identity.ts:26` |
| DELETE | `/api/gitidentity/{host}` | `src/sandbox/worker/git-identity.ts:48` |
| DELETE | `/api/secrets/{name}`     | `src/sandbox/worker/secrets.ts:27`      |

They are nonetheless real server routes: the client declares itself a
hand-mirror of the worker's own OpenAPI schema, with field names matching it
verbatim (`src/sandbox/worker/types.ts:1`). That schema file is stripped from
every released tarball.

### Documented but never called

| Endpoint                                                                             | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET https://api.cast.ai/v1/llm/providers`                                           | **Refuted.** `docs/supported-providers.md:17` names it in prose; the `curl` immediately below uses `/v1/llm/openai/supported-providers`, which is what the CLI calls. Take the `curl` as authoritative                                                                                                                                                                                                                                                                                                         |
| `…/clusters/{clusterId}/hosted-models`                                               | **Unproven, host unresolved** — section 2.5                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `https://api.kimchi.dev/aioptimizer/v1beta/{logs,metrics}:ingest`                    | **Stale documentation.** Zero hits for the host and for the unhyphenated service segment across every tree and the binary. The page is self-consistent around it, so it is a whole stale page; it documents third-party exporters, never the Kimchi CLI                                                                                                                                                                                                                                                        |
| `SearchTagKeys`, `SearchTagValues`, `SearchTags`, `GenerateLatestInferenceSummaries` | **Unproven, and not console-only.** They are method names on the same `ai-optimizer/v1beta` service the CLI already calls — `docs/model-apis-tags.md:108` lists `GenerateAnalytics` alongside them, and `GenerateAnalytics` is the CLI's `/ai-optimizer/v1beta/analytics`. **Their paths remain unknown and must not be constructed**: the method-to-path mapping is not mechanical, since `GenerateAnalytics` drops the verb while `GenerateProductivityMetricsTimeseries` keeps it as `…:generateTimeseries` |
| `X-Tags` / `X-LiteLLM-Tags` request headers                                          | **Refuted for the CLI.** Documented at `docs/model-apis-tags.md:43-56`; the CLI sends neither and uses a request-body `tags` array                                                                                                                                                                                                                                                                                                                                                                             |

## 7. Unresolved

1. **The host for `…/clusters/{clusterId}/hosted-models`.** The documented path
   carries an `organizations/{id}` segment. Every `api.cast.ai` path the CLI
   builds lacks that segment and infers org scope from the key via
   `inferUserFromApiKey=true`; every path the CLI builds that has it resolves to
   `app.kimchi.dev/api`. That is weak evidence for the latter, not proof.
   _Settles with:_ the site's API-reference page, which is absent from the
   50-page scrape, or one authenticated GET against each host.
2. **Whether the catalog ever serves `provider:"anthropic"` with
   `slug:"claude-fable-5"`.** This is the last gate on the configured-fallback
   path being live; both are exact-match comparisons. _Settles with:_ one
   authenticated
   `GET https://llm.kimchi.dev/v1/models/metadata?include_in_cli=true` and a
   grep. Requires a live API key.
3. **Whether a self-hosted deployment appears in the catalog at all.**
   `is_serverless:false` is not how it would arrive (section 2.5), and nothing
   else in the 13-field contract could distinguish one — `provider` is the only
   other hint and the CLI branches on exactly two values. _Settles with:_ the
   same authenticated GET, from an account that has one deployed.
4. **Model-deployment mutation endpoints.** Resolved as absence in the CLI and
   in the documentation; the documentation's claim that they exist is a broken
   cross-reference. Whether the server has them is still unknown. _Settles
   with:_ the API-reference page. **Do not invent paths.**
5. **Whether `…productivity-metrics:generateTimeseries` is live server-side.**
   The client method is dead at every version. _Settles with:_ one authenticated
   GET. Requires a live API key.
6. **`?beta=true` and the SDK rebinding trace at 1.1.21.** Unanswerable from
   Kimchi source at any version, because the SDKs are external packages.
   _Settles with:_ unpacking `@earendil-works/pi-coding-agent@0.84.1` and
   `@0.85.1`.
7. **Success-path bodies for `:resume` and `/api/startupcompletedz`.** The
   client reads only `resp.ok`. Fixtures model resume as `200 {}`, which is a
   fixture and not a capture; the readiness probe is body-less by design.
   _Settles with:_ a packet capture against a live workspace.
8. **The server-side default for `injectIntoEnv` on `PUT /api/secrets`.** The
   client side is settled — it is never sent, deliberately, and
   `secrets.test.ts:29` asserts the key is absent. _Settles with:_ the worker's
   own source, or a live PUT followed by reading the workspace environment.
9. **`clientType` values other than `"harness"`.** The purpose is settled: it is
   a server-side filter whose own documentation comment presupposes other
   creators, and the CLI knows exactly one value. The Go helper sends none at
   all, confirming it is optional. The server's full enumeration is not
   derivable from a client.
10. **Whether the control plane requires `X-Api-Key` or merely accepts it.**
    Both schemes are in live first-party use on the same four routes — the
    TypeScript client sends `Authorization: Bearer`, the Go helper sends
    `X-Api-Key` (`tools/proxy-helper/pkg/cast/cast.go:48`). _Settles with:_ a
    probe against the live service.
11. **The worker's OpenAPI schema.** Named at `src/sandbox/worker/types.ts:1`
    and stripped from every released tarball. It would settle the five uncalled
    routes and the session wire shape outright. _Settles with:_ upstream
    repository access.
12. **The server side of `app.kimchi.dev/cli-auth`.** The client contract is
    fully pinned: state echo, token in cleartext in the query string, an
    OAuth-style `error` pair, loopback-only binding, 5-minute timeout, and a
    `castai_v1_…` key shape. Unknown: scoping, scopes, whether the key is newly
    minted or re-issued, and its TTL. _Settles with:_ an account-side probe.
13. **Whether `llm.kimchi.dev` routes `/chat/completions` at the root** as well
    as under `/openai/v1` — that is, whether the second row of section 4.6's
    table actually misfires. The failure is silent either way, because session
    naming catches and falls back. _Settles with:_ one authenticated POST to
    each. Requires a live API key.
14. **`api.kimchi.dev`.** Absent from every source tree examined and from both
    binaries, and the one page naming it also misspells the service segment.
    "Never existed, or planned and never shipped" is much better supported than
    "retired alias", but it is not proof. _Settles with:_ a DNS or TLS probe, or
    releases earlier than 1.1.21.
15. **Whether `app.kimchi.dev/api` accepts a key issued in the EU region.** It
    decides whether `/sync`, `/terminal` and rsync work for an EU account
    without `KIMCHI_REMOTE_ENDPOINT` set (section 4.10). The client assumes not.
    _Settles with:_ one `POST …/workspace-tokens:verifyKey` with an EU key
    against each host.
16. **Whether the EU hosts serve every path the US hosts do.** The client builds
    the same paths under both, but calls EU not generally available and hides it
    behind experimental features. _Settles with:_ a DNS and TLS probe of the
    three EU hosts, then one authenticated GET per path family.

## Appendix — counts

| Class                                                                  | Count at 1.1.37                                                     |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `llm.kimchi.dev`                                                       | 11 (1.1.30 had 9: `/v1/route` went, the three memory calls came)    |
| `app.kimchi.dev`                                                       | 10 (including the browser login navigation)                         |
| per-workspace worker                                                   | 10 (9 HTTP plus the agent WebSocket)                                |
| ssh tunnel                                                             | 1                                                                   |
| `api.cast.ai`                                                          | 6 (one of them declared and never called)                           |
| distribution and self-update                                           | 6                                                                   |
| **Total remote endpoints**                                             | **44**                                                              |
| of which reachable under an EU host as well                            | 27 — every row above except the worker, the tunnel and distribution |
| local and loopback                                                     | about 22                                                            |
| implemented in the worker client, zero callers, absent from the binary | 5                                                                   |
| documented only, unproven                                              | 4                                                                   |
| vendored SDK and upstream-harness literals excluded                    | about 150, plus the mem0 defaults of section 6                      |

The 42 endpoints of 1.1.30 were present and identically hosted at 1.1.21 and
1.1.27; what changed across that range is when they fire, not which they are.
From 1.1.31 to 1.1.37 one was removed, three were added, and all but the worker,
tunnel and distribution rows gained a second host.
