# Airlock HTTPS passthrough

An instance runs a loopback CONNECT proxy while Claude keeps its native
authentication, base URL, and TLS configuration. The default instance forwards
opaque TLS. Optional client tokens and selective interception use the same
shared instance settings described below; they do not configure Claude’s proxy
identity or trust automatically in this manual opt-in. For authenticated managed
Claude selection, use [the Claude guide](claude.md).

The server handles HTTP/1.1 CONNECT, HTTP/1.1 absolute-form `http://`
forwarding, and CONNECT over cleartext HTTP/2 prior-knowledge connections to the
proxy. Ordinary HTTP forwarding over HTTP/2 is not implemented; the HTTP/2 path
provides CONNECT and the local health route. HTTP/2 inside an HTTPS tunnel is
negotiated directly between the client and destination through TLS ALPN; Airlock
forwards those opaque TLS bytes. This is distinct from HTTP/2 on the
client-to-proxy connection. Native Claude HTTP/2 behavior through this opt-in
has not been verified. This opt-in does not select interception, so Airlock does
not negotiate ALPN on the client's behalf.

## Shared opt-in

Use this configuration in either the Home Manager or devenv module. The forced
null leaves replace an ordinary pre-existing CPA selection; if another module
forces the same leaf, Nix still reports the priority conflict for you to
resolve.

```nix
{config, lib, ...}: {
  ai.proxy = {
    clientKey = lib.mkForce null;
    instance = lib.mkForce null;
    key = lib.mkForce null;
    url = lib.mkForce null;
  };
  ai.airlock.instances.main = {};
  ai.claude = {
    enable = true;
    proxy = {
      clientKey = lib.mkForce null;
      instance = lib.mkForce null;
      key = lib.mkForce null;
      url = lib.mkForce null;
    };
    native.settings.env.HTTPS_PROXY =
      "http://127.0.0.1:${toString config.ai.airlock.instances.main.port}";
  };
}
```

The root `ai.proxy` forced-null block is not Claude-specific: every runtime
inheriting that root selection stops using the preselected CPA proxy. Keep this
opt-in in an isolated test configuration unless that global effect is what you
mean. This manual opt-in uses no proxy selection; the forced leaves only clear a
pre-existing selection. To select Airlock through `ai.claude.proxy` instead, see
[the Claude guide](claude.md).

The instance defaults to port 8318 and claims that port exclusively. Its service
is named `airlock-main`, and the launcher renders `{"listen":"127.0.0.1:8318"}`
to a private runtime file before starting
`airlock serve --config "$AIRLOCK_CONFIG"`. Airlock uses ordinary Claude native
settings; it does not select the CPA proxy integration, replace Claude’s base
URL, or take ownership of Claude credentials.

## Authenticated interception service

Both backends accept this service configuration. Import `redact` from this
flake’s library (or use an existing binding to it):

```nix
ai.airlock.instances.main = {
  port = 8318;
  settings = {
    clients.claude.token = redact.file "/run/secrets/airlock-claude";
    interception.destinations = ["api.anthropic.com:443"];
  };
};
```

`clients` defaults to null and is omitted from the JSON, preserving optional
authentication. A nonempty map requires Basic proxy authentication using the
client name and token; an empty map fails startup. Tokens take redact
references, never plaintext Nix strings or store files. The shared service
launcher reads the reference on every start, writes a private 0600 token file
and puts only its path in `clients.<name>.token_file` in the runtime JSON. File
references also supply the service’s provider ordering and restart triggers.

`interception` defaults to null. When present, `destinations` contains exact
DNS-name:port strings; Airlock checks their validity before listening. Optional
`interception.upstream_roots` names a PEM file added to native upstream trust
roots. The service invokes
`airlock serve --config "$AIRLOCK_CONFIG" --ca-directory "${AIRLOCK_CONFIG%/*}/ca"`.
The CLI override supplies the CA directory omitted from generated JSON. Manual
JSON configurations still require `ca_directory` unless this override is passed;
the override replaces an explicit directory and requires interception.

The CA lives beside the actual service runtime config, not under `stateDir`:
`$XDG_RUNTIME_DIR/ai-service-airlock-main/ca`, or the shared service launcher’s
user-qualified `${TMPDIR:-/tmp}` fallback. This does not enforce tmpfs. Airlock
creates or validates the private CA before binding or reporting readiness; a
missing token, invalid configuration or invalid CA prevents readiness. A restart
reuses the CA while that runtime directory survives and rereads client tokens.
Removing the runtime directory (for example at logout) makes the next start
create a new CA. No activation job creates CA material and no trust is
installed. Configure a client’s proxy credentials and scoped trust separately
before using an authenticated/intercepting instance.

## Running and rolling back

On Linux Home Manager, apply the generation and then use the generated user
unit:

```console
$ systemctl --user start airlock-main.service
$ systemctl --user status airlock-main.service
$ systemctl --user stop airlock-main.service
```

To roll back, stop the service, remove the entire shared opt-in—both forced-null
selection blocks, the Airlock instance, and Claude’s `HTTPS_PROXY`
declaration—apply Home Manager again, and restart Claude. Darwin Home Manager
writes no systemd user unit; use the devenv path below or run Airlock manually.

With devenv, start the process manager, inspect the named process, and stop the
manager:

```console
$ devenv processes up
$ devenv processes status airlock-main
$ devenv processes down
```

To roll back, stop the manager, remove the entire shared opt-in—both forced-null
selection blocks, the Airlock instance, and Claude’s `HTTPS_PROXY`
declaration—then re-evaluate or reload devenv so its generated settings and
processes reflect the removal. Restart Claude, and start the process manager
again only when some other process still needs the supervisor.

Claude honors ordinary `NO_PROXY` rules. A host excluded there bypasses Airlock
and uses Claude’s native network path, so check the effective environment before
relying on Airlock for a request. Plain HTTP clients can use `HTTP_PROXY` with
HTTP/1.1 absolute-form requests; this opt-in sets only Claude's `HTTPS_PROXY`.
HTTP forwarding streams bodies with no response duration limit and does not
follow redirects or retry requests. This documentation describes the opt-in
only; applying it does not create provider credentials or send provider traffic.
