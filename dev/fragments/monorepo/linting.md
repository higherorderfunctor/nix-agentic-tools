## Linting

> **Last verified:** 2026-08-31 (commit pending — full-corpus treefmt and hook
> diagnostics are detached from shell activation; serialized treefmt hooks now
> use their cache, while Stop keeps its two convergence passes uncached). Prior:
> 2026-08-29 (repository hooks now declare their local, Stop, and CI lifecycles
> once in `config/repo-validation.nix`; every code validator has a
> merge-blocking whole-corpus gate).

`nix flake check` is the authoritative CI gate. Local hooks provide earlier
feedback, but neither a successful changeset scan nor a `--no-verify` commit is
evidence that the tracked corpus is clean.

The source of truth is `config/repo-validation.nix`. Every hook declaration must
name its role, Stop participation, and CI backend (including an explicit `null`
for local-only commit-lifecycle hooks). Evaluation rejects a validator,
formatter, or security hook without CI coverage, and rejects a validator that
does not participate in Stop feedback. From that table the repo derives:

| Surface                    | Selection                                           | Scope                                                       | Authority                        |
| -------------------------- | --------------------------------------------------- | ----------------------------------------------------------- | -------------------------------- |
| Git hooks                  | each declaration's real Git stages                  | staged files / commit message                               | fast local feedback; bypassable  |
| Claude Stop                | `stop = "formatter"` or `"judgment"` → manual stage | unstaged ∪ staged ∪ untracked changes                       | agent feedback; not a merge gate |
| `checks.repo-lints`        | validators with `ci.backend = "git-hooks"`          | every matching tracked file                                 | required `test` context          |
| `checks.shellcheck-corpus` | validator with the specialized corpus backend       | every tracked extension- or shebang-identified shell script | required `test` context          |

The manual stage is a lifecycle boundary, not a synonym for pre-commit. It
contains treefmt plus the four code validators and therefore excludes convco,
gitleaks, treefmt-restage, and `reject-default-branch-commit`. Devenv
diagnostics and the Stop hook always request that stage explicitly; an unscoped
`prek run` must not be used for either. Stop may rewrite working-tree files but
never stages them. Index mutation belongs only to the pre-commit restager.

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
lose the intended warm-cache benefit. The Stop hook is the exception: it sets
`TREEFMT_NO_CACHE=true` for both formatter passes so the second pass proves the
first rewrite converged instead of accepting a cache hit as that proof.

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
- **Spelling:** cspell

**Commit-only hooks:**

- convco (commit message shape)
- gitleaks (staged secrets; mirrored by its standalone CI job)
- reject-default-branch-commit
- treefmt-restage (re-adds formatter changes only during pre-commit)

**Available in the devShell, wired to no gate:** agnix (agent config linting) —
run it by hand or via the agnix MCP server.

There is no shellharden in this repo, and no linter reads shell embedded in
`.nix` strings beyond `writeShellApplication`'s own checkPhase. See the Bash
coding standard for which sites that leaves unchecked.
