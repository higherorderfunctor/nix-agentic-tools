# git-branchless config extraction

> **Last verified:** 2026-09-29 — ast-grep census of the patched 0.11.1 source:
> 24 `branchless.*` keys (23 typed options, `branchless.mainBranch` excluded),
> 17 foreign keys, 36 builtin revset functions; 35 mutants fail closed or move
> the output as declared.
>
> **Settled — do not relitigate.**
>
> - **No self-report exists.** git-branchless has no `config` subcommand, and
>   its `--help` and man pages name two keys. Structured extraction is the top
>   usable rung; regex is not needed.
> - **Extract from the PATCHED source.** The unpatched tree misses
>   `branchless.core.protectCheckedOutBranches`, which only this repository's
>   patch reads.
> - **`test.jobs` does not imply the worktree strategy.** Only the command-line
>   `--jobs` above 1 switches strategy; a configured value above 1 with
>   `test.strategy = working-copy` fails every `git test run` (measured
>   2026-09-29). The prototype's annotation said otherwise and was wrong.

## Pipeline

`passthru.extracted` on the package (`packages/ai/gitTools/git-branchless/`)
runs over `passthru.patchedSource`, a `srcOnly` of the package's own `src`,
`patches` and `postPatch` under `stdenvNoCC`. It never builds Rust, and passthru
leaves the package's store path alone.

1. `extract/rules/config.yml` — ast-grep (tree-sitter-rust) rules. Rule ids are
   the contract with the resolver.
2. `extract/extract.py` — the resolver. It writes `extracted.json` and exits
   non-zero on any guard.
3. `extract/annotations.json` — the only hand input: prose the source cannot
   state (computed defaults, alias-family descriptions, the patch note), types
   for two untyped reads, and `deadKeys`.

Every config access goes through `ConfigRead`/`ConfigWrite` in
`git-branchless-lib/src/git/config.rs`, which is why a structured scan works.

## Sidecar shape

- `settings.<key>` — every `branchless.*` key: `type` (`bool`, `int`, `string`,
  `path`, `enum` + `values`), `default`, `description`, `status` (`current` /
  `legacy`), and `reads` / `writes` mapping `file#fn` to the config chains that
  site's handle reads (`repository`, `global` without the repository, `file` for
  one isolated file). Handle chains follow parameters back to every caller.
- `foreign.<key>` — git's own keys the tool reads or writes (`reads`/`writes`
  only; they are not typed here).
- `deadKeys` — key-shaped consts nothing reads, with the annotated reason.
- `revsetFunctions` — the builtin `FUNCTIONS` table. It is consulted before
  `branchless.revsets.alias.*`, so an alias with a builtin's name is dead.

`<name>` marks a family (`branchless.test.alias.<name>`).

## Guards

| Code | Fails when                                                                                                      |
| ---- | --------------------------------------------------------------------------------------------------------------- |
| F1   | a call on a config handle matches no recognised shape, or a UFCS call                                           |
| F2   | a key expression is unresolvable, or a key-returning fn has a non-literal match arm                             |
| F3   | a `branchless.*` read has no type                                                                               |
| F4   | an annotation is stale, shadows an extracted value without `replace`, or `deadKeys` names nothing               |
| F5   | the `ConfigRead`/`ConfigWrite` methods or `GetConfigValue` types change                                         |
| F6   | raw git2 config access outside the allowlist                                                                    |
| F7   | a `["config", …]` git argv has a non-literal element                                                            |
| F8   | a key-shaped const is never read and not in `deadKeys`                                                          |
| F9   | a production string literal names a `branchless.*` key no recognised read or write extracts (the net)           |
| F10  | a handle is obtained where no key is extracted and not handed to a Config-typed parameter, or stored in a field |
| F11  | a test cfg other than exactly `#[cfg(test)]`                                                                    |
| F12  | a default is neither a literal, an enum variant, nor a literal const                                            |
| F13  | two reads of one key disagree on type, enum values or default                                                   |
| F14  | the `FUNCTIONS` table changes shape, or aliases are no longer looked up after it                                |
| F15  | fewer than 20 current settings or 20 revset functions (the scan went blind)                                     |

Test code is whatever `#[cfg(test)]` or `#[test]` marks, plus `tests/`,
`benches/` and `testing.rs`, filtered once in the resolver for every rule.

F9 is the broad net: literals inside macros, closures and helper fns are tokens
to ast-grep too, so a read the resolver cannot follow still leaves its key in a
literal. It does not catch a key built entirely at run time without a
`branchless.` literal.

`checks/extractor-mutants.nix` holds one upstream-shaped change per guard and
per known blind spot; `git-branchless-extractor-guards` runs them through
`extract/mutate.py`. Add a mutant with every new guard.

## Checks

- `git-branchless-extracted` — the committed sidecar equals a fresh extraction.
  Staleness only: the update pipeline commits whatever the extractor says, so
  correctness rests on the guards.
- `git-branchless-extractor-guards` — the mutants.
- `git-branchless-extracted-binary` — every extracted key (a family by its
  literal prefix) is a string in the built binary.
- `git-branchless-settings-options` — the generator over the real sidecar and
  over fixtures.

## Generator

`lib/settings.nix` (exported as `lib.git-branchless.settings`) reads the
committed sidecar with `builtins.readFile` — never `passthru.extracted`, which
would be IFD — and returns `options` rooted at `branchless`, mirroring the git
key path, plus `leaves` for lowering and a `report`. Scalars are `nullOr T`,
default `null`; families are `attrsOf str`, default `{}`, with names matching
`^[A-Za-z][A-Za-z0-9-]*$`. Dotted names are valid to git-branchless but render
differently per backend, so raw git configuration is the escape hatch.
Upstream's default goes into the description, never into `default`.

Its hand tables report stale rows (`report.staleExclusions`,
`report.staleRefinements`), and `report.untyped` lists any sidecar type the
walker cannot map:

- `exclusions` — `branchless.mainBranch`, the legacy key `init` makes inert.
  Keys git-branchless only writes are excluded without a row.
- `refinements` — `test.jobs` to `0..2^31-1`, and revset alias names that are
  not builtins (compared case-insensitively against `revsetFunctions`). A row
  also goes stale when the key's sidecar type changes.

## Regeneration

git-branchless is owned by its flake input, so `mkUpdateScript` never runs for
it. `passthru.regenerateExtracted` (`packageLib.mkFlakeInputRegen`) is run by
`dev/scripts/update-input.sh git-branchless` through discovery; see the update
pipeline fragment. Locally, from the repository root:

```bash
"$(nix build --no-link --print-out-paths .#git-branchless.passthru.regenerateExtracted)"
```

## Reading the tool's config at run time

git-branchless reads config through libgit2, which ignores `GIT_CONFIG_GLOBAL`
and `git -c`. It reads `$HOME/.gitconfig` and `$XDG_CONFIG_HOME/git/config`,
repository includes and `config.worktree`. Put a test's global layer in XDG, not
in `GIT_CONFIG_GLOBAL`.
