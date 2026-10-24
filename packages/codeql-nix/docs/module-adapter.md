# Module metadata adapter

> **Last verified:** 2026-10-23 — M3p adds optional retained definition order to
> E2a root metadata; native paths retain provenance and selected syntax
> admission is independent of retained origins.

An adapter obtains configuration plus option metadata: a rich result.
`src/eval/nix/adapters/evalModules.nix` takes pinned `lib`, module paths and
JSON arguments; `src/eval/nix/modules.nix` selects one option's metadata without
values. Definitions are retained assignments; declarations introduce options;
origins are file labels; priority is the override number, lower wins. Tied
definitions survive. Every emitted option and retained definition has its own
observation and exactly one typed `nx_observation_options` or
`nx_observation_definitions` link; definition observations identify their
sibling ordinal through the definition entity, never through request text.
`definitions` preserves retained ordinals beside `declarations`, `isDefined` and
`priority`; priority includes `isDefined`. The `selection` facet emits these
retained definitions, whether the option is defined, winning override priority
and explicit order together. It counts option plus definitions, and depth zero
permits only an undefined root option. Order comes from a retained definition's
own `priority` field, stays separate from override priority and remains absent
when upstream omits it. See [module-properties.md](module-properties.md) for
query semantics. The [supervisor](evaluation-isolation.md) keeps limits and
publication. Callers supply [S2](source-identity.md) file rows and copy
mappings; original and copied bytes must match before linking. Implicit native
module paths retain Nix string context without changing their label spelling.
Plain absolute strings, synthetic labels, explicit `_file` and explicit
definition labels prove no source identity. The supervisor admits selected
authenticated syntax files by exact target root name and content identity before
requests run; unselected files and failed requests retain this admission.
Origin-file links still require trusted labels plus matching original and copied
bytes. Missing rows mean unknown. An optional pinned `library` descriptor makes
this adapter import the actual library handle; caller-supplied `lib` remains the
legacy route without binding claims. The supervisor supplies independently
authenticated top-level function and `lib` formal candidates, and successful
selection transactions may bind direct root file invocations.
`specialArguments.lib` suppresses these bindings; computed, forwarded and
uncovered functions remain unknown. Library/target/model pins must match.
Re-audit lazy label normalization before value consumers. Change these producers
together, preserving F1 validation and F2 authorization. Run
`checks.x86_64-linux.codeql-nix-modules` for direct Nix comparisons and
refusals; format edits and regenerate through `generate:all`.
