# Diagnostic-lean devenv closure taxonomy

> **Last verified:** 2026-09-12 — source paths and ownership guidance follow
> native package assembly.
>
> Full lineage: `git show d1c28a21:dev/fragments/devenv/ci-lean-closure.md`.
>
> Branch measurement, 2026-09-03: the standard-library semantics interpreter
> dropped `transitions` from `grammarPython` (`devenv.nix`), taking that
> realized closure from 357,486,880 to 265,083,120 bytes.

The Devenv Diagnostic workflow (`.github/workflows/devenv-test.yml`) runs only
on `workflow_dispatch`. Its cold interactive shell closure is therefore an
operator-chosen diagnostic cost, not an automatic merge-path cost. The required
`test` context runs `nix flake check` and owns the deterministic invariants that
previously justified the runtime workflow:

- `instruction-materialization` executes the exact shell-entry copier against a
  temporary repository and proves byte equality, real-file type, mode,
  idempotence, repair, and stale-file pruning;
- `isolate-prek-hooks` executes the exact shared-hook rewriter in primary and
  linked worktrees;
- `repo-validation-policy`, `repo-lints`, and `shellcheck-corpus` prove
  lifecycle selection and scan the complete tracked validator corpus.

`devenv.nix` still evaluates an `isCI` branch for the manual diagnostic. It
omits tooling that enterTest never invokes, but it does not alter repository
validation declarations. A developer exporting `CI=1` gets fewer interactive
packages, never fewer guards.

The diagnostic's full-corpus manual-stage hook run lives in the `enterTest`
script, after shell-entry tasks have materialized files and installed hooks. It
does not live behind `devenv:enterTest` in the task DAG: a shared prerequisite
with the shell lane allowed devenv's all-task traversal to pull that sibling
into ordinary `devenv shell`. The named `devenv:git-hooks:run` task remains
available as a dependency-free manual diagnostic and executes the same packaged
runner against the immutable generated hook config.

## The five buckets

| Bucket                   | Examples                                               | Manual diagnostic closure?             | Automatic CI treatment                                |
| ------------------------ | ------------------------------------------------------ | -------------------------------------- | ----------------------------------------------------- |
| Diagnostic dependencies  | generation pipeline, coreutils-class tools, validators | yes                                    | narrow flake checks realize only their declared tools |
| Interactive-only dev UX  | LSPs (`nixd`→llvm, `marksman`→dotnet, `taplo`), Semble | no — `lib.optionals (!isCI)`           | not invoked                                           |
| Validation hooks         | prek plus declared hook tools                          | yes — policy is unconditional          | validator-only projection; commit lifecycle excluded  |
| Factory CLI wrappers     | all five `ai.*` runtimes (see note)                    | yes — enterTest exercises files fanout | package/build checks remain separate                  |
| Consumer overlay exports | `pkgs.ai.devTools.*`, MCP server packages              | never unless explicitly selected       | CI build matrix and cache-hit-parity                  |

## The decision rule

Adding a package to `devenv.nix`? Ask whether the on-demand diagnostic invokes
it. If not, put interactive-only tooling in the `!isCI` list. Do not use that
branch for validation policy: automatic guards belong in flake checks with their
own narrow closures.

### Every enabled `ai.*` runtime is in the wrapper bucket, unconditionally

The `Examples` column above used to name two wrappers and read as if the bucket
were selective. It is not: `lib/ai/app/mkBackendTransform.nix` installs a
package for every enabled runtime, so all five ride the closure whenever they
are enabled — codex, copilot and kiro always did, `claude` was supposed to and
did not (it installed on neither backend), and `kimchi` was enabled here on
2026-09-02.

The weight is real and worth stating rather than discovering — but state the
MARGINAL cost, which is neither the binary size nor the total closure. Measured
at kimchi 1.0.10, the version `packages/kimchi/sources.json` currently pins:

| figure                   | bytes           | what it means                              |
| ------------------------ | --------------- | ------------------------------------------ |
| `bin/kimchi` alone       | 116,974,792     | what a naive `stat` reports                |
| **kimchi's output path** | **124,037,485** | **the only path not already in the shell** |
| total closure            | 161,764,840     | includes deps every other package shares   |

Quote the middle row. kimchi's closure is 5 store paths and **4 were already
present** in the pre-change devenv profile — glibc and friends, there for
everything else — so the shell gains one path, not a whole closure.

Both neighbouring figures have shipped here as the answer, wrong in opposite
directions: the binary size is too low (it misses the rest of the output path),
and the total closure is too high by ~36 MiB (it bills shared dependencies to
whichever package happens to be measured). Neither is what adding this to the
shell costs.

