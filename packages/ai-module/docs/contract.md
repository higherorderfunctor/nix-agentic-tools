## ai-module Files, Activation and Services Contract

> **Last verified:** 2026-10-22 — secret providers supply activation nodes and
> Home Manager service unit ordering; repository modules reach Home Manager and
> devenv file and activation sinks only through ai-module's three layers, apart
> from the exact exemptions in `packages/ai-module/checks/sink-guard.nix`; a
> service's `files` and secret files render at start in checked private runtime
> directories, chosen after the declared environment applies, with
> user-qualified fallbacks; private secret slots are cleared before reads and
> exec, public variables reserve `_ai_`, tool instances use `lib/instances.nix`,
> a restart trigger alone makes a unit a secret reader, and every service has a
> start limit so a crash loop ends failed. CPA client keys are instance-owned
> rather than runtime resource claims.

The detail lives in `packages/ai-module/docs/DESIGN.md` (layers, graph, guards,
known limitations) and `packages/ai-module/docs/files-engine.md` (schema,
refusals, state, legacy import, transitions). This is the part to hold while
editing ai-module or any owner that writes through it.

### Three layers

| Layer | Option                                           | Written by                                                                                                                                      |
| ----- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | `ai.<owner>.files`                               | The owner, through `packages/ai-module/lib/runtime.nix`                                                                                         |
| 2     | `ai.files` (claims in internal `ai.claims.path`) | The layer-1 helper's forwarding; a consumer may override                                                                                        |
| 3     | `ai.activation`                                  | The helper's forwarding of the owner's `ai.<owner>.activation`; generated engine entries are added at lowering, they are not option definitions |

Keys are final backend-root-relative paths (`$HOME` or `$DEVENV_ROOT`); nothing
adds a prefix. A runtime factory stages `ai.<runtime>._generatedFiles` and lets
`lib/ai/app/generatedFiles.nix` turn it into layer 1 over one formatted, guarded
tree; a non-AI owner writes layer 1 directly.

### Owner rule

- Owners write `ai.<owner>.files`, `ai.<owner>.activation` and
  `ai.<owner>.services`, plus `ai.<owner>.legacyLedgers` for an earlier writer's
  ledger. Native sinks (`home.file`, `home.activation`, `systemd.user`,
  `launchd.agents`, devenv `files`, `tasks`, `enterTest`, `processes`) are
  reached only through ai-module; `ai-module-no-direct-sink-writes` fails a line
  in a library or owner module that starts with one of those sink names (or
  `home = {`), except the exact path/line pairs exempted in
  `packages/ai-module/checks/sink-guard.nix`: option stubs, Beads' manual tasks
  and glab's oneshot keyring units. A lifecycle the three layers cannot express
  reopens this design; it is never a new exemption.
- Root `ai.*` options are defined only in their declaring file; the
  module-provenance guard (`rootPoolViolations`) exempts `lib/runtime.nix` alone
  for `activation`, `files`, `claims`, `legacyLedgers` and `services`.
- A disabled owner forwards no files. Commands default to the owner's state;
  `runWhenDisabled = true` keeps a release or retirement command running.
  `legacyLedgers` and `runWhenDisabled` commands must be declared outside the
  owner's enable gate.

### Methods and where they lower

| `method`  | Delivered by                                                               |
| --------- | -------------------------------------------------------------------------- |
| `symlink` | Native: HM `home.file`, devenv `files` (devenv guards stale/foreign links) |
| `ro`      | Files engine copy, on both backends                                        |
| `rw`      | Files engine key merge into a json/toml/yaml document, on both backends    |

`method = { devenv = …; hm = …; }` picks per backend. `content.run` needs `ro`
or `rw` and runs only in `files-apply`, after the `secrets` point. The engine
never tracks native links, and a devenv `copyMode` override on a planned path
fails evaluation.

### Activation

