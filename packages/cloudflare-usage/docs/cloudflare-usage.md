# Cloudflare daily neurons

`cloudflare-usage claude` (or `codex`) reads today's Workers AI neurons through
that runtime's CPA management endpoint. Install the public `cloudflare-usage`
package. This is a standalone debugging tool: it adds no delegate-routing pool,
reader registration, model list, or inference route.

Set these deployment inputs:

| Variable                                        | Meaning                                               |
| ----------------------------------------------- | ----------------------------------------------------- |
| `CLOUDFLARE_ACCOUNT_ID_FILE`                    | File containing the 32-digit hexadecimal account ID   |
| `CLOUDFLARE_AUTH_INDEX`                         | Optional CPA auth index; skips discovery              |
| `CLOUDFLARE_DAILY_NEURONS_LIMIT`                | Required positive finite daily entitlement in neurons |
| `DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE` | File containing the Claude instance management key    |
| `DELEGATE_USAGE_CPA_CLAUDE_URL`                 | Claude instance CPA base URL                          |
| `DELEGATE_USAGE_CPA_CODEX_MANAGEMENT_KEY_FILE`  | File containing the Codex instance management key     |
| `DELEGATE_USAGE_CPA_CODEX_URL`                  | Codex instance CPA base URL                           |

Only the selected runtime's URL/key-file pair is used. The account and
management key files contain one nonempty line. Treat the management URL as
trusted configuration and use HTTPS for remote instances. Management redirects
are refused and ambient HTTP proxy settings are ignored. Credentials and account
IDs are never printed, persisted, or passed in argv.

The vendor script composes with delegate-routing's `usage-cpa.sh` through its
`mkUsageScript` builder. That helper owns management authentication, runtime
pair validation, in-memory credential discovery, api-call envelope handling, and
the common `usage_project` output schema. Discovery reads the v8 management
`config/api-keys/claude`, `codex`, `openai-compatibility`, and `passthrough`
collections. Missing collections (404) follow the shared helper's
empty-collection behavior. Credentials match hostname exactly
`api.cloudflare.com` and path `/client/v4` or a descendant on a segment
boundary. The Jev/OpenCode base is ignored. Duplicate keys count once; exactly
one distinct key with an auth index must remain. `CLOUDFLARE_AUTH_INDEX` can
select a credential explicitly.

CPA sends `Bearer $TOKEN$` through management `api-call` to
`https://api.cloudflare.com/client/v4/graphql`. The Cloudflare key stays at CPA;
the GraphQL payload contains the account ID and current UTC date. No inference
request is made. The token must be authorized to read Workers AI analytics; the
reader cannot infer its permissions or the daily entitlement. Live Cloudflare
query/response compatibility has not been measured here.

Output uses pool `cloudflare`, the selected CPA auth index as account
name/index, null plan, empty balances/bonuses, and one `daily` window of 86400
seconds. Reset is next midnight UTC from the same clock snapshot as the query
date. Used percentage is neurons divided by the configured limit times 100;
remaining percentage is 100 minus used percentage, following the shared
projector. An empty analytics group list means zero usage. GraphQL errors,
account mismatch, invalid neurons, and failures at either HTTP layer fail
without printing server payloads.

CI reuses `packages/delegate-routing/checks/usage-runtime.py`'s local CPA
fixture for success, Jev exclusion, ambiguity, empty usage, representative
errors, token substitution, proxy bypass, redirect refusal, and secret handling.
It runs the packaged executable and a source composition with argv probes. The
unchanged structure check verifies the public executable and actual routing
inventory. Neither check contacts Cloudflare.
