# ai-module: files, activation and services

`ai-module` is the base for every repository module, including non-AI programs.
The three layers are `ai.<owner>.files` → `ai.files` → `ai.activation`. Native
links branch from layer 2 to the backend's file primitive. They are the only
path from a repository module to Home Manager's or devenv's file and activation
sinks.

## Layout

| Path under `packages/ai-module/`                                | Responsibility                                                                                                                                        |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `checks.nix`, `checks/`                                         | The owner's checks; the entry imports its check modules.                                                                                              |
| `docs/contract.md`                                              | Short owner contract, loaded as a path-scoped fragment.                                                                                               |
| `docs/DESIGN.md`                                                | Layer design, activation graph, guards and known limitations.                                                                                         |
| `docs/files-engine.md`                                          | File schema, refusal messages, codec rules, state, legacy import and transition tables.                                                               |
| `lib/activation.nix`                                            | Activation entry type, point resolution and graph validation.                                                                                         |
| `lib/default.nix`                                               | Exports the owner library under `aiModule`: file types/normalization and the runtime registration helper.                                             |
| `lib/files/default.nix`                                         | File entry type, normalization and plan validation.                                                                                                   |
| `lib/files/backend.nix`                                         | What both backend modules derive from `ai.files`: the plan, native link map, engine invocation and generated `files-prune`/`files-apply` entries.     |
| `lib/files/engine.py`, `lib/files/files_codecs.py`              | The runtime engine and its codecs.                                                                                                                    |
| `lib/files/guard.py`, `lib/files/observe.py`                    | Devenv's native-link guard and its never-failing observer.                                                                                            |
| `lib/instances.nix`                                             | The owner module for named tool instances (`ai.<owner>.instances`), each lowered to one service, and the loopback selection of an instance by name.   |
| `lib/lower-devenv.nix`, `lib/lower-hm.nix`                      | One lowering function per backend; each receives the complete activation graph, generated entries included.                                           |
| `lib/runtime.nix`                                               | The layer-1 helper (`runtimeModule`).                                                                                                                 |
| `lib/secrets.nix`                                               | Resolves secret providers and legacy secret nodes for both backend lowerings.                                                                         |
| `lib/services.nix`                                              | The service entry type, the generic launcher and the backend lowerings.                                                                               |
| `modules/common.nix`                                            | Declares the root options and computes `ai.deliveredPaths`; shared by both backends.                                                                  |
| `modules/devenv/default.nix`, `modules/homeManager/default.nix` | Generate the backend's engine entries (and devenv's guard and observer), write the native file map and call the corresponding lowering function once. |

ai-module imports nothing from `lib/ai/`. `lib/facets.nix` discovers owner
libraries, backend module directories and `checks.nix`; no central owner list
exists (`docs/repository-layout.md`). An empty configuration remains usable: the
base stays installed and its empty plan can drain earlier ownership. Removing
the base module itself cannot drain anything.

## Options and composition

### Layer 1: runtime file overrides

`runtimeModule { name; enabled; shared ? []; }` declares `ai.<name>.files`, an
`attrsOf fileEntry`, default `{}`. `name` is the stable runtime identifier;
`enabled` is the owning module's existing boolean. These are constructor inputs,
not another runtime enable option. The helper also declares
`ai.<name>.activation` (layer 3) and the internal `ai.<name>.legacyLedgers`
(`listOf { codec = enum ["dir" "json"]; ledger; path; }`), both forwarded
outside the `enabled` gate into `ai.activation` and the internal root
`ai.legacyLedgers`, so a disabled owner still runs its `runWhenDisabled`
commands and drains its old ledgers. Each forwarded command gets
`enable = mkDefault enabled` at the forwarded priority; a producer that sets
`enable` overrides it. Keys listed in `shared` forward without a claim in
`ai.claims.path`, which leaves their composer the single claimant. Runtime
factories and non-AI owners import the helper. Semble exposes it on both
backends; glab and mcp-services expose it on Home Manager; beads, git and
git-branchless expose it on devenv. These lifecycle namespaces remain visible in
option docs, with explicit backend presence checks outside shared API parity.
Shared skills, rules and other surfaces produce entries here; their rendering
stays above this layer.

Keys are **backend-root-relative final paths**, just like layer 2. There is no
implicit prefix added by forwarding. A runtime producer computes its configured
prefix once, before declaring paths; user overrides use the same final path.

