# ai-module: files and activation MVP

Design for PR 2; no production caller changes. The operator's 2026-10-15
`private/files-redesign/PLAN.md` decisions supersede the inventory's original
verdicts. Row IDs below refer to `private/files-redesign/ledger.md` (223 rows).
Those private inputs are review evidence, not dependencies of the package.

`ai-module` is the base for every repository module, including non-AI programs.
The three layers are `ai.<runtime>.files2` → `ai.files2` → `ai.activation2`.
Native links branch from layer 2 to the backend's file primitive. PR 3 migrates
callers, removes superseded delivery code, and drops the `2` suffixes. PR 2 adds
options alongside existing ones and exercises them only in checks.

## Owner and move

| Destination under `packages/ai-module/`                         | Responsibility and source                                                                                                                                                                                  |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `checks.nix`, `checks/`                                         | Move `lib/files2/checks/` here; the entry imports its check modules. Remove the forwarding `checks/files2/default.nix`. Preserve existing check names during the move.                                     |
| `docs/DESIGN.md`                                                | This layer contract and coverage.                                                                                                                                                                          |
| `docs/files-engine.md`                                          | Move `lib/files2/DESIGN.md` here, retaining its file schema, refusal messages, codec rules, state and transition tables. Replace its standalone module/backend sections with a link here.                  |
| `lib/activation.nix`                                            | Activation entry type and graph validation.                                                                                                                                                                |
| `lib/default.nix`                                               | Export the owner library under `aiModule`: file types/normalization and the runtime registration helper.                                                                                                   |
| `lib/files/`                                                    | Move `lib/files2/{default.nix,engine.py,files2_codecs.py}` here; `guard.py` prepares native devenv links. Split normalization from backend delivery as the later chunks replace the old lowering function. |
| `lib/lower-devenv.nix`, `lib/lower-hm.nix`                      | One lowering function per backend; each receives the complete normalized file plan and activation graph.                                                                                                   |
| `modules/common.nix`                                            | Declare generic options and generate file-engine activation entries; shared by both backends.                                                                                                              |
| `modules/devenv/default.nix`, `modules/homeManager/default.nix` | Import common declarations and call the corresponding lowering function once.                                                                                                                              |

Delete `lib/files2/` after its contents move; no forwarding shim and no import
from `lib/ai/`. `lib/facets.nix:196` discovers owner libraries, `:212` discovers
backend module directories, and `:275` discovers `checks.nix`; no central owner
list is added. This follows `docs/repository-layout.md`. The existing empty
configuration remains usable: the base stays installed and its empty plan can
drain old ownership. Removing the base module itself cannot drain anything.

## Options and composition

### Layer 1: runtime file overrides

`runtimeModule { name; enabled; shared ? []; }` declares `ai.<name>.files2`, an
`attrsOf fileEntry`, default `{}`. `name` is the stable runtime identifier;
`enabled` is the owning module's existing boolean. These are constructor inputs,
not another runtime enable option. The helper also declares
`ai.<name>.activation2` (layer 3) and the internal `ai.<name>.legacyLedgers`
(`listOf { codec = enum ["dir" "json"]; ledger; path; }`), both forwarded
outside the `enabled` gate into `ai.activation2` and the internal root
`ai.legacyLedgers`, so a disabled owner still runs its `runWhenDisabled`
commands and drains its old ledgers. Each forwarded command gets
`enable = mkDefault enabled` at the forwarded priority; a producer that sets
`enable` overrides it. Keys listed in `shared` forward without a claim in
`ai.files2Owners`, which leaves their composer the single claimant. Checks
install synthetic runtime modules in PR 2; PR 3 installs the helper in runtime
owners. Shared skills, rules and other surfaces produce entries here; their
rendering stays above this layer.

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
| Direct layer-2 override | Uses ordinary Nix priorities against forwarded definitions. Equal-priority incompatible scalar/content alternatives fail; equal structured leaves merge. There is no hidden runtime precedence over `ai.files2`.                                                                       |
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
forwarded root definition reports `lib/runtime.nix`; the module-provenance guard
exempts exactly that file for `activation2`, `files2`, `files2Owners` and
`legacyLedgers`. Content selection examines only the highest-priority defined
alternative, so a discarded source is never evaluated.

