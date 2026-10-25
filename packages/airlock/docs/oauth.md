# airlock managed primary OAuth

> **Last verified:** 2026-10-25 — managed primary token exchange, refresh, and
> revoke are client-bound and durable.

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

`airlock-claude-native-oauth` runs pinned Claude through both generated
launchers against a loopback fake. It verifies empty-store login, refresh,
fake-pair persistence, profile, and Messages; real account behavior remains
live-unverified.
