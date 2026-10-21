# CPA Manager Plus typed settings

> **Last verified:** 2026-10-20 — 27 config.json keys and 32 environment
> variables give the settings type through `lib/extracted/options.nix`; the
> render loads through Manager Plus 1.14.7's `LoadWithoutCreatingDefault`;
> `ai.cpa-manager-plus.instances` renders it at start and applies
> `config.adminKeyFile` through `reset-admin-key` on every start, against the
> database the server resolves at run time, with inherited admin-key variables
> unset.

`lib/default.nix` exports
`cpa-manager-plus.{settingsType, render, report, exclusions, sample}`. One
generated tree holds both surfaces: `config` is config.json and `environment`
the variables Manager Plus reads, from `extract/rules.nix`'s reconciled entries.
The shared rules are in `dev/fragments/extracted/typed-settings.md`.

## Secrets live in the environment

config.json names key files, never keys, so its render lifts nothing. The keys
are the three annotated variables `CPA_MANAGEMENT_KEY`, `CPA_MANAGER_ADMIN_KEY`
and `CPA_MANAGER_DATA_KEY`, typed as redact references. An instance takes its
admin key from `config.adminKeyFile` instead (Instances, Admin key). Every other
variable is a string, as Manager Plus reads it; `readBy` and `configKeys` are
prose the type does not carry (`unread`).

`render settings` gives `{ content; secrets; environment; }`: config.json as
JSON text, and the set variables, nulls dropped, ready for an option of type
`redact.types.environment`. `CPA_MANAGER_CONFIG` is excluded: the launcher
points it at the rendered config.json.

## Check

`cpa-manager-plus-settings` evaluates `sample` through `settingsType`, passes
the rendered environment through `redact.types.environment`, and runs
`checks/settings_test.go` in `internal/config`. It decodes the config into
`fileConfig` with unknown keys refused (the loader ignores them), sets the
environment with a dummy for each reference, and calls
`LoadWithoutCreatingDefault`; `CPA_MANAGEMENT_KEY` must reach the loaded config.
The one override, `USAGE_ARCHIVE_RETENTION_DAYS = "30"`, is a variable the
loader parses as an integer and refuses otherwise.

## Instances

`ai.cpa-manager-plus.instances.<name>` (`modules/instances.nix`, through
`packages/ai-module/lib/instances.nix`) runs Manager Plus as the service
`cpa-manager-plus-<name>`. `port` (18317) fixes `config.httpAddr` to
`127.0.0.1:<port>`, where the native default binds every interface; `stateDir`
fixes `config.dataDir`, which Manager Plus otherwise resolves next to the
rendered config in the launcher's runtime directory. The rendered environment
becomes the service's. `upstream` names an `ai.cliproxyapi.instances` entry and
defaults `config.cpaUpstreamUrl` to its loopback origin and `CPA_MANAGEMENT_KEY`
to its `management.secret-key` reference; a missing or disabled one fails an
assertion.

### Admin key

Manager Plus reads its admin key only while its database holds no admin
credential (`internal/service/bootstrap/service.go`, `ensureAdminCredential`);
after the first start a changed key is ignored. An instance with
`config.adminKeyFile`, an absolute path, applies it on every start instead: the
run script calls `cpa-manager-plus reset-admin-key --admin-key-file <file>`
before it execs the server. Without `--db-path` the command loads the same
config and environment the server does (its `resolveDBPath`), so it resets the
database the server opens. The command refuses a missing or empty database, so a
start without one is a first start. The run script tells the two apart by
resolving the database as `config.go` `LoadWithOptions` does, at run time:
`USAGE_DB_PATH`, then `$USAGE_DATA_DIR/usage.sqlite`, set in the environment or
inherited from it, then config.json's `dbPath`, then `<dataDir>/usage.sqlite`,
`<stateDir>/usage.sqlite` by default. A first start seeds the credential from
the same file, and the run script fails first if that file is unreadable or
blank, where Manager Plus would generate a key and log it. A failed reset fails
the start. The path is a restart trigger (`restartOnChange`), so a changed file
restarts the instance onto the new key, and on Linux Home Manager the unit
orders after the secret providers, as one reading a redact reference does. Only
the path reaches argv and the store; the command prints no key.

`environment.CPA_MANAGER_ADMIN_KEY` and `CPA_MANAGER_ADMIN_KEY_FILE` fail an
assertion that names `config.adminKeyFile`. Either one takes precedence over
`adminKeyFile` (`readSecret`) and would be read on the first start only, and the
plain key could reach `reset-admin-key` only through argv or a copy on disk. The
run script unsets both before the reset and the server, so a value inherited
from the user manager's environment cannot seed a first start either. Without
any of the three, the run script resets nothing, as before.