The helper also records each declared key, including one with `enable = false`,
in the internal `ai.files2Owners.<path>` list; a disabled entry would otherwise
override another runtime's entry unseen. Normalization fails with
`files2."<path>": runtime owners <a> and <b> claim one destination` when a path
has two runtime claims. Overlapping (ancestor/descendant) paths from distinct
runtimes fail through the expanded-destination overlap check, which names the
paths, not the owners.

### Layer 2: generic files

`ai.files2` is `attrsOf fileEntry`, default `{}`. It serves runtimes and
ordinary program modules equally. `fileEntry` is the moved engine design's
schema: content alternatives `run/source/text/value` default null; `enable`
defaults true; `executable` and `mode` default null; `format` defaults `raw`;
`method` defaults `symlink`; `recursive` defaults false. Two internal fields are
added. `_contentPrio` is read-only: the strongest priority of any `content`
definition, read without evaluating one, so a runtime's generated tree can leave
out a whole-content default a consumer replaced. `requires` is a list of
derivations, default `[]`. The engine appends their string context to each
delivered leaf after the recursive walk, so the backends build them before
delivery and evaluation never reads them; a runtime's generated files require
its generated tree, whose guards, surface checks and byte limits then gate a
recursive source or a value that does not point into it. Types, priority
arbitration and all refused combinations remain in the engine document. A
backend-specific method still requires both `devenv` and `hm` fields.

Normalize the complete map once, after merging and runtime gating, then check
expanded destination collisions. Symlinks lower to `home.file` or devenv
`files`; `ro` and `rw` always use the engine on both backends. Native devenv
copy cannot retire real files (`dev/fragments/devenv/files-internals.md:152`).
There is no native-copy escape hatch for an entry owned by this map: a native
`files.<path>.copyMode` other than `symlink` on any enabled normalized
destination, including `ro` and `rw`, fails evaluation with that path named.

One stable namespace, `ai`, owns the unified copy plan. Keep the engine state
layout: HM uses
`${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/files2/ai.json`; devenv
uses `$DEVENV_STATE/nix-agentic-tools/files2/ai.json`. Roots are `$HOME` and
`$DEVENV_ROOT`, respectively. Neither namespace nor engine task names are
per-file options. The same root must not be activated concurrently through two
independent backend states.

Layer 2 generates `files2-prune` internally on every activation, including with
an empty map, so removing the last file still drains it. For an empty map only,
its command exits before Python starts when the engine state file is absent,
which the engine guarantees whenever nothing is owned, so a consumer that
declares no files pays one shell test per activation. A nonempty map always
starts the engine in prune, whose parent check refuses a symlinked parent before
HM's native linking. `files2-apply` is generated only for a nonempty plan.
Backend lowering validates and lowers their union with the caller's
`ai.activation2` graph; the generated entries are not option definitions that a
whole-option priority override can remove. A caller key colliding with a
reserved name fails evaluation, whether or not that entry is emitted: both
backends reserve `files2-apply` and `files2-prune`, and devenv also reserves
`files2-guard`, `files2-inspect` and `files2-snapshot`. Generated entries have
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

Devenv also generates the observer pair (L168, L169), which never deletes and
never fails the shell. Both entries remain emitted with an empty plan:
inspection must still report retained paths from its ledger, and snapshot
precedes the always-present cleanup task. `files2-snapshot` clears both abstract
defaults and runs before `devenv:files:cleanup`: it copies the owned paths of
devenv's previous link list into `$DEVENV_STATE/ai-delivery-observed.json`.
`files2-inspect` runs after `materialized` with devenv `showOutput`, because
devenv hides a passing task's output. It warns for an owned link that is absent
or replaced by a file, a directory or a stale link, and for a remembered path no
longer delivered that is still on disk. Ownership is the normalized plan, each
path named by its `ai.files2Owners` claim or else `ai.files2`, plus the live
`ai.deliveredPaths`.

