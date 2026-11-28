# Airlock route plan prototype

The optional route plan prototypes the request path after PR #3020.
Both CONNECT transports converge in [tunnel.rs](../packages/ai/airlock/src/tunnel.rs).
The shared grant, route, and outbound request live in [gateway.rs](../packages/ai/airlock/src/gateway.rs).
[tls.rs](../packages/ai/airlock/src/gateway/tls.rs) owns inner TLS and HTTP/1.1.
[usage.rs](../packages/ai/airlock/src/gateway/usage.rs) observes response frames
as they pass through.

## Run the local smoke check

From `packages/airlock`:

```sh
cargo build --locked
python3 checks/route-plan-smoke.py target/debug/airlock
```

The check provisions its own CA, fake upstream credentials, and two
client grants. It exercises explicit inference, selected CONNECT interception,
pre-response fallback, a truncated stream, typed decision fallback, and the
usage view. The existing [HTTP/2 tests](../packages/ai/airlock/tests/http2.rs)
cover the outer CONNECT transport.

## Example Nix instance

```nix
{pkgs, ...}: {
  ai.airlock.instances.prototype = {
    port = 8318;
    routePlan = pkgs.writeText "airlock-routes.json" (builtins.toJSON {
      clients.probe = "/run/airlock-secrets/client";
      intercept = "api.anthropic.com:443";
      ca_instance = "prototype";
      management = {
        listen = "127.0.0.1:8319";
        token_file = "/run/airlock-secrets/operator";
      };
      routes = [
        {
          client = "probe";
          path = "/v1/messages";
          model = "your-model-id";
          primary = {
            uri = "https://api.anthropic.com/v1/messages";
            key_file = "/run/airlock-secrets/anthropic";
            pool = "anthropic-api";
          };
        }
      ];
    });
  };
}
```

The plan contains paths. Provision the files out of band so the service account
can read upstream credentials and the sandbox can read only its client token.
Use an isolated test harness with the instance CA, without adding that CA to
system trust. The binary prints the bound listeners at startup. Run
`airlock ca init --instance prototype` under the service's runtime environment
to locate its public CA file.

Explicit HTTP/1.1 calls send the client token as `Authorization: Bearer …`.
A selected CONNECT uses Basic proxy authentication with the client name and
its token, carried separately from the native HTTP request. Outer HTTP/1.1 and
cleartext HTTP/2 CONNECT share the tunnel path. Other CONNECT destinations are
opaque. A sandbox that requires enforced egress needs a deployment boundary
around this service.

Each route grants one client, incoming path, and exact model. Configure an
optional fallback destination with the same shape as the primary. A 429 or 503
before the response is handed to the client can select that fallback once.
Destinations can supply an upstream model alias. The optional JSON passthrough
operation supports `auth = "bearer"` and a JSON pointer such as
`unwrap = "/result"`. This covers the decision route shape through the same
route planner as Messages.

The management listener serves `GET /health` and a token-protected `GET /usage`.
Usage is a bounded in-memory view of recent upstream attempts, with optional
token counts from small JSON responses and identity-encoded Messages SSE.
Response bytes stream unchanged on the inference path. The plan covers a single
intercepted authority and uses direct, verified HTTPS for selected upstreams.
Provider login, live harness behavior, and Proton chaining require their own
integration work.
