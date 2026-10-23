# Activation, backend execution and guards

> **Last verified:** 2026-10-22 — split from DESIGN.md without changing the
> generic file, activation or service contracts.

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
