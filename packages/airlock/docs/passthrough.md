# Airlock HTTPS passthrough

Airlock’s R04 milestone is deliberately small: an instance runs a loopback HTTP
CONNECT proxy while Claude keeps its native authentication, base URL, and TLS
configuration. Airlock does not configure provider credentials, CA certificates,
TLS interception, Cedar policy, storage, routing, or a user interface.

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
mean. This milestone adds no proxy-selection abstraction; the forced leaves only
clear a pre-existing selection.

The instance defaults to port 8318 and claims that port exclusively. Its service
is named `airlock-main`, and the launcher renders `{"listen":"127.0.0.1:8318"}`
to a private runtime file before starting
`airlock serve --config "$AIRLOCK_CONFIG"`. Airlock uses ordinary Claude native
settings; it does not select the CPA proxy integration, replace Claude’s base
URL, or take ownership of Claude credentials.

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
relying on Airlock for a request. Airlock makes no promise about `HTTP_PROXY`:
absolute plain-HTTP requests are outside this milestone. This documentation
describes the opt-in only; applying it does not create provider credentials or
send provider traffic.
