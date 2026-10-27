# Claude through a managed Airlock instance

<!-- cspell:words noproxy -->

Both Home Manager and devenv accept the same explicit selection:

```nix
ai.airlock.instances.main.settings = {
  clients.claude.token = redact.file "/run/secrets/airlock-claude";
  interception.destinations = ["api.anthropic.com:443"];
};
ai.claude = {
  enable = true;
  proxy = {instance = "main"; clientKey = "claude";};
};
```

Use this flake's `redact` library or an existing binding to it. The selected
instance must be enabled and contain the named client. CPA and Airlock instance
names share one claim group; give them different names. Only Claude currently
supports Airlock selection. A per-runtime selection replaces `ai.proxy` as a
whole, so unrelated runtimes can retain their CPA selections. To remove an
inherited selection explicitly, force all four leaves (`clientKey`, `instance`,
`key`, `url`) to null at the root and runtime scopes that select it.

Start Airlock before launching the managed `claude` command. On Linux Home
Manager, apply the configuration and run:

```console
$ systemctl --user start airlock-main.service
$ systemctl --user status airlock-main.service
$ curl --noproxy '*' --fail http://127.0.0.1:8318/health
ok
```

With devenv, reload the configuration, run `devenv processes up` in another
terminal and inspect `devenv processes status airlock-main`. Home Manager on
Darwin has no systemd user service; use devenv for this managed service path.
Use the configured port when it differs from 8318. The local health route needs
no client token and sends no upstream request. The Claude launcher also performs
one bounded local health request before exec; it never starts the service or
waits indefinitely. Missing, hidden, unsafe or stale runtime artifacts stop the
launch with a service-start diagnostic.

At each exec the launcher reads the service's rendered `config.json` and its
private token file. It percent-encodes the client name and token into
`HTTPS_PROXY`, and removes upper/lowercase HTTP, HTTPS, ALL and NO proxy inputs.
It leaves Claude's OAuth store, API keys, API-key descriptor, arguments, stdin
and config root intact. Airlock never invokes CPA's credential helper, auth
suppression, quiet defaults or model picker. Upstream credentials still travel
through Claude's native authentication inside CONNECT.

For interception, `NODE_EXTRA_CA_CERTS` points to the service's `ca/ca.pem`. An
inherited extra-CA file is combined with that CA in a private 0600
content-addressed bundle under the same runtime directory; unreadable inherited
trust stops launch. Bundles publish atomically and remain for that directory's
lifetime, so repeated launches with identical input create no additional files.
Different trust inputs retain separate bundles until the runtime directory is
cleared. No system trust is installed or mounted. Omit `interception` for opaque
CONNECT: that selection requires no CA and leaves inherited extra trust alone.

The service runtime path follows its usual XDG/TMPDIR selection. Claude's
configured native `XDG_RUNTIME_DIR` and `TMPDIR` are applied before lookup, then
the service's literal directory overrides take precedence for finding its files.
Secret-backed directory overrides cannot be used by this selector. The service
and client must otherwise share the same runtime environment. The default jail
exposes these paths and loopback; explicitly masking config, tokens, CA or
inherited trust causes launch failure. Jail environment exclusions run before
the launcher, which owns and exports the managed proxy/trust inputs afterward.

Configured `native.settings.env` proxy/bypass variables conflict with selected
Airlock. Interception also refuses configured `NODE_EXTRA_CA_CERTS` and
`NODE_TLS_REJECT_UNAUTHORIZED`; inherit additional trust in the launching
environment instead. Native upstream auth settings remain valid. User or managed
settings files outside this Nix configuration can override process inputs after
exec; inspect those separately during HITL. A null Claude package is refused
because this integration requires the managed launcher.

Restart the service after rotating its token: Airlock loads tokens before bind,
and each new Claude process reads that service's current runtime token file.
Changing a token file under a running service does not reload its in-memory
token. A restart reuses the runtime CA; clearing the runtime directory creates a
new one. Restart Claude after either token or CA replacement.

Mock launcher checks prove process delivery on both backends. Actual pinned
Claude/Bun trust behavior and native end-to-end provider traffic remain an
unperformed human test gate. This integration alone makes no claim that every
Claude request honors the proxy or extra-CA variable.

To roll back, remove the Claude selection (and any inherited root selection),
rebuild/reload, and restart Claude. That stops adding these scoped inputs.
Stopping/removing the Airlock instance is a separate explicit choice; ordinary
native auth/config remains available throughout rollback.