### Layer 3: generic activation

`ai.activation2` is `attrsOf activationEntry`, default `{}`. Its key is the
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
Native names default to `ai2-<key>` on HM and `ai2:<key>` on devenv. A resolved
devenv name must have two or more nonempty colon-separated parts containing only
ASCII letters, digits, underscores and hyphens. Invalid names fail with the
entry named. Duplicate resolved names, reserved names, self-edges and cycles
also fail with the entry names. Native node strings are trusted integration
edges, not guessed optional tasks; callers add conditional edges only when their
provider exists.

`ai.activation2Order.secretNodes` is `listOf str`, default `[]`. The HM lowering
always adds `sops-nix` (its DAG tolerates a missing dependency; a module in this
repo may not define root `ai.*` defaults); devenv has no standard provider.
Integrations can register additional native preparation nodes once, outside
individual file entries. These nodes supply the `secrets` point for commands and
`content.run`.

## Backend graph and execution

Each backend lowering function maps the same graph once. HM uses
`lib.hm.dag.entryBetween before after`; devenv emits `{ after; before; exec; }`
tasks. Native file sinks and activation sinks are single literal attributes
whose values contain the computed maps; do not create option-derived module
fragments while collecting definitions (`lib/ai/adapters/hm.nix:29`).

`A → B` means B depends on A. Every abstract point resolves to the following
node(s) for both `before` and `after` references:

| Point          | HM node(s)                            | devenv node(s)               |
| -------------- | ------------------------------------- | ---------------------------- |
| `files`        | `linkGeneration`                      | Internal `ai2:files-linked`. |
| `linkCheck`    | `checkLinkTargets`                    | Internal `ai2:link-check`.   |
| `materialized` | Internal `ai2-files-ready`.           | Internal `ai2:files-ready`.  |
| `secrets`      | Registered `secretNodes`.             | Registered `secretNodes`.    |
| `shell`        | Internal completion node `ai2-ready`. | `devenv:enterShell`.         |

The internal point nodes are empty DAG/task entries, not caller commands. HM
adds `linkGeneration → ai2-files-ready → ai2-ready`; apply also precedes
`ai2-files-ready`. HM has no shell-entry phase: `shell` means the completion of
this activation graph. Ordinary activation entries still run during HM switch.

Devenv adds this exact chain when the **final native `config.files`** is
nonempty:

```text
devenv:files:cleanup → ai2:link-check → ai2:files2-guard
  → devenv:files → ai2:files-linked → ai2:files2-apply
  → ai2:files-ready → devenv:enterShell
```

With no native file task, replace `guard → devenv:files → files-linked` with
`guard → files-linked`. Without a guard, `link-check` precedes the next node of
the chain directly. Retain direct `prune → apply` and `guard → apply` edges
whenever both ends are emitted, and `provider → apply` edges for run content.
Prune and every command with `before = ["linkCheck"]` precede `ai2:link-check`,
so guard runs after all such commands. They also follow `devenv:files:cleanup`
unless explicitly positioned before cleanup with a native edge. Cleanup exists
even at zero files; never manufacture a missing `devenv:files` task. A
declaration requiring before link-check must clear `after = ["files"]`;
contradictory ordering is an error.

The same HM chain is prune/pre-link commands → `checkLinkTargets` →
`linkGeneration` → apply → `ai2-files-ready` → `ai2-ready`. Secret providers
also precede apply when required. A command such as Claude's conditional mode
repair can select `after = ["materialized"]` to run after owned writes.

