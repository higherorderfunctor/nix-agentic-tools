# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The server listens only on IP loopback addresses and detects HTTP/1.1 or
cleartext HTTP/2 prior knowledge on the same port. CONNECT opens a TCP tunnel to
a hostname or IP address with an explicit port. By default it forwards opaque
bytes; explicit DNS-and-port selections enable verified TLS interception. Native
HTTPS client authentication is unchanged. The listener currently accepts CONNECT
without proxy authentication; domain policy is not implemented yet.

Cleartext clients choose HTTP/2 by sending its prior-knowledge preface; HTTP/1.1
clients use the same listener automatically. The proxy listener does not yet
offer TLS or ALPN negotiation. Unselected TLS tunnels remain opaque; selected
destinations negotiate inner HTTP/2 or HTTP/1.1 independently on each TLS leg.
Native Claude traffic through `HTTPS_PROXY` has not been validated to use
HTTP/2; the HTTP/2 tests here select it with a prior-knowledge client.

HTTP/1.1 clients can also send absolute-form `http://` proxy requests. Airlock
streams request and response bodies without buffering a complete body, following
redirects, or imposing a response duration limit. It regenerates HTTP framing
and removes hop headers and proxy credentials while preserving destination
authorization. Transfer codings other than a single `chunked` coding are
rejected: requests receive `400` before connecting upstream, and upstream
responses receive `502` before their headers are forwarded. Upstream responses
containing both Transfer-Encoding and Content-Length also receive `502`. HTTP
upgrades are unsupported: `Upgrade` and `Connection` are stripped, so an
opportunistic `Upgrade: h2c` request is forwarded as plain HTTP/1.1; an upstream
`101` receives `502`. Declared request trailers are preserved; declared response
trailers are preserved when the client sends `TE: trailers`.

HTTP/2 on the proxy connection supports CONNECT tunnels and the local health
route; it does not support ordinary HTTP forwarding. HTTP/1.1 forwarding keeps
one upstream connection per downstream connection. Changing authorities releases
the old socket, and downstream termination closes its current socket and
connection task. A client reset cancels the upstream request; a FIN waits for
the response. Requests are not retried.

Origin-form `GET /health` returns `200 OK` with an `ok` body once the listener
is ready. Other origin-form paths return `404`; other methods on `/health`
return `405` with `Allow: GET`. Malformed CONNECT targets return `400`, failed
upstream connections return `502`, and a CONNECT connection attempt exceeding 10
seconds returns `504`. HTTP forwarding rejects malformed proxy targets with
`400`, HTTP/1.0 proxy requests with `505`, and upstream request failures with
`502`. Both paths limit an upstream connection attempt to 10 seconds, including
DNS capacity waits and lookup. At most 16 blocking DNS lookups run or wait in
the runtime's blocking queue across CONNECT and HTTP forwarding. A timed-out
lookup retains its slot until the resolver finishes. IP literals bypass DNS.

```bash
airlock serve                         # 127.0.0.1:8318
airlock serve --listen 127.0.0.1:9000
curl http://127.0.0.1:9000/health
curl --proxy http://127.0.0.1:9000 https://example.com/
curl --proxy http://127.0.0.1:9000 http://example.com/
curl --http2-prior-knowledge http://127.0.0.1:9000/health
```

`--listen` also accepts IPv6 loopback (`[::1]:9000`) and port `0` to choose a
free port. Startup prints the bound address. The server owns at most 128
accepted connections. Each HTTP/2 connection allows at most 32 concurrent
streams and CONNECT jobs. The connection driver continues processing reset and
flow-control frames while all job slots are occupied. A connection must deliver
its first complete request within 10 seconds, including the HTTP/2 preface;
later HTTP/1 header reads have their own 10-second deadline. Established tunnels
have no lifetime timeout. SIGINT and SIGTERM stop accepting and allow existing
connections up to 3 seconds to finish before closing them. Runtime teardown has
a separate 10-second bound.

## Configuration

`--config FILE` instead of `--listen` reads a strict JSON object such as
`{"listen":"127.0.0.1:9000"}`. It requires `listen` and rejects unknown or
duplicate fields, non-loopback addresses, and other arguments except
`--instance NAME`, which selects the CA interception loads.

## Nix instances

An `ai.airlock.instances.<name>` entry runs `airlock-<name>` on its loopback
port (default 8318) through `ai.services`, on Home Manager and devenv alike.
Selecting it defaults both `HTTP_PROXY` and `HTTPS_PROXY` to that listener for
supported runtimes. HTTPS uses CONNECT, preserving credentials; opaque tunnels
preserve TLS. Plain HTTP requests are forwarded to their absolute-form
destinations.

```nix
ai.airlock.instances.main = {};
ai.proxy.instance = "main"; # both protocols default to "http://127.0.0.1:8318"
```

See [Network Proxy](../../dev/fragments/ai-proxy/ai-proxy.md) for runtime
selection, protocol defaults and native overrides.

On Home Manager Linux, start and stop the instance with:

```console
$ systemctl --user start airlock-main.service
$ systemctl --user stop airlock-main.service
```

