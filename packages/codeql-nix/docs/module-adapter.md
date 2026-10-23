# Module metadata adapter

> **Last verified:** 2026-10-23 — E2a emits root option metadata with X1 typed
> observation subjects.

An adapter obtains configuration plus option metadata: a rich result.
`src/eval/nix/adapters/evalModules.nix` takes pinned `lib`, module paths and
JSON arguments; `src/eval/nix/modules.nix` selects one option's metadata without
values. Definitions are retained assignments; declarations introduce options;
origins are file labels; priority is the override number, lower wins. Tied
definitions survive. Every emitted option and retained definition has its own
observation and exactly one typed `nx_observation_options` or
`nx_observation_definitions` link; definition observations identify their
sibling ordinal through the definition entity, never through request text.
`definitions` adds contiguous ordinals beside `declarations`, `isDefined` and
`priority`; priority includes `isDefined`. The
[supervisor](evaluation-isolation.md) keeps limits and publication. Callers
supply [S2](source-identity.md) file rows and copy mappings; original and copied
bytes must match before linking. Synthetic labels, explicit `_file` and explicit
definition labels prove no source identity. Missing rows mean unknown. Re-audit
lazy label normalization before value consumers. Change these producers
together, preserving F1 validation and F2 authorization. Run
`checks.x86_64-linux.codeql-nix-modules` for direct Nix comparisons and
refusals; format edits and regenerate through `generate:all`.
