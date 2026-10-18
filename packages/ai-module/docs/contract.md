## ai-module Files, Activation and Services Contract

> **Last verified:** 2026-10-18 — repository modules reach Home Manager and
> devenv file and activation sinks only through ai-module's three layers, apart
> from the exact exemptions in `packages/ai-module/checks/sink-guard.nix`; a
> service's `files` are rendered by its launcher at start.

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
`files-snapshot`.

### Collisions

Exclusive paths, services and ports use the hidden `ai.claims.<group>.<key>`
registry. Two claims fail, even with identical values, with
`ai.claims.<group>.<key>: claimed by <a> and <b>`; owners are sorted and a
disabled entry still claims. Port owners name `<owner>:<service>.ports.<name>`.
Owners register resources; one registry validates every group.
Ancestor/descendant paths fail as overlapping destinations. A key in the
helper's `shared` list (root `AGENTS.md`) forwards unclaimed, so its composer
stays the single owner; divergent equal-priority definitions there fail with
conflict text naming `lib/runtime.nix`, not the owners.

### Services

Declare a daemon through `ai.<owner>.services`; enabled owners forward to
`ai.services`. Keys match `^[a-z0-9][a-z0-9_-]*$`. Fields are `command`
(nonempty argv), `enable`, `environment` (strings or redact references), `files`
(JSON `content` with `{$NAME}` placeholders, `secrets` NAME → reference, and the
`variable` exported with the path), `ports`, `restart` and `restartOnChange`
(absolute paths). A strict launcher reads secrets at start, renders each file
0600 into a 0700 `ai-service-<key>` runtime directory, and execs argv on both
backends. Services read store paths and secrets, never engine-written files;
oneshot and file-watch units remain outside this surface.

Linux Home Manager lowers to user units, devenv to processes. Darwin Home
Manager emits one warning per enabled service, since it has no systemd user
units. File references in the environment and in file secrets join explicit
restart triggers, which behave differently per backend: Linux Home Manager
fingerprints them in one generated `services-restart-on-change` activation entry
after `files` and `secrets`; devenv uses `watch.paths`. Only ai-module writes
these daemon sinks.

### State and ownership

The engine owns exactly what its state records:
`nix-agentic-tools/files/ai.json` under XDG state (HM) or `$DEVENV_STATE`
(devenv). `files-prune` runs on every activation, so removing the last entry
drains its copies; an edited copy is backed up before it changes. Legacy ledgers
import once into that state and are then deleted.