Generated commands use a scoped subshell, full strict mode, and absolute store
paths for external tools. HM invokes the resulting script through `run`, so a
dry run cannot mutate files or execute a secret renderer. Devenv tasks execute
the script directly. The engine gets `FILES2_BASH`; `content.run` receives the
backend environment and any provider environment. Existing renderer-specific
root exports stay inside the renderer body. No activation entry exports into a
later entry's shell. Devenv failure verification belongs to the backend check
path as well: execute failing tasks in tests and assert failure; shell-entry
warnings alone are not evidence of successful materialization.

## Engine contract delta

The [files engine contract](files-engine.md) retains the existing file schema
and runtime rules. Its schema, codecs, backup/adoption rules, path refusal,
recursive leaves and method/format switch semantics remain authoritative. In
particular, `rw` cannot surrender native keys to a whole-file owner. No
rollback, pending journal or crash recovery is added; mutation and state commit
remain per file.

Only ownership integration and state loading change. Replace the standalone
`files2` module/HM lowering function with the layers above. Under the existing
state lock, load a versioned document, apply an ordered migration chain,
validate the result, then atomically save before reconciliation. PR 2 defines v0
explicitly as `{ version = 0; files = ...; }` with the same payload schema as
v1; v0 → v1 changes only the version. Missing state starts at v1.
Missing/unknown versions and malformed payloads fail before filesystem mutation.
Loading the migrated state again is a no-op. PR 3 adds legacy-manifest import as
a separate step after loading, not a state version ([PR 3 plan](CUTOVER.md),
section 2.2); v0 does not parse historical TSV or ownership JSON.

## Ledger coverage

Declaration sketches use `R` for `ai.<runtime>.files2`, `F` for `ai.files2`, and
`A` for `ai.activation2`. R receives final root-relative paths. This is a
source-level mapping, not a claim of executed equivalence. IDs are exhaustive
within these groups; gaps and exclusions follow separately.

| Pattern                                                       | Ledger rows                                                                                                                                                                | Declaration sketch / retained behavior                                                                                                                                                                              |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Static native bytes and structured documents                  | L009–L010, L015–L016, L018, L021, L028, L034, L036, L039, L042, L044, L046–L047, L056, L062, L065–L066, L084–L087, L089–L092, L098, L126, L130–L131, L133–L135, L138, L143 | `R.path = { content = textOrSourceOrValue; format = codec; method = "symlink"; };` Executable scripts set `executable = true`; backend method differences remain explicit.                                          |
| Directory links and recursive leaves                          | L019, L033, L045, L048, L057, L093–L094, L115, L127, L145, L170                                                                                                            | `R.path = { content.source = tree; recursive = leaves; method = "symlink"; };` Single-file skills target `SKILL.md`; preserve source mode.                                                                          |
| Owned whole files, permissions and backend method differences | L014, L022, L025–L026, L031, L049, L054, L059–L060, L088, L102, L116–L118, L120, L125, L137, L141, L144                                                                    | `R.path = { content = payload; format = codec; method = "ro"; };` Add `mode` when required; backend pair selects HM link/project copy.                                                                              |
| Activation-rendered bytes                                     | L119, L121, L142                                                                                                                                                           | `R.path = { content.run = renderer; format = "json"; method = "ro"; };` Automatic HM `sops-nix` edge; register other providers once, optional `mode = "0400"`.                                                      |
| Shared writable documents                                     | L024, L035, L061, L095, L122–L123, L171                                                                                                                                    | `R.path = { content.value = declaredKeys; format = "json"; method = "rw"; };` Empty values retire prior keys. Static glab host YAML can use F with `rw` and `mode = "0600"`; live invocation host selection cannot. |
| Overrides, lazy defaults, enable and collisions               | L023, L029–L030, L038, L052–L053, L055, L067–L068, L072–L078, L080–L081, L124, L132                                                                                        | Set individual R fields with ordinary module priorities; disabled runtime contributes no claim. Retain winning-source laziness, reject cross-owner collisions, allow empty text.                                    |
| Shared root context arbitration                               | L017, L037, L040, L069–L071, L079, L103, L128, L146, L162–L163                                                                                                             | Upstream composer selects one `F.path = { content = finalContent; format = "markdown"; method = "ro"; };`; it retains replacement, suppression, deduplication and byte checks.                                      |
| Surface fanout                                                | L027, L104–L105, L129, L151–L154, L172, L179–L183, L191                                                                                                                    | Render existing pools into R; method/prefix selection belongs to the runtime producer. Store script packages remain upstream.                                                                                       |
| Plain automatic commands                                      | L001, L007, L012, L020, L032, L041, L043, L051, L063–L064, L097, L106–L107, L109, L147, L155–L156, L168–L169, L195                                                         | `A.name = { command = body; enable = ownerEnabled; };` Use abstract points and native edges below; keep locks, conditional chmod, restart logic and observation inside bodies.                                      |
| Generic sinks, state and policy                               | L058, L157–L161, L165–L167, L173–L175, L177–L178                                                                                                                           | F generates prune/apply and native sinks through A. Facts become a selected `method`, not extra file fields. Seed engine history for retired-file fixtures; no caller ledgers.                                      |

