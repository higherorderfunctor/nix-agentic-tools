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

`ai.activationOrder.secretNodes` is `listOf str`, default `[]`. The HM lowering
always adds `sops-nix` (its DAG tolerates a missing dependency; a module in this
repo may not define root `ai.*` defaults); devenv has no standard provider.
Integrations can register additional native preparation nodes once, outside
individual file entries. These nodes supply the `secrets` point for commands and
`content.run`.

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
files engine, so there are no service dependency edges into file activation or
Home Manager's systemd reload. Each Linux Home Manager unit is ordered after
`network.target` and `sops-nix.service`: sops-nix decrypts in its own oneshot
user unit at login, and a daemon started beside it would read a missing secret
and fail until its restart. An absent sops-nix unit leaves the ordering inert.

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
`${TMPDIR:-/tmp}/ai-service-<uid>-<key>` (numeric user ID). An existing
directory must be owned by the current user and must not be a symlink; other
inputs fail before chmod or writes. The runtime root must already exist. jq
replaces every placeholder string with its secret as a JSON string, writes a
0600 temporary file, renames it to `<file key>.json` and exports `variable` with
that path. Content and secrets are both known at evaluation, so the launcher
refuses to build when a placeholder has no secret, a secret has no placeholder,
or a `variable` repeats another file's or an environment name. Declared
environment names and file variables cannot start with `_ai_`, the launcher's
private namespace. JSON is the one format: YAML 1.2 readers take it as is. A
daemon's own writes to the file are lost at the next start.

`lib/instances.nix` gives a tool with typed settings named instances:
`ai.<owner>.instances.<name>` with `enable`, `package`, `port`, `settings` and
`stateDir`, declared through one owner module per backend that differs only in
the default state root (`xdg.stateHome` on Home Manager, `devenv.state` on
devenv, so a repository's instance keeps its own logins). Each instance becomes
the service `<owner>-<name>`: its port is `ports.main`, its settings render to
`files.config`, and a strict run script creates `stateDir` (and the owner's
state subdirectories) 0700, enters it and execs the package. The owner fixes the
settings an instance derives (the listen port, state paths) as ordinary
definitions, so a consumer value that disagrees fails evaluation. `select`
resolves an instance name to `http://127.0.0.1:<port>` or to the reason it
cannot: the name is missing or the instance is disabled. CLIProxyAPI and CPA
Manager Plus use it.

| Backend             | Lowering                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Home Manager Linux  | User unit: `After = network.target`, `WantedBy = default.target`, `RestartSec = 5`; `never` becomes `no`.                                 |
| Home Manager Darwin | No unit; one warning per enabled service says the platform has no systemd user units.                                                     |
| devenv              | Process `exec` is the same launcher; `restart.on` maps `on-failure` to `on_failure`; `watch.paths` is present only for nonempty triggers. |

Home Manager Linux reserves `services-restart-on-change`. When enabled services
have triggers, one generated activation entry runs after `files` and `secrets`.
It runs only while the user manager reports `running` or `degraded`,
fingerprints the readable regular files among the triggers under
`${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/services/<key>.sha256`,
`try-restart`s a service whose recorded fingerprint changed (the first record
restarts nothing and a stopped unit stays stopped) and saves each fingerprint
only after that succeeds. The two backends differ: Home Manager compares content
at activation, devenv's `watch.paths` restarts live on any change and accepts
directories.

Exclusive resources share `ai.claims.<group>.<key>`, a hidden registry of owner
lists validated once in `modules/common.nix`. Runtime helpers register
non-shared paths in `path`, service names in `service` and decimal ports in
`port`. Port owners are `<owner>:<service>.ports.<name>`. A list with more than
one owner fails with `ai.claims.<group>.<key>: claimed by <a> and <b>`, sorted
by owner. Adding a resource group needs no new validation code; owners register
resources and never assert uniqueness. The internal shared owner accepts scoped
service claims for proxies (`proxy:root`, `proxy:<runtime>`), so identical proxy
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

| Point          | HM node(s)                           | devenv node(s)              |
| -------------- | ------------------------------------ | --------------------------- |
| `files`        | `linkGeneration`                     | Internal `ai:files-linked`. |
| `linkCheck`    | `checkLinkTargets`                   | Internal `ai:link-check`.   |
| `materialized` | Internal `ai-files-ready`.           | Internal `ai:files-ready`.  |
| `secrets`      | Registered `secretNodes`.            | Registered `secretNodes`.   |
| `shell`        | Internal completion node `ai-ready`. | `devenv:enterShell`.        |

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
