# ai-module: files, activation and services

`ai-module` is the base for every repository module, including non-AI programs.
The three layers are `ai.<owner>.files` → `ai.files` → `ai.activation`. Native
links branch from layer 2 to the backend's file primitive. They are the only
path from a repository module to Home Manager's or devenv's file and activation
sinks.

> **Last verified:** 2026-10-22 — navigation preserves existing layer and
> backend anchors; linked sections retain the generic contracts.

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

See [runtime file overrides](design-runtime-files.md).

### Layer 2: generic files

See [generic files](design-files.md).

### Layer 3: generic activation

See [activation](design-activation.md#layer-3-generic-activation).

## Services

See [services and Instances](design-services.md) and
[service lifecycle and claims](design-service-lifecycle.md).

## Backend graph and execution

See [backend execution](design-activation.md#backend-graph-and-execution),
[engine contract](design-activation.md#engine-contract) and
[repository guards](design-activation.md#repository-guards).

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