Command ordering details: L012 uses `after = ["files"]` and
`runWhenDisabled = true`; L020 clears `after` and uses `before = ["linkCheck"]`;
L032 adds `secrets` before link-check. L106 retains
`name.devenv = "git:config"`; L107 orders before that and conditionally before
`devenv:git-hooks:install`. L109/L147 use `after = ["files" "secrets"]`.
L155/L169 use `after = ["materialized"]`. L168 clears abstract defaults and uses
`beforeNodes.devenv = ["devenv:files:cleanup"]`. L195 uses
`afterNodes.devenv = ["devenv:git-hooks:install"]`. These are finite commands;
none needs a new file method or service scheduler.

## Gaps

| Gap                     | Rows / disposition                                                                                                                                                                                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Copilot agents          | L101 is dropped: github.com code review never reads `.github/agents`, so Copilot declares `agents` an unsupported surface (`backends = []`) and warns. Its old ledger stays in `legacyLedgers`, so existing files retire.                                                                         |
| Legacy ownership import | L011, L013, L083, L096, L099–L100, L112–L114, L136, L139–L140, L164, L176. PR 3 must import old manifests, including historical directory hashes and disabled-first-upgrade state. PR 2 only establishes the migration chain. No old/new concurrent-writer or rollback compatibility is promised. |
| Native-copy override    | L050 is deliberately rejected under the settled native-first rule: native copy cannot drain. Rewrite this fixture in PR 3 to assert refusal and use `method = "ro"` for owned copies.                                                                                                             |

L165's proposed native-link ownership bootstrap is withdrawn: the engine never
tracks native links. Native cleanup plus the guarded desired-link preparation
above covers the operation. This is separate from legacy copy import.

Out of scope, not missing MVP features: manual tasks/apps L004–L006, L008,
L184–L190, L192–L194, L196 and L207–L223 remain owner tasks. L007 is automatic
prepare, so it maps above with L001; the manual-task exclusion names bootstrap,
checkpoint, diagnostics and status. Services L002–L003/L110–L111 are follow-up
work. Runtime I/O L082/L108/L148–L150 and CI L197–L206 remain with their
execution lifecycles. For the reclassified module side of L082/L108/L149–L150,
hook configuration maps to R and wrappers remain native package installation. No
seed method, formatting framework, renderer framework or remaining `lib/ai/`
migration is designed here.

## PR 2 chunks and proof

Each chunk targets at most about 400 changed lines including checks and design
updates. Pure file relocations are reviewed with rename detection; if a move
requires content changes beyond that budget, split those changes into the next
chunk. Every chunk must evaluate its named check before handoff; CI builds and
executes it. No local package builds are required.