Commands order themselves with abstract points (`files`, `linkCheck`,
`materialized`, `secrets`, `shell`) in `after`/`before`; existing native DAG or
task names go only in `afterNodes`/`beforeNodes`. ai-module adds the strict
header: HM runs each command in `run bash -c`, devenv in a subshell, so `exit`
ends only that command. Native names are `ai-<key>` (HM) and `ai:<key>` (devenv)
unless `name` sets one. Both backends reserve the keys `files-apply` and
`files-prune`; devenv also reserves `files-guard`, `files-inspect` and
`files-snapshot`. `ai.activationOrder.secretProviders` declares each provider's
native `nodes` and optional Home Manager user `unit`; both lowerings use the
nodes for the `secrets` point. Home Manager adds `sops-nix` by default unless
the consumer declares that key. `ai.activationOrder.secretNodes` adds nodes
without a unit.

### Collisions

Exclusive paths, services and ports use the hidden `ai.claims.<group>.<key>`
registry. Two claims fail, even with identical values, with
`ai.claims.<group>.<key>: claimed by <a> and <b>`; owners are sorted and a
disabled entry still claims. Port owners name `<owner>:<service>.ports.<name>`.
Owners register resources; one registry validates every group. Other resources
use `ai.<owner>.claims.<group> = [keys]` while that owner is enabled; CPA client
keys instead belong to named instance entries. Ancestor/descendant paths fail as
overlapping destinations. A key in the helper's `shared` list (root `AGENTS.md`)
forwards unclaimed, so its composer stays the single owner; divergent
equal-priority definitions there fail with conflict text naming
`lib/runtime.nix`, not the owners.

### Services

Declare a daemon through `ai.<owner>.services`; enabled owners forward to
`ai.services`. Keys match `^[a-z0-9][a-z0-9_-]*$`. Fields are `command`
(nonempty argv), `enable`, `environment` (strings, redact references or secret
files), `files` (JSON `content` with `{$NAME}` placeholders, `secrets` NAME →
reference or secret file, and the `variable` exported with the path), `ports`,
`restart` and `restartOnChange` (absolute paths). A strict launcher reads
secrets at start, renders each file and each `redact.types.secretFile` value
0600 into a 0700 `$XDG_RUNTIME_DIR/ai-service-<key>` directory, or
`${TMPDIR:-/tmp}/ai-service-<uid>-<key>` without XDG_RUNTIME_DIR, both read
after the declared environment applies, and execs argv on both backends; a
secret file is delivered as its path. The root must exist; an existing service
directory must be owned by the current user and neither a symlink nor a
non-directory. The launcher clears private secret slots before reading and
before exec; `environment` names and file `variable` names reserve the `_ai_`
prefix. Services read store paths and secrets, never engine-written files;
oneshot and file-watch units remain outside this surface. A tool with typed
settings declares named instances through `lib/instances.nix`, which lowers each
`ai.<owner>.instances.<name>` to the service `<owner>-<name>`.

Linux Home Manager gives a secret-reading unit, one with a redact reference or a
restart trigger, `Wants=` and `After=` on the registered provider units and
starts it under the targets of provider units defined in the evaluated
configuration, falling back to `default.target`; a plain service uses
`network.target` ordering and `default.target`. Devenv lowers to processes and
ignores provider units. Darwin Home Manager emits one warning per enabled
service, since it has no systemd user units. File references in the environment
and in file secrets join explicit restart triggers, which behave differently per
backend. On Linux Home Manager the launcher stamps a digest of the triggers and
its invocation ID under the runtime directory before exec, and one generated
`services-reconcile` activation entry after `reloadSystemd` restarts each active
reader whose stamp differs from the files, through `systemd.user.systemctlPath`;
a failed provider or reader, a restart that does not stamp current bytes, or an
unreachable running user manager fails activation. Devenv uses `watch.paths`.
Every service has one start limit, defined once as `restartPolicy` in
`lib/services.nix`: five starts in 300 s with `RestartSec=5`. Linux Home Manager
writes `StartLimitBurst` and `StartLimitIntervalSec` in `[Unit]`; devenv writes
`restart.max = 4` and `restart.window = 300`. Only ai-module writes these daemon
sinks.

### State and ownership

The engine owns exactly what its state records:
`nix-agentic-tools/files/ai.json` under XDG state (HM) or `$DEVENV_STATE`
(devenv). `files-prune` runs on every activation, so removing the last entry
drains its copies; an edited copy is backed up before it changes. Legacy ledgers
import once into that state and are then deleted.