| Runtime | Typical producer prefixes; exceptions remain explicit                                  |
| ------- | -------------------------------------------------------------------------------------- |
| Claude  | `.claude/`; `.claude.json` and project `.mcp.json` are separate paths.                 |
| Codex   | `.codex/`; skills use `.agents/skills/`; project context may be root `AGENTS.md`.      |
| Copilot | `.github/` for project instructions.                                                   |
| Kimchi  | Configured harness, configuration and MCP directories; project `.kimchi/`.             |
| Kiro    | Configured settings and `.kiro/` directories; project context may be root `AGENTS.md`. |

Claude's `.claude.json` is Home Manager only. Its producer disables the staged
`rw` entry when the unpin map is empty, leaving the engine to retire old keys
without adopting an unrelated document. The mode command runs while Claude is
enabled, including with an empty map, after `materialized`. Engine state is
saved atomically while files remain owned and deleted otherwise; repeat
activation preserves ownership contents rather than the state file's timestamp.

These examples are not hard-coded prefix policy in the base. A producer must
make an absolute home configuration path relative to `home.homeDirectory`; paths
outside the active root are refused by the file contract.

| Definition              | Priority and enable behavior                                                                                                                                                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Generated surface       | Default text/source and method use `mkDefault`; structured defaults apply per leaf so a consumer leaf preserves siblings. A deliberately whole-entry default remains whole-entry, as with compiled context.                                                                            |
| Runtime override        | Ordinary definitions override defaults; `mkForce` works normally. Select the winning content alternative before evaluating a discarded source. Disabled entries require no content.                                                                                                    |
| Layer 1 → 2             | Forward surviving module definitions with their priority wrappers, not a merged value reintroduced at ordinary priority. Reuse the file entry type. Forward nothing from a disabled runtime; do not publish a false tombstone that disables another producer.                          |
| Direct layer-2 override | Uses ordinary Nix priorities against forwarded definitions. Equal-priority incompatible scalar/content alternatives fail; equal structured leaves merge. There is no hidden runtime precedence over `ai.files`.                                                                        |
| Shared destination      | Distinct live runtime owners cannot independently claim one path. Shared `AGENTS.md` composition/arbitration stays upstream and emits exactly one layer-2 entry, retaining agreeing claims, replacement and suppression semantics. Ordinary cross-runtime collisions name both owners. |

