# git-branchless config extraction

> **Last verified:** 2026-10-07 — the extractor emits facts only and the rows
> file fills them in Nix; 24 `branchless.*` keys (23 typed options), 17 foreign
> keys, 36 builtin revset functions; 41 mutants fail closed or move the output
> as declared.
>
> **Settled — do not relitigate.**
>
> - **No self-report exists.** git-branchless has no `config` subcommand, and
>   its `--help` and man pages name two keys. Structured extraction is the top
>   usable rung.
> - **Walk the tree; never regex the code.** The first version located sites
>   with ast-grep rules and then parsed the matched text with ~30 regexes
>   (literals, `format!` arguments, `Option<T>`, closures, the `FUNCTIONS`
>   table). That text parsing broke on a `>` inside a `format!` argument (mutant
>   N4) and was replaced on 2026-09-29 by typed-node walks. Regex survives only
>   over decoded prose: the key-token net over string VALUES and the
>   `(deprecated)` marker in doc text. Old version:
>   `git show b56c7fca:packages/git-branchless/extract/extract.py`.
> - **Extract from the PATCHED source.** The unpatched tree misses
>   `branchless.core.protectCheckedOutBranches`, which only this repository's
>   patch reads.
> - **`test.jobs` does not imply the worktree strategy.** Only the command-line
>   `--jobs` above 1 switches strategy; a configured value above 1 with
>   `test.strategy = working-copy` fails every `git test run` (measured
>   2026-09-29). The prototype's annotation said otherwise and was wrong.
> - **No config key or revset alias scopes bare `git sync`.** `sync.rs:31-46`
>   queries draft commits directly, and builtins resolve before aliases in
>   `eval.rs:185-189`; use the Git alias documented in the git fragment.

## Pipeline

`passthru.extracted` on the package (`packages/ai/gitTools/git-branchless/`)
runs over `passthru.patchedSource`, a `srcOnly` of the package's own `src`,
`patches` and `postPatch` under `stdenvNoCC`. Both come from
`lib/git-tool-settings/extraction.nix`, shared with git-absorb and git-revise.
It never builds Rust, and passthru leaves the package's store path alone.

1. `extract/extract.py` — the resolver. It parses every production `.rs` file
   with tree-sitter-rust (`lib/git-tool-settings/rust_tree.py`), reads call
   shapes, keys, defaults and types from typed nodes, writes `extracted.json`
   (facts only) and exits non-zero on any guard.
2. `extract/annotations.json` — the rows file, the only hand input, applied in
   Nix by `lib/git-tool-settings/rules.nix`: a row per key (`{}` when the facts
   suffice), prose the source cannot state (computed defaults, alias-family
   descriptions, the patch note), types for two untyped reads, and a `reason`
   per dead key.

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
- `deadKeys` — key-shaped consts nothing reads; the reason is a row.
- `revsetFunctions` — the builtin `FUNCTIONS` table. It is consulted before
  `branchless.revsets.alias.*`, so an alias with a builtin's name is dead.

`<name>` marks a family (`branchless.test.alias.<name>`).

## Guards

| Code | Fails when                                                                                                      |
| ---- | --------------------------------------------------------------------------------------------------------------- |
| F1   | a call on a config handle matches no recognised shape, or a UFCS call                                           |
| F2   | a key expression is unresolvable, or a key-returning fn has a non-literal match arm                             |
| F5   | the `ConfigRead`/`ConfigWrite` methods or `GetConfigValue` types change                                         |
| F6   | raw git2 config access outside the allowlist                                                                    |
| F7   | a `["config", …]` git argv has a non-literal element                                                            |
| F9   | a production string literal names a `branchless.*` key no recognised read or write extracts (the net)           |
| F10  | a handle is obtained where no key is extracted and not handed to a Config-typed parameter, or stored in a field |
| F11  | a test cfg other than exactly `#[cfg(test)]`                                                                    |
| F12  | a default is neither a literal, an enum variant, nor a literal const                                            |
| F13  | two reads of one key disagree on type, enum values or default                                                   |
| F14  | the `FUNCTIONS` table changes shape, or aliases are no longer looked up after it                                |
| F15  | fewer than 20 current settings or 20 revset functions (the scan went blind)                                     |

Test code is whatever `#[cfg(test)]` or `#[test]` marks, plus `tests/`,
`benches/` and `testing.rs`, filtered once in `rust_tree.py` for every step.

F9 is the broad net: literals inside macros, closures and helper fns are still
string nodes in the tree (a macro's token tree keeps them typed), so a read the
resolver cannot follow still leaves its key in a literal. It does not catch a
key built entirely at run time without a `branchless.` literal.

A read with no type, a key with no description, a new dead key, and a row whose
key is gone are not guards: they fail the drift check through the rows rule (see
the git-tool-settings fragment).

`checks/extractor-mutants.nix` holds one upstream-shaped change per guard and
per known blind spot; `git-branchless-extractor-guards` runs them through
`lib/git-tool-settings/mutate.py`. Add a mutant with every new guard, and one
that a naive text pattern would get wrong for every remaining regex (the N
series).

## Checks

- `git-branchless-extracted` — the committed sidecar equals a fresh extraction,
  and the rows rule passes over it.
- `git-branchless-extractor-guards` — the mutants.
- `git-branchless-extracted-binary` — every extracted key (a family by its
  literal prefix) is a string in the built binary.
- `git-branchless-settings-options` — the tool's hand tables over the real
  sidecar and over fixtures.

## Generator

`lib/default.nix` exports `lib.git-branchless.settings`: the shared generator
(`lib/git-tool-settings`, see its fragment) over the committed sidecar, plus
this tool's two hand tables. Both report stale rows:

- `exclusions` — `branchless.mainBranch`, the legacy key `init` makes inert.
- `refinements` — `test.jobs` to `0..2^31-1`, and revset alias names that are
  not builtins (compared case-insensitively against `revsetFunctions`).

`checks/settings-options.nix` runs the generator over fixture sidecars for the
branchless-specific cases (enum widening, a new builtin, the jobs range, alias
names).

## Regeneration

git-branchless is owned by its flake input, so `mkUpdateScript` never runs for
it. `passthru.regenerateExtracted` (`packageLib.mkRegenerateExtracted`) is run
by `dev/scripts/update-input.sh git-branchless` through discovery; see the
update pipeline fragment. Locally, from the repository root:

```bash
"$(nix build --no-link --print-out-paths .#git-branchless.passthru.regenerateExtracted)"
```

## Reading the tool's config at run time

git-branchless reads config through libgit2, which ignores `GIT_CONFIG_GLOBAL`
and `git -c`. It reads `$HOME/.gitconfig` and `$XDG_CONFIG_HOME/git/config`,
repository includes and `config.worktree`. Put a test's global layer in XDG, not
in `GIT_CONFIG_GLOBAL`.
