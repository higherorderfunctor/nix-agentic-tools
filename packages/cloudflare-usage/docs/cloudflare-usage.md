# Cloudflare daily neurons

`cloudflare-usage claude` (or `codex`) reads today's Workers AI neurons through
that runtime's CPA management endpoint. Install the public `cloudflare-usage`
package. It is standalone: it adds no delegate-routing pool, reader
registration, model list, or inference route, and requires no
passthrough-provider patch.

Set these deployment inputs:

| Variable                                        | Meaning                                                      |
| ----------------------------------------------- | ------------------------------------------------------------ |
| `CLOUDFLARE_ACCOUNT_ID_FILE`                    | Readable file containing the 32-digit hexadecimal account ID |
| `CLOUDFLARE_AUTH_INDEX`                         | Optional nonempty CPA auth index; bypasses discovery         |
| `CLOUDFLARE_DAILY_NEURONS_LIMIT`                | Explicit positive finite daily entitlement, in neurons       |
| `DELEGATE_USAGE_CPA_CLAUDE_MANAGEMENT_KEY_FILE` | File containing the Claude instance management key           |
| `DELEGATE_USAGE_CPA_CLAUDE_URL`                 | Claude instance CPA base URL                                 |
| `DELEGATE_USAGE_CPA_CODEX_MANAGEMENT_KEY_FILE`  | File containing the Codex instance management key            |
| `DELEGATE_USAGE_CPA_CODEX_URL`                  | Codex instance CPA base URL                                  |

Only the selected runtime pair is used. Secret files contain one nonempty line;
there are no secret value flags or direct-token fallback. Treat the management
URL as trusted deployment configuration; use HTTPS for remote CPA instances.
Management redirects are refused and ambient HTTP proxy settings are ignored.
Discovery reads management config in memory; credentials and account IDs are
never printed, persisted, or passed in argv.

Discovery reads the v8 management `config/api-keys/claude`, `codex`,
`openai-compatibility`, and `passthrough` collections. Only a 404 from the
optional passthrough surface is skipped. Family identity comes from the
collection; grouped providers must also have a provider name that is nonempty
after trimming whitespace; internal spaces are allowed. Credentials qualify only
with HTTPS hostname exactly `api.cloudflare.com` and an empty base path or
`/client/v4` (including descendant paths on a segment boundary). Duplicate keys
across groups count once. Exactly one distinct nonempty key with an auth index
must remain; missing or ambiguous matches fail with a static diagnostic.

An existing CPA API-key credential can supply the token independently of
passthrough support. To select a specific credential, obtain its `auth_index`
from the authenticated management config view in memory and set
`CLOUDFLARE_AUTH_INDEX`; do not print credentials or save the config response.
The override skips discovery but still uses CPA's token substitution. CPA sends
`Bearer $TOKEN$` through management `api-call` to
`https://api.cloudflare.com/client/v4/graphql`, with the account ID and UTC date
as GraphQL variables. No inference request is made.

Deployment needs a token authorized to read the account's Workers AI analytics
and an explicit daily entitlement. The command cannot infer either token
permissions or paid/free allowances. No default quota is invented. The query and
response shape are supplied contracts; live Cloudflare compatibility and
exhausted-budget HTTP behavior have not been measured here.

Output follows the usage schema: pool `cloudflare`, account name/auth index from
CPA, null plan, empty balances/bonuses, and one `daily` window. Its duration is
86400 seconds and its reset is next midnight UTC, calculated from the same clock
snapshot as the query date. Used percentage is neurons divided by the configured
limit times 100; overage remains above 100 and remaining percentage floors at
zero. Window status is null. An empty group list for one matching account means
zero usage. Missing, null, mismatched or multiple accounts; multiple groups;
invalid neurons; GraphQL errors even alongside data; and either HTTP layer's
failure all fail without printing server payloads.

CI checks `cloudflare-usage` exercise the real Python entrypoint against a local
CPA server with an injected clock, plus the packaged executable. The structure
check verifies the public executable and actual generated routing inventory.
Neither check contacts Cloudflare.
