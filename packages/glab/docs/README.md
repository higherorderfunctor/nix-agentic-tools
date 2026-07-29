# glab

Declarative configuration for the GitLab CLI, with the instance URL and
token supplied at invocation time so neither reaches the Nix store.

The same `glab.*` options exist in the home-manager module and the devenv
module — they are one shared declaration
(`packages/glab/modules/options.nix`), not two that happen to agree.

## Usage

```nix
{
  glab = {
    enable = true;

    # Self-hosted instance whose URL should stay out of the store.
    host.file = config.sops.secrets.gitlab-url.path;
    token.file = config.sops.secrets.gitlab-token.path;

    settings = {
      git_protocol = "ssh";
      check_update = false;
      telemetry = false;
    };
  };
}
```

For a public instance the URL is ordinary configuration, so use `plain`:

```nix
glab = {
  enable = true;
  host.plain = "gitlab.com";
  token.helper = "/run/wrappers/bin/my-token-helper";
};
```

## Secret-capable options

`host`, `token` and `job_token` each take **exactly one** of three
branches. The option is a discriminated union, so "plain and file both
set" is not a state you can construct — there is no runtime assertion to
forget.

| branch   | behavior                                                       |
| -------- | -------------------------------------------------------------- |
| `plain`  | literal value, interpolated into the store, **world-readable** |
| `file`   | path read at invocation time; nothing enters the store         |
| `helper` | executable run at invocation time; nothing enters the store    |

`file` and `helper` both **abort** when the value comes back empty, rather
than exporting nothing and letting glab fall back to its own default. That
matters most for `host`, whose default is `gitlab.com`: an empty
self-managed URI would otherwise send your token to the wrong instance,
silently. A half-applied sops rotation, or a key the reader cannot
decrypt, produces exactly that empty file.

`token` and `job_token` are secret-capable because glab's own schema
marks them keyring-eligible. `host` is included on top of that: a
self-hosted instance URL is often information an operator would rather
not publish in a world-readable store path, even though upstream does not
class it as a credential.

## Settings

`glab.settings.*` is **generated** from
`overlays/generic/glab-extracted.json`, which is extracted from glab's
own `internal/config.KeySchema` and drift-checked by
`checks.glab-extracted`. Option names are upstream's key names, and each
description is upstream's own.

That means the surface cannot silently disagree with the packaged
version, and it also means env-var mapping is exact — several keys have
non-obvious names (`telemetry` → `GLAB_SEND_TELEMETRY`, `remote_alias`
→ five aliases) that a hand-written list gets wrong.

Two caveats worth knowing:

- Some generated keys are ones **glab maintains itself** — their
  descriptions say "automatically set" (`last_seen_version`, the
  `duo_cli_*` and `orbit_local_*` bookkeeping). They appear because
  upstream marks them settable; pinning one stops glab updating it.
- **List-typed keys are omitted.** The only one today is
  `custom_headers`, a sequence of records with no meaningful single
  env-var spelling. Set it with `glab config set`.

`glab.extraSettings` is the escape hatch for keys newer than the packaged
schema. It forms the variable by upper-casing the key, which is what glab
does for any key without an explicit override — exact for genuinely new
keys, wrong for one that has aliases. If such a key starts behaving
oddly, bump the package: the typed option appears on its own.

## `auth status` and the seeded `hosts:` entry

`glab auth status` is the one command that does **not** read the resolved
configuration. It enumerates `cfg.Hosts()` — the `hosts:` block of
`config.yml` — so an env-only setup makes it report `gitlab.com` and
"No token found" while every other command works fine. That is a trap: it
is the first thing anyone runs when debugging auth.

The wrapper therefore seeds a `hosts:` entry on first run, by invoking
glab itself (`glab config set --host <host> api_protocol <proto>`) rather
than editing YAML. glab owns and reformats that file, so hand-written
YAML would drift — and this way nothing like `yq` enters the closure.

Note the flag is `--host`, **not** `-h`: `-h` collides with help and
silently writes a `gitlab.com` entry instead.

`api_protocol` is derived from the scheme on the configured host rather
than hardcoded, so an `http://` instance is not seeded with a
contradictory `https`. With no scheme given it falls back to `https`,
matching glab's own default for that key.

A fast path means the seed runs once, not on every invocation: the
wrapper scans `config.yml` for a line that, trimmed, equals `<host>:`.
That comparison is a **fixed string**, deliberately not a pattern —
`grep` was tried and rejected, because a bracketed IPv6 host
(`[2001:db8::1]`) puts regex metacharacters in the hostname, and a
pattern that matched too much would skip seeding while the entry is
genuinely absent. It is also pure bash builtins, so it costs no process
and works with no `PATH`.

The hostname lands in `config.yml` in cleartext at mode 0600 — which is
where glab would write it anyway on `glab auth login`, but worth knowing
if your instance URL comes from sops.

The wrapper also, before every `exec`:

- creates the config directory at mode `0700` when absent;
- repairs `config.yml` to `0600` when a stray umask left it looser, since
  glab hard-refuses anything else;
- fails when a credential file is missing or resolves empty, with a
  message naming the environment variable and the path it was read from
  (for example `GITLAB_TOKEN … from /run/secrets/gitlab-token`) — not the
  Nix option, which the wrapper does not know at runtime.

## `configDir` — project-local state

`glab.configDir` sets `GLAB_CONFIG_DIR`. It is a **literal path** — it is
shell-quoted into the wrapper, so nothing in it expands: no `$VAR`, no
`$(…)`, no `~`. Build the path in Nix, where the values already live.

| facet        | default                              | why                                                                                                                                           |
| ------------ | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| home-manager | `null` → glab's `~/.config/glab-cli` | a user-global install should own the user-global config                                                                                       |
| devenv       | `"${config.devenv.state}/glab-cli"`  | per-project hosts and aliases, so two projects on different instances cannot fight over one file, and the state is disposable with `.devenv/` |

For a custom location use `"${config.home.homeDirectory}/…"` under
home-manager or `"${config.devenv.state}/…"` under devenv, rather than a
shell string. `devenv.state` is available at evaluation time — verified
with `devenv eval devenv.state` — which is why the devenv default needs no
runtime expansion.

That difference is a `config` default, not a differing option
_declaration_ — the two facets' option trees stay identical, which
`module-glab-hm-devenv-option-parity` asserts.

## Why a wrapper rather than a managed `config.yml`

Two independent blockers, both measured against glab 1.110.0:

1. glab **refuses** a `config.yml` that is not mode `0600` — it exits
   with `has the permissions 664, but glab requires 600`. Home-manager
   files and store symlinks land `0444`/`0644`.
2. glab **writes** to that file (aliases, `last_seen_version`, auth
   bookkeeping), so a read-only store path breaks those paths.

Environment variables have neither problem and cover the whole key set:
`GetFromEnvWithSource` resolves every key through `EnvKeyEquivalence`,
and an env value beats the config file. Verified including
`GIT_PROTOCOL`, a key with no explicit override, which exercises the
uppercase fallback.

The wrapper is a `symlinkJoin` that replaces `bin/glab` only, so
upstream's manpages and shell completions are preserved.