| Chunk | Deliverable                                                                         | Own checks                                                                                                                                             |
| ----- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0     | This design only.                                                                   | Format, spelling, exhaustive ledger disposition; adversarial design review.                                                                            |
| 1a    | Move engine, codecs, checks and engine document; owner discovery; delete old paths. | Existing `files2-eval`, `files2-hm`, `files2-ro-runtime`, `files2-rw-runtime` evaluate at relocated paths; CI reruns unchanged behavior.               |
| 1b    | Versioned migration chain.                                                          | v0 → v1, repeat load, missing state, rejected versions/payloads; execute engine tests.                                                                 |
| 2a    | Activation schema and HM lowering.                                                  | Command-only DAG, dry-run, names, native edges, disabled drain and cycle errors.                                                                       |
| 2b    | Devenv activation lowering and provider points.                                     | Exact edges with/without native files; direct secret edge; execute command success/failure.                                                            |
| 3a    | Generic file map over activation; replace old HM lowering function.                 | Real HM native generation plus engine phases, N→0, disabled owner and dry-run; execute renderer after provider without consumer `secretNodes`.         |
| 3b    | Devenv native files, guard and copy phases.                                         | Execute stale/foreign-link guards, native cleanup, copies and empty-plan drain; reject native-copy override.                                           |
| 4a    | Runtime helper and priority-preserving forwarding.                                  | Synthetic non-AI and runtime owners, disabled gating, scalar/value/content priorities, lazy discarded source and destination collisions.               |
| 4b    | Shared-surface producer fixtures.                                                   | Skills reach R then F per runtime prefix; one composed shared target reaches F once or not at all; conflicts are 4a. No production runtime imports.    |
| 5a    | Generated fixture matrix.                                                           | `method × format × shape × backend`; valid plans/sinks/edges, impossible cells assert the exact named error from the engine contract.                  |
| 5b    | Generated transitions and end-to-end activation fixtures.                           | All six directed method switches changing only method, format-only switches, retirement, backups, adoption and preserved native keys on both backends. |

Matrix lists are backend `["devenv" "hm"]`, format
`["json" "markdown" "raw" "toml" "yaml"]`, method `["ro" "rw" "symlink"]`, shape
`["executable" "recursive" "run" "source" "text" "value"]`: 180 cells, generated
rather than enumerated. Recursive sources contain nested directories and
executable leaves; non-recursive directory links get a separate fixture. Use
independent expected outcomes for refusals, not the implementation's validation
result as the expected value. Invalid cells cover keyless `rw`, keyless values,
recursive `rw`, and run/symlink; separate negative cases cover content ties,
paths, modes and overlapping destinations. Evaluation-only tests read structured
plans/graphs; runtime tests execute the emitted activation scripts with native
backend fixtures, then assert bytes, links, modes, backups and state. A
successful evaluation is not a claim that runtime checks passed.

The 5b check `ai-module-transitions` lists scenarios as declaration steps and
executes every generated body on a fresh root in native order: HM runs prune,
then a stand-in for `linkGeneration` (remove dropped links, link the rest), then
apply; devenv runs a stand-in for `devenv:files:cleanup`, prune, guard, a
stand-in for `devenv:files`, then apply. Each step's plan is asserted on disk
and in state, so a switch both lands and retracts the previous materialization.
Every step also asserts its exact set of new backups: none, unless a local edit
or a program-written `rw` key precedes an owned change, which must back up those
bytes. The generated phases come from the evaluated entries, and the runner
refuses a phase it would not execute. Scenarios: the six directed method
switches; `ro` and `rw` format switches json → toml → yaml, with a
program-written `rw` key; retirement; backup of an edited copy; silent adoption
of an identical full image (bytes and mode); and execute bits of a recursive
leaf under `ro` and `symlink`. The stand-in link step refuses a real file, as
both native steps do; the native steps themselves are not executed.
