# Git tool settings: census, sidecar, generator

> **Last verified:** 2026-09-29 — one generator
> (`lib/git-tool-settings/default.nix`) serves git-branchless and git-absorb (7
> keys, 36 mutants).
>
> **Settled — do not relitigate.**
>
> - **Extraction method order is eval > AST > regex.** Eval: the program reports
>   or executes its own schema. AST: walk typed nodes (tree-sitter-rust through
>   `rust_tree.py`; Python's `ast`). Locating a site with a tree query and then
>   running a regex over the matched code text is NOT AST extraction; the first
>   git-branchless census did that and misread a `>` inside a `format!`
>   argument. A regex is allowed only over prose (docs, man pages, doc comments)
>   or an already-decoded string value, and each one carries a comment saying
>   why the tree cannot supply it plus a mutant a naive pattern gets wrong.
> - **Unknown sidecar fields fail the generator.** A field it ignored would drop
>   a measured fact silently (the git-absorb critic found `minimum` ignored and
>   `maxStack = 0` type-checking). Teach the generator the field in the same
>   change that teaches an extractor to write it.

## Files

| Path                                   | Role                                                                                                 |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `lib/git-tool-settings/default.nix`    | the generator: sidecar → closed option tree, `leaves`, `report`                                      |
| `lib/git-tool-settings/extraction.nix` | `patchedSource`, `extracted`, and the three checks per tool                                          |
| `lib/git-tool-settings/rust_tree.py`   | tree-sitter-rust helpers: literals, calls, token trees, doc comments, test filtering                 |
| `lib/git-tool-settings/census.py`      | failure list, key-token net, fill-only annotations, sidecar writer                                   |
| `lib/git-tool-settings/mutate.py`      | the mutation harness every tool's `<tool>-extractor-guards` runs                                     |
| `packages/<owner>/extract/`            | the tool's own `extract.py` and `annotations.json`                                                   |
| `packages/<owner>/lib/default.nix`     | `lib.<owner>.settings {lib}` — the generator over that sidecar, plus the tool's hand tables (if any) |

Owners live under `packages/` and share code only through `lib/`, which is why
the generator and helpers sit here and not in one owner.

## Sidecar schema

Top level: `settings`, `foreign`, `deadKeys`, `source.version`, and optional
`revsetFunctions` (git-branchless). A `settings` entry (the tool's own section)
may carry:

- always: `reads` / `writes` (`file#fn` → config chains), `type` (`bool`, `int`,
  `string`, `path`, `enum` with `values: [{value, description}]`), `status`
- measured: `default`, `defaultExpr` (source of a computed default), `fallback`
  (keys consulted when unset, in order), `minimum`, `invalid` (`default` or
  `fallback`: what a value the tool cannot parse becomes), `specialValues`,
  `overriddenBy` (CLI flags that beat the setting), `cli`
  (`{flag, doc, alsoSetBy}`, a flag ORed with the setting), `documented`
- prose: `description`, `defaultDescription`, `note`

`foreign` entries (git's own keys the tool reads or writes) take the measured
fields but no prose; they never become options. Annotations may only fill an
empty field or replace one they name in `replace` (`census.apply_annotations`).

## Generator

The tree is rooted at the tool's section and mirrors the git key path. Scalars
are `nullOr T`, default `null`; `<name>` families are `attrsOf str`, default
`{}`, names matching `^[A-Za-z][A-Za-z0-9-]*$`. `int` is 32-bit, raised to
`minimum` when measured. The description carries upstream text, the upstream
default or fallback chain, special values, CLI interplay, silent-invalid
handling and notes; the upstream default never goes into `default`. Keys the
tool only writes are excluded.

`report.untyped` (a type it cannot map), `report.collisions` (nested keys) and
`report.stale*` (hand-table rows naming a gone or retyped key) must be empty;
`git-tool-settings-generator` asserts that for every owner exporting `settings`
(discovered from the flake's `lib`), plus fixture cases for the schema and each
description field.

## Checks per tool (`extraction.nix`)

- `<tool>-extracted` — drift between the committed sidecar and a fresh
  extraction. Staleness only; the update pipeline commits whatever the extractor
  says.
- `<tool>-extractor-guards` — the mutants: each trips the guards it names or
  moves the output exactly as declared.
- `<tool>-extracted-binary` — every extracted key is a string in the installed
  package.

## Per tool

- **git-branchless** — see `packages/git-branchless/docs/extraction.md`.
- **git-absorb** — every read is one shape,
  `match repo.config().and_then(|c| c.get_T(K)) { Ok(v) [if v > N] => v, _ => D }`;
  keys and defaults reach it through parameters and are paired per call path.
  Descriptions come from `Documentation/git-absorb.adoc` converted to DocBook by
  `asciidoc`, config examples parsed as INI. Measured runtime facts the sidecar
  cannot carry: git-absorb's libgit2 ignores `git -c` and `GIT_CONFIG_*`, so
  only config files reach it; an invalid value in a higher scope resets to the
  default instead of falling through; the four CLI flags are ORed with their
  keys (`cli`), so a global `true` can only be undone per repository.

## Adding a tool

`extract/extract.py` + `annotations.json`,
`passthru.{patchedSource,extracted, regenerateExtracted}` on the package, a
`checks.nix` calling `extraction.checks`, a mutant list covering every guard,
and `lib/default.nix` exporting `<owner>.settings`. The generator check then
covers it without an edit.
