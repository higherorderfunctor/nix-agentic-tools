# glab

Glab settings arrive through its environment at launch. A self-hosted hostname
can stay out of the store, along with tokens, by using runtime references. Home
Manager and devenv expose the same options and supply the `rv` argument.

```nix
{ config, rv, ... }: {
  glab = {
    enable = true;
    host = rv.file { path = config.sops.secrets.gitlab-host.path; };
    token = rv.file { path = config.sops.secrets.gitlab-token.path; };
    settings = {
      check_update = false;
      git_protocol = "ssh";
      telemetry = false;
    };
  };
}
```

A public hostname can be a literal: `glab.host = "gitlab.com";`. Tokens are
reference-only: literal tokens fail option type checking. Use
`rv.helper { path = "/absolute/bin/read-token"; }` for an executable that emits
a value. `lib.runtimeValues` exposes the same helpers to manual library callers.
`lib.glab.mkGlab` validates its input through the shared module declarations.

## Runtime references

Every delivered scalar setting accepts its ordinary literal type or a reference.
Secret classification uses key names and upstream keyring metadata. Token-like
keys in `extraSettings` also require references, including newly introduced
keys:

```nix
{ rv, ... }: {
  glab.extraSettings.gitlab_token = rv.file { path = "/run/secrets/token"; };
  glab.settings.api_host = rv.file { path = "/run/secrets/api-host"; };
}
```

The shared option library supports string and boolean literals or references.
Secret keys reject literals.

A missing, unreadable, empty or directory source, or a failed helper aborts
before glab runs. Diagnostics name the option and failure, never the resolved
value or helper output. The reader drops trailing newlines before the empty
check. Values refresh on each invocation. A reference marked `secret = true`
cannot be passed through argv; this includes a host used by glab's host-entry
initialization.

## OS-keyring synchronization

Linux Home Manager can persist a runtime token through Secret Service:

```nix
{ rv, ... }: {
  glab = {
    enable = true;
    host = "gitlab.example.com";
    keyringSync.enable = true;
    token = rv.file { path = "/run/secrets/gitlab-token"; };
  };
}
```

Activation creates a marker under XDG state. A systemd path unit consumes it
when the graphical session is available. The service probes Secret Service
before reading the real token, then uses the same shared reader as the launch
wrapper. It passes the token over stdin to
`glab auth login --stdin --use-keyring`. Failed or cancelled probes never read
the token. The marker is removed on every exit; one activation permits one
attempt.

The launch wrapper omits `GITLAB_TOKEN` in this mode so glab reads its keyring.
Other token entries in `extraSettings`, including environment aliases such as
`GITLAB_ACCESS_TOKEN`, are rejected: keyring synchronization reads only
`glab.token`, so these entries cannot be synchronized safely. The devenv module
declares the option for parity but rejects enabling it: project shells do not
own graphical-session login services.

## Generated settings and state

`settings.*` comes from the committed `extracted.json` sidecar. Upstream
descriptions and environment aliases are retained. List-valued keys such as
`custom_headers` have no scalar environment representation and remain excluded.
Keys glab maintains itself remain settable when upstream marks them settable;
pinning one prevents glab from updating it.

`extraSettings` supports future scalar keys. Known keys use upstream environment
aliases; unknown keys use the uppercase fallback. Keys are classified during
option type checking.

Glab owns its mutable `config.yml`. The wrapper creates its directory with mode
0700, repairs the file to 0600, and seeds a `hosts:` entry using glab itself so
`auth status` can enumerate the configured host. The host consequently appears
in that private runtime file. Fixed-string matching supports IPv6 hostnames.

`configDir` accepts a literal path or reference. Literal paths are shell-quoted;
`$VAR`, `~` and command substitutions do not expand. Home Manager leaves glab on
its normal user-global default; devenv defaults to
`"${config.devenv.state}/glab-cli"`. Literal paths also enter an enabled Codex's
writable roots. Runtime paths cannot be added to that static declaration.

## Migration

Replace `host.plain = "gitlab.com"` with `host = "gitlab.com"`. Replace
`token.file = "/run/secrets/token"` with
`token = rv.file { path = "/run/secrets/token"; };`. The same constructor change
applies to helpers. The `plain` credential arm has been removed; move literal
tokens into runtime files or helpers.
