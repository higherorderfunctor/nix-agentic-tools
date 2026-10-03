## Linting

> **Last verified:** 2026-10-03 — local and CI cspell hooks tolerate batches
> excluded entirely by ignorePaths while still failing spelling errors; the
> separate shellcheck backend retains its empty-corpus guard. Full lineage:
> `git show f7189d05:dev/fragments/monorepo/linting.md`.

`nix flake check` is the authoritative CI gate. Local hooks provide earlier
feedback, but neither a successful changeset scan nor a `--no-verify` commit is
evidence that the tracked corpus is clean.

The source of truth is `config/repo-validation.nix`. Every hook declaration must
name its role and CI backend (including an explicit `null` for local-only
commit-lifecycle hooks). Evaluation rejects a validator, formatter, or security
hook without CI coverage. From that table the repo derives:

| Surface                    | Selection                                                      | Scope                                                       | Authority                       |
| -------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------- |
| Git hooks                  | each declaration's real Git stages; treefmt runs at pre-commit | staged files / commit message                               | fast local feedback; bypassable |
| `checks.formatting`        | treefmt's formatter check                                      | every tracked file selected by treefmt                      | required `test` context         |
| `checks.repo-lints`        | validators with `ci.backend = "git-hooks"`                     | every matching tracked file                                 | required `test` context         |
| `checks.shellcheck-corpus` | validator with the specialized corpus backend                  | every tracked extension- or shebang-identified shell script | required `test` context         |

The manual stage belongs to the devenv diagnostic. It contains treefmt plus the
code validators and therefore excludes convco, gitleaks, treefmt-restage, and
`reject-default-branch-commit`. The diagnostic always requests that stage
explicitly; an unscoped `prek run` must not be used for it. Index mutation
belongs only to the pre-commit restager.

Full-corpus work is not a shell-entry concern. `devenv:treefmt:run` and
`devenv:git-hooks:run` remain explicit named diagnostics with no activation DAG
edges. `devenv test` invokes the same packaged hook runner only after
shell-entry tasks finish, before its runtime smoke assertions. This placement is
deliberate: devenv's `RunMode::All` can traverse from a shared prerequisite into
a sibling lane, so leaving the hook task behind `devenv:git-hooks:install` made
ordinary shell activation run the full repository even though the hook task
targeted `devenv:enterTest`.

The treefmt hook enables treefmt's SQLite evaluation cache and sets
`require_serial = true`. prek otherwise partitions the files across concurrent
treefmt processes; those processes contend on one cache database, time out, and
lose the intended warm-cache benefit.

Formatters and linters remain separate — treefmt formats and lints nothing.

**Formatters — treefmt, all write in place:**

- **JS/TS/JSX/JSON/CSS:** biome
- **Markdown/YAML and friends:** prettier (`proseWrap = "always"`)
- **Nix:** alejandra
- **Shell:** shfmt (`*.sh`, `*.bash` — extension globs only, so it never sees an
  extensionless script, shell embedded in a `.nix` string, or a heredoc body)
- **TOML:** taplo

**Code validators — local changeset feedback plus CI corpus gates:**

- **Nix:** deadnix (dead code), statix (anti-patterns)
- **Shell:** `shellcheck -x` with the shared opt-in flags from
  `config/shell-strict.nix`. The specialized CI scanner deliberately covers a
  superset of prek's file tagging and hard-fails an empty corpus.
- **Spelling:** cspell uses `--no-must-find-files` because a commit whose staged
  files are all excluded by `ignorePaths`, or one of prek's parallel filename
  batches made only of such files, otherwise exits 1 with nothing checked. Both
  local hooks and `checks.repo-lints` use this invocation; spelling issues still
  fail. There is no separate empty-corpus guard for cspell.

**Commit-only hooks:**

- convco (commit message shape)
- gitleaks (staged secrets; mirrored by its standalone CI job)
- reject-default-branch-commit
- treefmt-restage (re-adds formatter changes only during pre-commit)

**Available in the devenv shell, wired to no gate:** agnix (agent config
linting) — run it by hand or via the agnix MCP server.

There is no shellharden in this repo, and no linter reads shell embedded in
`.nix` strings beyond `writeShellApplication`'s own checkPhase. See the Bash
coding standard for which sites that leaves unchecked.