Forwarding uses the module system's alias primitive
`lib.modules.mkAliasAndWrapDefsWithPriority lib.id`, under `lib.mkIf enabled`.
Priority wrappers inside the map (per entry, per field, per value leaf) travel
with the definitions. The wrapper re-applies the runtime option's own highest
priority, so an option-wide `mkDefault` map still loses to an ordinary layer-2
definition; plain `lib.mkAliasDefinitions` strips it and turns that case into an
equal-priority conflict. Forwarded definitions report the helper module's
location, not the producer's; no fixture needs the producer location, so no
custom forwarder exists. The helper sets `_file` to its own path, so every
forwarded root definition reports `lib/runtime.nix`, which the root-definition
guard exempts (see [Repository guards](#repository-guards)). Content selection
examines only the highest-priority defined alternative, so a discarded source is
never evaluated.

The helper also records each declared key, including one with `enable = false`,
in the internal `ai.claims.path.<path>` list; a disabled entry would otherwise
override another runtime's entry unseen. The claims registry fails with
`ai.claims.path.<path>: claimed by <a> and <b>` when a path has two runtime
claims. Overlapping (ancestor/descendant) paths from distinct runtimes fail
through the expanded-destination overlap check, which names the paths, not the
owners.

### Layer 2: generic files

`ai.files` is `attrsOf fileEntry`, default `{}`. It serves runtimes and ordinary
program modules equally. `fileEntry` is the files engine schema: content
alternatives `run/source/text/value` default null; `enable` defaults true;
`executable` and `mode` default null; `format` defaults `raw`; `method` defaults
`symlink`; `recursive` defaults false. Two internal fields are added.
`_contentPrio` is read-only: the strongest priority of any `content` definition,
read without evaluating one, so a runtime's generated tree can leave out a
whole-content default a consumer replaced. `requires` is a list of derivations,
default `[]`. The engine appends their string context to each delivered leaf
after the recursive walk, so the backends build them before delivery and
evaluation never reads them; a runtime's generated files require its generated
tree, whose guards, surface checks and byte limits then gate a recursive source
or a value that does not point into it. Types, priority arbitration and all
refused combinations remain in the engine document. A backend-specific method
still requires both `devenv` and `hm` fields.

Normalize the complete map once, after merging and runtime gating, then check
expanded destination collisions. Symlinks lower to `home.file` or devenv
`files`; `ro` and `rw` always use the engine on both backends. Native devenv
copy cannot retire real files (`dev/fragments/devenv/files-internals.md`). There
is no native-copy escape hatch for an entry owned by this map: a native
`files.<path>.copyMode` other than `symlink` on any enabled normalized
destination, including `ro` and `rw`, fails evaluation with that path named.

`ai.deliveredPaths` is public and read-only: every enabled `ai.files` key, a
recursive key as `<key>/**`. The devenv module appends it to
`treefmt.config.settings.global.excludes` when the shell has treefmt enabled, so
repository formatting never rewrites a delivered file; another consumer can read
the same list for its own formatter.

One stable namespace, `ai`, owns the unified copy plan. The engine state is HM
`${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/files/ai.json` and
devenv `$DEVENV_STATE/nix-agentic-tools/files/ai.json`. Roots are `$HOME` and
`$DEVENV_ROOT`, respectively. Neither namespace nor engine task names are
per-file options. The same root must not be activated concurrently through two
independent backend states. The engine's state-directory move and legacy import
are described in [files-engine.md](files-engine.md#legacy-ownership-import).

Layer 2 generates `files-prune` internally on every activation, including with
an empty map, so removing the last file still drains it. For an empty map only,
its command exits before Python starts when neither the engine state file nor
any listed legacy ledger exists; the engine deletes both once nothing is owned,
so a consumer that declares no files pays one shell test per activation. A
nonempty map always starts the engine in prune, whose parent check refuses a
symlinked parent before HM's native linking. `files-apply` is generated only for
a nonempty plan. Backend lowering validates and lowers their union with the
caller's `ai.activation` graph; the generated entries are not option definitions
that a whole-option priority override can remove. A caller key colliding with a
reserved name fails evaluation, whether or not that entry is emitted: both
backends reserve `files-apply` and `files-prune`, and devenv also reserves
`files-guard`, `files-inspect` and `files-snapshot`. Generated entries have
`runWhenDisabled = true`. Prune has `after = []; before = ["linkCheck"];`; apply
has `after = ["files"]` plus `"secrets"` when any enabled entry uses
`content.run`. Apply also depends directly on prune and, when emitted, the
devenv native guard; devenv refuses a dependency on an absent task. The internal
`materialized` point depends on apply. These reserved entries and their names
cannot be overridden by callers. Content renderers execute only in apply.

The devenv guard is a third ordinary generated activation entry, between
`linkCheck` and `files`, emitted only when the plan has native links. It checks
the desired native links after cleanup and pre-link commands: accept the desired
store link, remove a stale store link, refuse regular files, special files and
non-store links, and refuse symlinked parents. Only desired native destinations
are examined; there is no native-link state in the engine. Native backends
retract their own removed links.

Devenv also generates the observer pair, `files-snapshot` and `files-inspect`,
which never deletes and never fails the shell. Both entries remain emitted with
an empty plan: inspection must still report retained paths from its ledger, and
snapshot precedes the always-present cleanup task. `files-snapshot` clears both
abstract defaults and runs before `devenv:files:cleanup`: it copies the owned
paths of devenv's previous link list into
`$DEVENV_STATE/ai-delivery-observed.json`. `files-inspect` runs after
`materialized` with devenv `showOutput`, because devenv hides a passing task's
output. It warns for an owned link that is absent or replaced by a file, a
directory or a stale link, and for a remembered path no longer delivered where
the store link it delivered is still on disk, which cleanup should have removed.
A remembered path that is absent, or holds anything else, is the user's and is
forgotten silently: devenv only ever wrote that store link there. Ownership is
the normalized plan, each path named by its `ai.claims.path` claim or else
`ai.files`. Native links come from the backend file map.

### Layer 3: generic activation

`ai.activation` is `attrsOf activationEntry`, default `{}`. Its key is the
logical name; use a nonempty identifier without slashes. A command can exist
without any file. Entries must remain declared outside their owner's enable gate
when disabled execution is required.

| Entry field       | Type / default                                                   | Need                                                                                                   |
| ----------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `after`           | `listOf point`, `["files"]`                                      | Ordinary commands run after native links; secret commands add `secrets`; observers use `materialized`. |
| `afterNodes`      | Submodule `{ devenv = listOf str; hm = listOf str; }`, both `[]` | Existing provider/task dependencies, including hook installation.                                      |
| `before`          | `listOf point`, `["shell"]`                                      | Finish before use; migrations explicitly select `linkCheck` and clear the default `after`.             |
| `beforeNodes`     | Same type/default as `afterNodes`                                | Observation before native cleanup; Git initialization before existing native tasks.                    |
| `command`         | `lines`, required, nonempty                                      | Strict Bash body for finite activation work, including daemon pinning.                                 |
| `enable`          | `bool`, `true`                                                   | Owner supplies its enable condition. Execute when this is true OR `runWhenDisabled` is true.           |
| `name`            | Submodule `{ devenv = nullOr str; hm = nullOr str; }`, both null | Override the derived native identity only for an existing external dependency, e.g. `git:config`.      |
| `runWhenDisabled` | `bool`, `false`                                                  | Keep retirement and daemon release running when the owner turns off.                                   |

`point` is the enum `["files" "linkCheck" "materialized" "secrets" "shell"]`.
Native names default to `ai-<key>` on HM and `ai:<key>` on devenv. A resolved
devenv name must have two or more nonempty colon-separated parts containing only
ASCII letters, digits, underscores and hyphens. Invalid names fail with the
entry named. Duplicate resolved names, reserved names, self-edges and cycles
also fail with the entry names. Native node strings are trusted integration
edges, not guessed optional tasks; callers add conditional edges only when their
provider exists.

`ai.activationOrder.secretProviders` is an `attrsOf` submodule, default `{}`.
Each provider declares `nodes` (`listOf str`, default `[]`) that mark when its
secrets are readable and `unit` (`nullOr str`, default `null`) for its Home
Manager user unit; devenv ignores units. The Home Manager lowering adds a
built-in `sops-nix` provider with node `sops-nix` and unit `sops-nix.service`
unless the consumer declares that key, which replaces the built-in whole. A
module in this repo may not define root `ai.*` defaults.
`ai.activationOrder.secretNodes` remains the node-only shorthand (`listOf str`,
default `[]`); its nodes join the providers' nodes in the `secrets` point for
commands and `content.run`. Devenv has no built-in provider.

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

### Start limit

A daemon that fails within about 55 s of each start ends failed, so alerts on a
failed unit fire; an instant crash loop ends failed after 25 s. Restarts are
`RestartSec = 5` apart, and systemd's default `StartLimitIntervalSec=10s` and
`StartLimitBurst=5` can never trip: the sixth start of an instant crash loop
lands 5 x 5 = 25 s after the first, and a 10 s window holds at most three
starts. The unit then stays in `activating (auto-restart)` for good.
`restartPolicy` in `lib/services.nix` is the one definition: five starts in 300
s. A daemon that lives longer than about 55 s per start (5 x (55 + 5) = 300 s)
never trips it. The trade-off: a start-time dependency absent for longer than
about 25 s, such as a keyring or the network at login, is now terminal where the
unit used to retry for good. Recover with `systemctl --user reset-failed <unit>`
and a start; the same command clears a trip that would refuse a fix-and-switch
inside the 300 s interval, because the start limit also applies to manual starts
and survives `daemon-reload`. The limit applies to every `restart` value,
including `always`, and to every service; no consumer needs to tune it, so there
is no option. Add one when a named consumer does.

Devenv's native supervisor applies the same limit as `restart.max = 4` and
`restart.window = 300`: it counts restarts after the first start in a sliding
window, so five starts in 300 s.

#### Recipe: a desktop notification when a service fails

This is a personal recipe, not a module default and not an option. Home Manager
only: devenv has no systemd, and its supervisor has no `OnFailure=`. A Home
Manager `ai.services.<name>` entry becomes the user unit `<name>.service`, and
`systemd.user.services.<name>` is an ordinary Home Manager attribute that merges
with the generated definition, so a consumer adds `Unit.OnFailure` without
touching the module. systemd then requests the templated unit on failure, with
the failing unit's name as the instance `%i`.

```nix
{pkgs, ...}: {
  systemd.user.services = {
    # Replace cliproxyapi with the ai.services key.
    cliproxyapi.Unit.OnFailure = ["notify-failure@%n.service"];

    "notify-failure@" = {
      Service = {
        ExecStart = "${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name=systemd 'Service failed' '%i failed; see journalctl --user -u %i'";
        Type = "oneshot";
      };
      Unit.Description = "Notify that %i failed";
    };
  };
}
```

`notify-send` needs a reachable user session bus and a running desktop
notification server; a headless session may have neither, and the notification
is lost. With the default `RestartMode=normal`, each failure before an automatic
restart passes through the failed state and triggers `OnFailure=`, as does the
terminal start-limit failure. It does not fire for a stop. A consumer who wants
a notification only when systemd gives up can also set
`Service.RestartMode = "direct"` on that unit (systemd 254+), which skips
`OnFailure=` for failures followed by an automatic restart
(`systemd.service(5)`, `RestartMode=`). After the unit gives up, recover with
`systemctl --user reset-failed <unit>` as above.

Home Manager Linux reserves `services-reconcile`. The Home Manager launcher of a
service with triggers hashes every trigger path and its bytes before it reads
any secret, so a file replaced during a start leaves the stamp older than the
daemon, never newer; a missing trigger fails the start. Immediately before exec
it writes the digest and its `INVOCATION_ID` to
`$XDG_RUNTIME_DIR/ai-service-<key>.stamp`. The devenv launcher writes no stamp.

One generated activation entry runs after `files`, `secrets` and
`reloadSystemd`, so it sees the units sd-switch started and the provider run
sd-switch caused, and calls `systemd.user.systemctlPath`. Activation fails when
a loaded provider unit's last `Result` is not `success`, or a reader is `failed`
or in `auto-restart`. The entry waits for each active reader's running
invocation to stamp, then one `try-restart` restarts every reader whose stamp
differs from the trigger files now or that did not stamp in time; each must come
back with a matching stamp, or activation fails naming it. Each of the two
passes shares one 90-second deadline, room for a secret command that waits on a
person, so the entry waits at most 180 seconds, under the 5-minute start timeout
of Home Manager's NixOS unit. A match proves the reader read every secret and
reached exec, not that it stays up; a reader that then crash-loops is refused by
the next activation. A stopped reader stays stopped, although sd-switch itself
starts a stopped unit an active target wants. A no-op activation, and a re-key
that leaves the decrypted bytes alone, restart nothing.

The entry acts only while the user manager reports `running` or `degraded`, the
test Home Manager's own reload uses. `starting` and `stopping` skip with a
message, since `user@<uid>.service` turns `active` before its manager finishes
starting. For any other answer, or none, it fails activation only when the
system manager reports `user@<uid>.service` `active`; every other state skips
with a message naming it, including a failed query on a host whose init is not
systemd. The two backends differ: Home Manager compares content after each
switch, devenv's `watch.paths` restarts live on any change and accepts
directories.

Exclusive resources share `ai.claims.<group>.<key>`, a hidden registry of owner
lists validated once in `modules/common.nix`. Runtime helpers register
non-shared paths in `path`, service names in `service` and decimal ports in
`port`. Other resources use `ai.<owner>.claims.<group> = [keys]`; `ai.proxy`
claims each instance-routed runtime's client key in `proxy-client-key`. Port
owners are `<owner>:<service>.ports.<name>`. A list with more than one owner
fails with `ai.claims.<group>.<key>: claimed by <a> and <b>`, sorted by owner.
Adding a resource group needs no new validation code; owners register resources
and never assert uniqueness. The internal shared owner accepts scoped service
claims for proxies (`proxy:root`, `proxy:<runtime>`), so identical proxy
declarations fail the shared ownership assertion at the native assertion
boundary.

## Backend graph and execution

Each backend lowering function maps the same graph once. HM uses
`lib.hm.dag.entryBetween before after`; devenv emits `{ after; before; exec; }`
tasks. Native file sinks and activation sinks are single literal attributes
whose values contain the computed maps; do not create option-derived module
fragments while collecting definitions (`packages/ai-module/lib/lower-hm.nix`).

`A → B` means B depends on A. Every abstract point resolves to the following
node(s) for both `before` and `after` references:

| Point          | HM node(s)                                                                | devenv node(s)                             |
| -------------- | ------------------------------------------------------------------------- | ------------------------------------------ |
| `files`        | `linkGeneration`                                                          | Internal `ai:files-linked`.                |
| `linkCheck`    | `checkLinkTargets`                                                        | Internal `ai:link-check`.                  |
| `materialized` | Internal `ai-files-ready`.                                                | Internal `ai:files-ready`.                 |
| `secrets`      | Resolved provider nodes and `secretNodes`, including built-in `sops-nix`. | Resolved provider nodes and `secretNodes`. |
| `shell`        | Internal completion node `ai-ready`.                                      | `devenv:enterShell`.                       |

The internal point nodes are empty DAG/task entries, not caller commands. HM
adds `linkGeneration → ai-files-ready → ai-ready`; apply also precedes
`ai-files-ready`. HM has no shell-entry phase: `shell` means the completion of
this activation graph. Ordinary activation entries still run during HM switch.

Devenv adds this exact chain when the **final native `config.files`** is
nonempty:

```text
devenv:files:cleanup → ai:link-check → ai:files-guard
  → devenv:files → ai:files-linked → ai:files-apply
  → ai:files-ready → devenv:enterShell
```

With no native file task, replace `guard → devenv:files → files-linked` with
`guard → files-linked`. Without a guard, `link-check` precedes the next node of
the chain directly. Retain direct `prune → apply` and `guard → apply` edges
whenever both ends are emitted, and `provider → apply` edges for run content.
Prune and every command with `before = ["linkCheck"]` precede `ai:link-check`,
so guard runs after all such commands. They also follow `devenv:files:cleanup`
unless explicitly positioned before cleanup with a native edge. Cleanup exists
even at zero files; never manufacture a missing `devenv:files` task. A
declaration requiring before link-check must clear `after = ["files"]`;
contradictory ordering is an error.

The same HM chain is prune/pre-link commands → `checkLinkTargets` →
`linkGeneration` → apply → `ai-files-ready` → `ai-ready`. Secret providers also
precede apply when required. A command such as Claude's conditional mode repair
can select `after = ["materialized"]` to run after owned writes.

Generated commands use a scoped subshell, full strict mode, and absolute store
paths for external tools. HM invokes the resulting script through `run`, so a
dry run cannot mutate files or execute a secret renderer. Devenv tasks execute
the script directly. The engine gets `FILES_BASH`; `content.run` receives the
backend environment and any provider environment. Existing renderer-specific
root exports stay inside the renderer body. No activation entry exports into a
later entry's shell. Devenv failure verification belongs to the backend check
path as well: execute failing tasks in tests and assert failure; shell-entry
warnings alone are not evidence of successful materialization.

## Engine contract

The [files engine contract](files-engine.md) holds the file schema, codecs,
backup/adoption rules, path refusal, recursive leaves, method/format switch
semantics, state versions and legacy import. In particular, `rw` cannot
surrender native keys to a whole-file owner. There is no rollback, pending
journal or crash recovery; mutation and state commit are per file.

## Repository guards

Two checks keep owners on the layers:

- **Root `ai.*` definitions.** `rootPoolViolations` in
  `checks/module-provenance/helpers.nix` reports any repository file that
  defines a root `ai.*` option outside the file declaring it. The one exemption
  is `packages/ai-module/lib/runtime.nix` for `activation`, `files`, `claims`,
  `legacyLedgers` and `services`; any other root option it defined would still
  be reported.
- **Direct native sinks.** `ai-module-no-direct-sink-writes`
  (`packages/ai-module/checks/sink-guard.nix`) scans `lib/**/*.nix` and
  `packages/*/{lib,modules}/**/*.nix`, excluding `packages/ai-module/`, for
  writes of `home.file`, `home.activation`, `files`, `tasks`, `enterTest`,
  `systemd.user`, `launchd.agents` or `processes` at the start of a line, and
  for a nested `home = {`, and fails with "route direct native sink writes
  through ai.<owner>.files or ai.<owner>.activation". Exceptions are exact
  path/line-text pairs, never whole files: option declarations in
  `lib/options-doc.nix` and the testing harnesses, file-plan data in
  `generatedFiles.nix`, the shared composer and `module-harness.nix`, Semble's
  model filename list, and Beads' manual tasks. Negative fixtures put each of
  the five sink forms in `lib/` and in each of the six non-AI owner module
  trees.

## Decisions

- **Copilot agents.** github.com code review never reads `.github/agents`, so
  Copilot declares `agents` an unsupported surface (`backends = []`) and warns.
  Its old ledger stays in `legacyLedgers`, so existing files retire.
- **Native copy is refused.** Native devenv copy cannot drain, so owned copies
  use `method = "ro"` and a native `copyMode` override fails evaluation.
- **The engine never tracks native links.** Native cleanup plus the guarded
  desired-link preparation above covers them. This is separate from legacy copy
  import.
- **Out of scope.** Manual tasks and apps (bootstrap, checkpoint, diagnostics,
  status), oneshot and file-watch units, runtime I/O and CI keep their own
  lifecycles. Hook configuration reaches layer 1; wrappers stay native package
  installation. No seed method, formatting framework or renderer framework
  exists in this layer.

## Known limitations

- **Consumer overrides land verbatim.** A consumer's layer-1 or layer-2 content
  replacement is not treefmt-formatted, not run through `ai.guards`, not checked
  by `ai.<runtime>.checks.<surface>` and not byte-limited: only staged entries
  enter the generated tree (`lib/ai/app/generatedFiles.nix`).
- **Structured values are codec output.** A `content.value` document is
  delivered as the engine codec's rendering (`builtins.toJSON` for JSON), not
  formatter output; it enters the generated tree only for guards, checks and
  limits.
- **No compatibility aliases.** `methodFor`, `content.enable`, `facts`,
  `lib.ai.own` and `lib.ai.deliveryMethod` are not options; setting one fails
  evaluation.
- **Native identities are derived.** Commands get `ai-<key>` (HM) and `ai:<key>`
  (devenv); only an explicit `name` keeps a literal one, as `git:config` does.
  External ordering must name the derived node.
- **Legacy import trusts the disk.** A `json` ledger, or a `dir` ledger line
  without a 64-hex witness, imports the on-disk bytes as the baseline, so a
  local edit made before the import is not backed up on the first owned change.
- **Imported `json` documents outlive retirement.** They import with
  `created = false`, so a fully retired document stays on disk, unowned.
- **Equal-priority conflicts name the helper.** Divergent equal-priority
  definitions of a forwarded or shared key fail with module-system conflict text
  that lists `lib/runtime.nix` for each forwarded definition, not the owners.
- **Non-AI owners get option groups.** `ai.beads`, `ai.git`,
  `ai.git-branchless`, `ai.glab`, `ai.mcp-services` and `ai.semble` appear in
  the public option tree as `ai.<owner>.{activation,files,services}`.
- **Replacing a generated `value` document needs `mkForce`.** Its leaves are
  defaults but the document itself is not, so a consumer `text` or `source` for
  that path ties at priority 100 and fails with `content alternatives tie`.
- **A reshaped `json` leaf blocks retirement.** When a native writer turns a
  recorded leaf into a non-empty object, retiring it fails with
  `native descendants prevent retirement`; the import does not skip such
  addresses.

## Checks

Matrix lists are backend `["devenv" "hm"]`, format
`["json" "markdown" "raw" "toml" "yaml"]`, method `["ro" "rw" "symlink"]`, shape
`["executable" "recursive" "run" "source" "text" "value"]`: 180 cells, generated
rather than enumerated (`ai-module-matrix`). Recursive sources contain nested
directories and executable leaves; non-recursive directory links get a separate
fixture. Refusals use independent expected outcomes, not the implementation's
validation result as the expected value. Invalid cells cover keyless `rw`,
keyless values, recursive `rw`, and run/symlink; separate negative cases cover
content ties, paths, modes and overlapping destinations. Evaluation-only tests
read structured plans/graphs; runtime tests execute the emitted activation
scripts with native backend fixtures, then assert bytes, links, modes, backups
and state. A successful evaluation is not a claim that runtime checks passed.

`ai-module-transitions` lists scenarios as declaration steps and executes every
generated body on a fresh root in native order: HM runs prune, then a stand-in
for `linkGeneration` (remove dropped links, link the rest), then apply; devenv
runs a stand-in for `devenv:files:cleanup`, prune, guard, a stand-in for
`devenv:files`, then apply. Each step's plan is asserted on disk and in state,
so a switch both lands and retracts the previous materialization. Every step
also asserts its exact set of new backups: none, unless a local edit or a
program-written `rw` key precedes an owned change, which must back up those
bytes. The generated phases come from the evaluated entries, and the runner
refuses a phase it would not execute. Scenarios: the six directed method
switches; `ro` and `rw` format switches json → toml → yaml, with a
program-written `rw` key; retirement; backup of an edited copy; silent adoption
of an identical full image (bytes and mode); and execute bits of a recursive
leaf under `ro` and `symlink`. The stand-in link step refuses a real file, as
both native steps do; the native steps themselves are not executed.