On devenv, use `devenv processes up` and `devenv processes down`. Restart Claude
and other selected runtimes after changing the selection.

An instance can also intercept selected destinations:

```nix
ai.airlock.instances.main.settings.interception = {
  destinations = ["api.anthropic.com:443"];
  upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; # optional
};
```

The service runs `airlock ca init --instance <name>` before
`serve --instance <name>` starts, so `ca.pem` exists before any client reads it.
On Home Manager the CA uses the default layout in
`$XDG_RUNTIME_DIR/airlock/<name>/` (see [Local CA](#local-ca)); on devenv the
service sets `AIRLOCK_HOME` to `airlock` under the project's devenv runtime
root, which init refuses when devenv falls back to the shared `/tmp`. Restarts
and updates reuse the CA; a reboot or logout clears the runtime directory, the
next start creates a new CA, and running clients must be relaunched to load it.

On Linux, when a runtime selects an intercepting instance and enables `ai.jail`
(or its runtime jail), the shared selection lowering masks `ca.key` as an empty
read-only file, leaving `ca.pem` readable. This applies to every jailed runtime
that selects the instance, even without CA trust delivery or with a native CA
override. The jail resolves the instance's runtime directory at launch as the
service does and refuses launch with a named error if the key is missing or
inaccessible, so start the service first. The mask covers only the selected key
path resolved at launch, not keys in other runtime directories or keys created
after launch. Relaunch clients after recreating a runtime directory. The mask
blocks direct file reads; it does not isolate same-user IPC such as the user
systemd manager, which can start processes outside the jail. Without the jail,
same-user processes can read the key directly; isolating the service under a
separate uid is future work.

The CA has no name constraints: Claude and its Node/Bun child processes trust it
for any hostname. Airlock reuses the CA across destination changes; name
constraints would require regenerating it when those destinations change. The
key mask limits direct key reads within the jail, with the boundaries above.

An intercepting instance registers an optional trust helper on the shared
network proxy entry. Claude's managed launcher sets `NODE_EXTRA_CA_CERTS` before
startup. With no inherited extra-CA file it uses the instance's `ca.pem` where
`airlock ca init` wrote it. Otherwise the helper composes the inherited file
followed by the instance CA, writes a temporary file and atomically renames it
to `<sha256 of inputs>.pem` beside `ca.pem` in the instance's runtime directory.
Identical inputs reuse the file across concurrent and later launches. Bundles
are not deleted per launch: their number is bounded by distinct input CA
contents, and they last as long as the runtime directory.

The launcher execs the real command directly, preserving its exit status,
signals and inherited file descriptors. Start the service before launching
Claude: a missing CA stops the launch with an instruction to start it. Opaque
instances change no CA trust. The helper and the jail ask `airlock ca directory`
for the instance's runtime directory with the service's base, so they refuse
what init refuses: on Home Manager a missing `XDG_RUNTIME_DIR`, and under
`AIRLOCK_HOME` a canonical path another user could replace.

A native `ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS` supplies the
extra-CA file instead of the ambient value; the helper appends Airlock's CA to
either one. When the managed launcher delivers trust, that native key is omitted
from the generated settings env so Claude cannot replace the composed startup
value. Setting Claude's package to null disables its managed launcher and warns
that trust must be set manually. Other runtimes selecting an intercepting
instance warn that TLS will fail without separately configured trust. No system
trust store is changed.

## Selective TLS interception

Add `interception` to the JSON configuration to select exact DNS names and
ports:

```json
{
  "interception": {
    "destinations": ["api.example.test:443"]
  },
  "listen": "127.0.0.1:9000"
}
```

Startup loads and validates the CA of the instance `serve --instance NAME` names
(see [Local CA](#local-ca)) before binding the listener. No trust is installed:
the client must explicitly trust the public `ca.pem`. A CONNECT to the absolute
form `api.example.test.:443` selects the same destination. Unselected names,
ports and IP literals retain opaque CONNECT behavior. Both outer HTTP/1.1 and
prior-knowledge HTTP/2 support interception. Each inner TLS leg independently
prefers `h2`, then `http/1.1` through ALPN; a peer without ALPN uses HTTP/1.1.
Unsupported-only ALPN offers fail. Airlock translates requests and responses
between all four HTTP/1.1 and HTTP/2 combinations while streaming bodies. HTTP/2
output relays request and response trailers, including those decoded from
chunked HTTP/1.1 messages. When a client sends `TE: trailers`, Airlock
advertises it upstream on either HTTP version, so HTTP/1.1 servers that gate
response trailers on TE can send them. HTTP/1.1 output relays only trailers
declared in `Trailer` on messages using chunked framing; undeclared trailers and
trailers on fixed-length or close-delimited messages are not relayed. Responses
to HTTP/1.1 clients carry trailers only when the client sent `TE: trailers`.
Split Cookie fields from HTTP/2 clients are joined with `; ` for HTTP/1.1
upstreams.

Airlock parses the ClientHello and requires SNI to match the CONNECT DNS name
before connecting upstream. It verifies the upstream certificate chain, name and
validity before completing the downstream handshake. System certificate roots
are the default; optional `upstream_roots` names a PEM certificate file added to
those roots for private origins or a corporate TLS-inspecting proxy. This widens
upstream trust. Upstream client certificates (mTLS) are not supported. There is
no insecure verification mode. Leaves exist only in memory, with one cache slot
per configured name, a seven-day lifetime, and renewal during their final day.

Each selected tunnel owns one verified upstream connection. Inner Host, absolute
URI authority, scheme and effective port must match the CONNECT destination.
HTTP/2 uses its required `:authority` and `https` scheme, and validates Host
when supplied. HTTP/1.1 requires Host. Concurrent inner HTTP/2 requests share
their upstream HTTP/2 connection. For an HTTP/1.1 upstream, Airlock queues
requests on its single connection, including streams opened before the client
receives SETTINGS. With either upstream version, each upload has a 1 MiB stream
window and the connection window is 33 MiB, exceeding all concurrent stream
windows combined so unread bodies cannot stall other uploads. These windows
permit up to 32 MiB of unread inner request DATA per session, plus protocol and
upstream buffers. Nested CONNECT, upgrades and unsupported authorities are
refused. Native destination Authorization and request bodies stream through the
existing HTTP framing and hop-header filters. TLS setup, writing the upstream
HTTP/2 preface to an upstream that never reads, and the first inner request’s
headers have ten-second deadlines; subsequent HTTP/1.1 header reads retain their
own ten-second bound. HTTP/2 permits at most 32 concurrent inner streams with
either upstream version. Its socket, stream and body work share a 128-future
session limit, including uploads that remain open after early responses; a
session whose live hyper futures exceed 128 is closed, dropping all its active
streams. Session termination synchronously drops queued and active protocol
futures. There is no session duration timer; inference may wait for its first
response header without a duration limit, and response bodies and SSE have no
lifetime timeout. Cancellation releases the owned upstream, while a plain
half-close permits a final response.

## Local CA

`airlock ca init [--instance NAME]` creates an instance's private local CA and
prints its certificate path; `serve --instance NAME` loads that CA for
interception and never creates one; `ca directory [--instance NAME]` prints the
runtime directory as init resolves and checks it, without creating it. Each
instance, `default` unless named, has its own runtime directory:

| Path                                   | Contents                                    |
| -------------------------------------- | ------------------------------------------- |
| `$XDG_RUNTIME_DIR/airlock/<instance>/` | the instance's runtime directory, mode 0700 |
| `…/<instance>/ca.key`                  | the CA's PKCS#8 private key, mode 0600      |
| `…/<instance>/ca.pem`                  | the CA's self-signed certificate, mode 0644 |

`AIRLOCK_HOME`, when set and non-empty, replaces the base for tests and custom
setups: an instance's runtime directory becomes
`$AIRLOCK_HOME/runtime/<instance>/`. Init resolves the existing part of
`AIRLOCK_HOME` to its canonical form and, before creating anything, refuses it
unless it and every directory above it is owned by the user or root and writable
by neither group nor others; `XDG_RUNTIME_DIR` is used as given. From there init
opens each directory down to the instance directory one at a time without
following a symlink, creates a missing one with mode 0700, and refuses one that
is a symlink, belongs to another user or grants group or other permissions.
Without either variable init fails rather than fall back to `/tmp`.

Existing material is validated and reused, and refused rather than ever
replaced.

## Build and validate

From the repository root:

```bash
nix build .#airlock
nix flake check
```

Inside the repository development shell, from `packages/airlock`:

```bash
cargo build --locked
cargo run --locked -- serve --listen 127.0.0.1:0
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

The overlay exposes Airlock as `pkgs.ai.airlock`. The Nix package uses the
repository's locked Rust toolchain. Rust tests cover HTTP forwarding and framing
rejection, bounded shared DNS, authority validation, byte streaming and
half-close in both directions, client cancellation, HTTP/2 multiplexing and flow
control, stream reset isolation, selective TLS interception, CA leaf issuance,
inner HTTP/1.1 and HTTP/2 translation, loopback binding, listener limits, header
deadlines, owned tunnel shutdown, local CA validation and CLI signals.
`checks.airlock-package` checks the packaged `--help` and `--version` entry
points.

`checks.airlock-instances` covers module wiring, port and name claims, proxy
registration, interception settings, selection defaults and overrides, and
Claude settings delivery. `checks.airlock-instance-runtime` starts each
backend's generated service launcher, requests `/health` at a configured
nondefault port and checks the runtime CA's reuse across restarts. It also
starts a mock Claude through the generated launcher to check CA delivery, native
and inherited extra-CA values, and refusal when the CA is missing. In CI the
jail mask is checked structurally, and missing-key launch refusals run before
bubblewrap; the CI build sandbox cannot run the real jail. Build
`checks.airlock-instance-jail-live` and run its `bin/airlock-instance-jail-live`
by hand on Linux to check the real service key is hidden, its certificate stays
readable, and Claude's trust helper runs inside the jail. That live run has no
structural fallback. Claude uses its installed jailed launcher, including with a
native CA override; the Codex-profile probe substitutes a test command and does
not exercise Codex's installed launcher. Rust protocol tests run through the Nix
package's `doCheck`.
