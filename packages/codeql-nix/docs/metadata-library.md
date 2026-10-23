# Observed metadata library

> **Last verified:** 2026-10-23 — L0 reads existing metadata and syntax facts.

- QL is the language for querying a CodeQL database.
- A target is an explicitly named configuration.
- A context is a target's root instance.
- A request selects an option path, metadata facet and work limits.
- An observation records an outcome for one typed option or definition.
- Selected means retained for type merging, without proving a value's cause.
- An origin is an evaluator label with an optional admitted file or point.
- An anchor identifies syntax by file, byte range, kind and child path.
- A candidate is a literal source binding matching an origin and option path.
- Association quality: zero candidates unmapped, one unique, many ambiguous.
- Priority is the override number, retained as exact signed decimal text.
- TRAP is the fact format imported into a CodeQL database.

`Targets.qll`, `Modules.qll` and `Origin.qll` expose only `Target`,
`RequestResult`, `ObservedOption`, `SelectedDefinition` and `Origin`. Private
`internal/Evaluation.qll` shares observation witnesses and path encoding over
the [existing tables](database-contract.md). Request results retain failures.

Observed options require their typed subject link and an observed outcome from a
complete or partial request. Selected definitions require their own such link
and an observed parent option; request paths and siblings cannot supply it.
Paths retain exact segments and target identity. Missing priority stays absent;
failed or missing observations establish neither selection nor a losing
definition.

Origins expose optional file paths and reported UTF-8 byte points. Candidates
reuse [authenticated anchors](source-identity.md), require target admission and
match exact literal paths. Association quality cannot identify the expression
that produced a value. Equal-priority definitions may all remain selected.

The owner's `checks.nix` imports `checks/metadata.nix`, which runs handwritten
`ql/test/step0/Metadata.ql` expectations over independently assembled TRAP.
Cases cover failed/missing work, typed subjects, sparse definition observations,
exact paths, distinct targets, signed endpoints and origin association controls.
Live evaluation needs separate proof. Update accessors and expectations
together; format changes and run `codeql-nix-metadata` through CI.
