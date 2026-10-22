# CPA Manager Plus typed settings

> **Last verified:** 2026-10-21 — 28 config.json keys and 32 environment
> variables give the settings type through `lib/extracted/options.nix`; the
> render loads through patched Manager Plus 1.14.7's
> `LoadWithoutCreatingDefault`; `config.defaultTheme` reaches the panel through
> `/usage-service/info`; `ai.cpa-manager-plus.instances` renders it at start and
> applies `config.adminKeyFile` through `reset-admin-key` on every start; key
> files are secret files; evaluation resolves the database from declared paths
> opened as written, and the run script unsets inherited admin-key and database
> variables.

`lib/default.nix` exports
`cpa-manager-plus.{settingsType, render, report, exclusions, sample}`. One
generated tree holds both surfaces: `config` is config.json and `environment`
the variables Manager Plus reads, from `extract/rules.nix`'s reconciled entries.
The shared rules are in `dev/fragments/extracted/typed-settings.md`.

## Keys and key files

The three annotated variables `CPA_MANAGEMENT_KEY`, `CPA_MANAGER_ADMIN_KEY` and
`CPA_MANAGER_DATA_KEY` carry a key itself and take a redact reference. The key
files `adminKeyFile`, `dataKeyFile` and `managementKeyFile`, and the
`*_KEY_FILE` variables that override them, are secret files
(`dev/fragments/redact/redact.md`, Secret files): Manager Plus gets the path of
a 0600 file the launcher writes, never a store path. `dataKeyPath` and
`CPA_MANAGER_DATA_KEY_PATH` stay plain paths: Manager Plus writes the key it
generates there. An instance takes its admin key from `config.adminKeyFile`
(Instances, Admin key). Every other variable is a string, as Manager Plus reads
it; `readBy` and `configKeys` are prose the type does not carry (`unread`).

`render settings` gives `{ content; secrets; environment; }`: config.json as
JSON text with each key file a `{$CPA_MANAGER_PLUS_<KEY>}` placeholder, and the
set variables, nulls dropped, ready for an option of type
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
`config.adminKeyFile`, a secret file, applies it on every start instead: the run
script reads the written file's path from the rendered config.json and calls
`cpa-manager-plus reset-admin-key --admin-key-file <file>` before it execs the
server. Without `--db-path` the command loads the same config and environment
the server does (its `resolveDBPath`), so it resets the database the server
opens. The command refuses a missing or empty database, so a start without one
is a first start. The run script tells the two apart by testing the database
evaluation resolves as `config.go` `LoadWithOptions` does:
`environment.USAGE_DB_PATH`, then `<environment.USAGE_DATA_DIR>/usage.sqlite`,
then `config.dbPath`, then `<config.dataDir>/usage.sqlite`,
`<stateDir>/usage.sqlite` by default. Each of these, when set, must be an
absolute path with no empty, `.` or `..` segment and no trailing whitespace, or
evaluation fails: Manager Plus cleans paths lexically (`filepath.Join`) and
trims Unicode whitespace (`strings.TrimSpace`), so only such a path is the one
it opens. The run script unsets `USAGE_DB_PATH` and `USAGE_DATA_DIR` unless the
instance declares them, so a value inherited from the user manager's environment
cannot move the database. A first start seeds the credential from the same file.
The launcher refuses an unreadable or empty reference, and the run script then
refuses a key that is blank to `strings.TrimSpace` (Unicode whitespace), where
Manager Plus would generate a key and log it. The trimmed key's scratch variable
is unset before assignment, so one exported by the environment reaches no child.
A failed reset fails the start. As with any secret reference, a `redact.file`
one is a restart trigger and orders the unit after the secret providers, so a
changed file restarts the instance onto the new key. Only the written file's
path reaches argv; the command prints no key.

`environment.CPA_MANAGER_ADMIN_KEY` and `CPA_MANAGER_ADMIN_KEY_FILE` fail an
assertion that names `config.adminKeyFile`. Either one takes precedence over
`adminKeyFile` at bootstrap (`readSecret`), which reads it on the first start
only, while every later start resets the credential from `adminKeyFile`: two
sources would seed one key and reset to another. The run script unsets both
before the reset and the server, so an inherited value cannot seed a first start
either. Without any of the three, the run script resets nothing, as before.

## Default theme

Manager Plus 1.14.7 has no server theme setting. The web store
(`apps/web/src/stores/useThemeStore.ts`) defaults `theme` to `auto`, which
follows `prefers-color-scheme`, and persists the user's pick in localStorage. A
browser that reports light to every page and clears site data on close, as
Firefox does with anti-fingerprinting on, always gets light.
`patches/default-theme.patch` adds `config.defaultTheme`. The package applies it
to `src` itself with `--fuzz=0`, so the build, the extractor and the checks all
read the patched tree; it changes neither `package-lock.json` nor `go.mod`, so
`npmDepsHash` and `vendorHash` are unchanged.

- `internal/config/config.go`: `auto` when unset, else `dark` or `white`, the
  web app's `Theme` values (`apps/web/src/types/common.ts`). Any other value
  fails `LoadWithOptions`. No environment variable sets it.
- `internal/service/setup/service.go`: `Info`, served unauthenticated at
  `/usage-service/info`, returns it. The panel already calls that endpoint
  before login (`LoginPage.tsx`, `ProtectedRoute.tsx`). Writing the value into
  `management.html` was rejected: `internal/service/panel/service.go` serves the
  embedded or `panelPath` bytes through `http.ServeContent`, so a rewrite would
  be a second channel with its own caching. The cost is one request at load, and
  a light first frame until the answer arrives.
- `apps/web`: `AppLifecycle.tsx` asks once at start unless the user has chosen,
  and `applyDefaultTheme` applies a valid answer. The store records `chosen`:
  `setTheme` (theme menu, login toggle) sets it and the default never does, so a
  changed `defaultTheme` still reaches a browser that never chose. Stored state
  moves to version 1. Any valid version 0 theme, `auto` included, counts as
  chosen: 1.14.7's `initializeTheme` wrote `auto` back on every load, so a
  picked `auto` and an untouched one are the same bytes and nothing can tell
  them apart. Treating all of them as chosen keeps a configured default from
  overwriting a pick; a browser with nothing stored, the case this key exists
  for, still takes the server default.

Unset, the server reports `auto` and the panel behaves as upstream, apart from
the one request. A panel served by plain CPA has no such endpoint and keeps its
theme. `module-service-instances-real-daemons` starts the patched server unset
and with `dark`, reads `defaultTheme` back from `/usage-service/info`, and finds
the reader in the served panel. `cpa-manager-plus-settings` runs the patch's
`TestLoadDefaultTheme`, and the web build runs its `useThemeStore.test.ts`.