Measure the marginal set on a bump rather than scaling any of these:

```bash
comm -23 \
  <(nix-store -qR "$(nix build --no-link --print-out-paths .#kimchi)" | sort) \
  <(nix-store -qR "$DEVENV_PROFILE" | sort)
```

It is unconditional — no `!isCI` guard, by design. If that closure growth ever
becomes unacceptable, the answer is `ai.kimchi.enable`, not an `!isCI` branch;
the decision rule above forbids using that branch for anything a guard depends
on, and enterTest asserts these binaries are on PATH.

### Codex uses an unrestricted project override

This repository used to supply a `codexForRepository` wrapper through
`ai.codex.package`, injecting `--cd` and `--profile nix-agentic-tools` for
runtime command families only. That argument-injecting wrapper remains gone.
Codex may still have an environment-only wrapper for `SHELL` and the
sandbox-safe Git SSH command, but the selected permission policy lives in the
normal user/project config stack rather than a separate `--profile` config
layer.

Named permission tables are now supported by the module and same-named tables
merge across user and project layers. They do not compose with legacy
`sandbox_mode` settings anywhere in the loaded stack, however. The Home Manager
user layer has migrated to `default_permissions = "user-default"`; this project
nevertheless selects `sandbox_mode = "danger-full-access"` as a temporary,
explicit override while unrestricted execution is needed here. With
`approval_policy = "never"`, Codex 0.151.0's doctor reports an unrestricted
filesystem sandbox and no approval prompts. Two earlier measurements still
constrain any future return to a project permission profile:

- **The old mixed model denied `~/.cache/nix`.** Automatic integration roots now
  lower into a selected custom permission profile as direct filesystem writes,
  so the later migration need not restate them by hand.
- **It ALLOWED the primary checkout's working tree.** The profile's own comment
  claimed it granted the shared Git directory "without granting write access to
  the main checkout's working files". `extends = ":workspace"` plus
  `:workspace_roots."." = "write"` made that false from the start. The stated
  security property never existed.

The unrestricted override needs no writable-root declarations. The repository
enables Semble only outside diagnostic mode, pins it to this flake, adds AWK and
jq Tree-sitter grammars, and maps its non-standard Bash, Gitignore, JSON, and
Markdown paths. Its devenv facet still owns and invalidates
`${config.devenv.state}/semble-cache`; its instruction facet stays off because
the tracked, fragment-generated `AGENTS.md` already carries the same search
workflow and devenv cannot replace that real file with a `files.*` symlink. The
user-global cache is no longer in play for this shell. Keeping
`ai.codex.programs.semble.enable = !isCI` is load-bearing: the manual diagnostic
does not invoke Semble and must not realize its model, MCP, or grammar closure.

Integration roots remain available to normal workspace-write and named-profile
consumers, but this project override intentionally does not use them. enterTest
asserts that the wrapper injects no `--profile`, the project config selects
`danger-full-access` without workspace refinements or named permission keys, and
no stale whole-file profile remains in `CODEX_HOME`.

Two proofs to preserve when touching the diagnostic: with `CI` unset the shell
must contain grammar/path-customized Semble and its scoped cache root, while an
on-demand `CI=1 devenv test` must stay green without either in that closure.

## The manual diagnostic carries #821 telemetry

The manual `devenv-test.yml` workflow records a run-context file before
`devenv test`, runs devenv with `--no-tui --trace-to json:file:… --verbose`,
takes a forensic snapshot on any non-success outcome, and uploads all of it as
one 7-day artifact. It is diagnostics for issue #821 (an intermittent
`path '/nix/store/…-references' is not valid` during shell configuration), not a
fix, and it changes nothing about the shell closure.

Why each individual choice is the way it is — uploading on success, the shared
telemetry directory, the cancellation arm on the snapshot's `if:`, the
strict-mode header alongside a `probe` helper that turns exit status into data,
and the tiered store-path parse — is commented at the site in `devenv-test.yml`.
Read it there; it is not restated here.

One coupling is invisible from either end, which is the only reason it is
written down at all: **the cache step's `id: nix-cache` is load-bearing.** The
run-context step reads that step's restore outputs, and nothing at the cache
step hints that anything depends on its id. Removing or renaming it blanks those
fields silently — the run-context file still writes, with empty values. (Which
outputs, specifically, is left to the workflow: enumerating them here is how
this paragraph would rot the next time one is added.)
