# Services and Instances

> **Last verified:** 2026-10-22 — split from DESIGN.md without changing the
> generic file, activation or service contracts.

## Services

`ai.services` is an `attrsOf serviceEntry`, default `{}`. Owners declare
`ai.<owner>.services` through `runtimeModule`; enabled owners forward
definitions with the same priorities as files. Disabled services still claim
their key and ports; disabled owners forward nothing. Names match
`^[a-z0-9][a-z0-9_-]*$` and become native unit or process keys verbatim.

| Field             | Type / default                                | Behavior                                                                                              |
| ----------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `command`         | Nonempty argv list of strings, required       | The launcher execs the escaped arguments.                                                             |
| `enable`          | Boolean, true                                 | Suppress native emission when false.                                                                  |
| `environment`     | `redact.types.environment`, `{}`              | Resolve and export through `redact.assign` at launch; a secret-named variable takes only a reference. |
| `files`           | Named rendered files, `{}`                    | Write `<key>.json` at launch; see below.                                                              |
| `ports`           | Named ports, `{}`                             | Register exclusive port claims.                                                                       |
| `restart`         | `never`, `always`, `on-failure`; `on-failure` | Map to the backend restart policy.                                                                    |
| `restartOnChange` | Absolute file paths, `[]`                     | Union with file references in environment values and file secrets, including concat parts.            |

`lib/services.nix` builds one strict `writeShellApplication`,
`ai-service-<key>`, for both backends. Native environment fields are never used.
A daemon reads store paths and secrets at start, never files written by the
files engine, so no unit depends on file activation. Each Linux Home Manager
unit orders after `network.target`. A service whose environment contains a
redact reference, whose rendered file has secrets, or that has a restart trigger
(a file it reads at start, such as a `restartOnChange` path) also has `Wants=`
and `After=` on every registered provider unit. sd-switch submits each start as
its own job, in unit-name order and without waiting, and `After=` orders only
against a job already queued, so with `After=` alone a reader that sorts before
its provider started first and read the previous secrets. `Wants=` puts the
provider's start into the reader's own transaction. So every start of a reader,
including each `Restart=` retry, re-runs a provider that is an inactive oneshot,
as sops-nix's is: a crash-looping reader decrypts again every `RestartSec`. It
is not `Requires=`: a provider restart, which sops-nix's own activation step
performs, restarts no reader. Its `WantedBy` is the targets those provider units
are wanted by, read from the evaluated `systemd.user.services`; a provider unit
not defined there contributes none, and with none left the service uses
`default.target`. Defined provider units wanted by different targets fail
evaluation: a reader pulls in every provider, so under the union of their
targets it would start one provider early, under the other's target. A plain
service uses `default.target`.

A `files.<key>` entry is a config file the launcher renders at each start, for a
daemon that reads its secrets from a file rather than its environment. Its
`content` is JSON text whose secrets are whole-string `{$NAME}` placeholders
(`lib/extracted/render.nix` produces them), so the text is safe in the store;
`secrets` maps each NAME to a redact reference; `variable` names the exported
path. The launcher clears inherited private secret slots before reading any
secret and clears resolved slots before exec. Secret readers and the daemon
never inherit those values; jq alone receives the needed slots in its
environment, never argv. The launcher atomically creates a 0700 directory at
`$XDG_RUNTIME_DIR/ai-service-<key>`, or, without XDG_RUNTIME_DIR,
`${TMPDIR:-/tmp}/ai-service-<uid>-<key>` (numeric user ID), the root read after
the declared environment is applied, so a declared `XDG_RUNTIME_DIR` or `TMPDIR`
picks it as it does for the daemon. An existing directory must be owned by the
current user and must not be a symlink; other inputs fail before chmod or
writes. The runtime root must already exist. jq replaces every placeholder
string with its secret as a JSON string, writes a 0600 temporary file, renames
it to `<file key>.json` and exports `variable` with that path. Content and
secrets are both known at evaluation, so the launcher refuses to build when a
placeholder has no secret, a secret has no placeholder, or a `variable` repeats
another file's or an environment name. Declared environment names and file
variables cannot start with `_ai_`, the launcher's private namespace. JSON is
the one format: YAML 1.2 readers take it as is. A daemon's own writes to the
file are lost at the next start.

A `redact.types.secretFile` value, in `environment` or a file's `secrets`, is
delivered as a path (`dev/fragments/redact/redact.md`, Secret files). The
launcher reads it into a private slot, writes it to a 0600 file in the runtime
directory through a same-directory rename, and exports the variable with that
path or has jq fill the placeholder with it. The file is `<VARIABLE>` for a
variable and `<file key>-<NAME>` for a placeholder; each must match the file-key
grammar `[A-Za-z0-9][A-Za-z0-9_.-]*` or the launcher refuses to build, and an
identifier holds no `.` or `-`, so neither collides with `<file key>.json`.
Every start rewrites them; a file the service no longer declares stays until the
runtime directory is cleared.

`lib/instances.nix` gives a tool with typed settings named instances:
`ai.<owner>.instances.<name>` with `enable`, `package`, `port`, `settings` and
`stateDir`, declared through one owner module per backend that differs only in
the default state root (`xdg.stateHome` on Home Manager, `devenv.state` on
devenv, so a repository's instance keeps its own logins). Each instance becomes
the service `<owner>-<name>`: its port is `ports.main`, its settings render to
`files.config`, and a strict run script creates `stateDir` (and the owner's
state subdirectories) 0700, enters it, runs the owner's `preStart` shell and
execs the package with the owner's per-instance arguments. The owner fixes the
settings an instance derives (the listen port, state paths) as ordinary
definitions, so a consumer value that disagrees fails evaluation. `select`
resolves an instance name to `http://127.0.0.1:<port>` or to the reason it
cannot: the name is missing or the instance is disabled. CLIProxyAPI and CPA
Manager Plus use it.

| Backend             | Lowering                                                                                                                                                                                                                                                         |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Home Manager Linux  | User unit: `After = network.target`; secret readers get `Wants` and `After` on provider units, and `WantedBy` the providers' defined targets, or `default.target`; `RestartSec = 5`, `StartLimitBurst = 5`, `StartLimitIntervalSec = 300`; `never` becomes `no`. |
| Home Manager Darwin | No unit; one warning per enabled service says the platform has no systemd user units.                                                                                                                                                                            |
| devenv              | Process `exec` is the same launcher; `restart.on` maps `on-failure` to `on_failure`; `restart.max = 4`, `restart.window = 300`; `watch.paths` is present only for nonempty triggers.                                                                             |
