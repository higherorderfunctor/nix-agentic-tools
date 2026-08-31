# Diagnostic-lean devenv closure taxonomy

> **Last verified:** 2026-08-31 (commit pending — full-corpus validation moved
> out of the activation task graph and into enterTest after shell setup; normal
> shell entry now performs activation setup without full-corpus scans). Prior:
> 2026-08-30 (the Home Manager layer has migrated to named permissions, while
> this repository temporarily selects `danger-full-access`; the obsolete
> workspace-write roots and diagnostic assertions are gone). Prior: 2026-08-29
> (`devenv test` is now an on-demand diagnostic instead of an automatic PR/push
> workflow. Deterministic instruction-copy, shared-hook-isolation, and
> validation-projection contracts moved under `nix flake check`; `$CI` no longer
> removes validation hooks). Prior: 2026-08-17 (commit pending — the staged
> Codex named-profile migration now receives the canonical Git common directory
> automatically, including from linked worktrees, while this repository's
> still-legacy config retains its existing `.git` workspace root until the
> separate migration). Prior: 2026-08-17 (commit pending — enabled treefmt now
> contributes its effective cache through the same permission-model-aware Codex
> root pool; enterTest expects five local roots and four in CI). Prior:
> 2026-08-17 (commit pending — named Codex permission tables are enabled at the
> module boundary, but this repository deliberately remains on legacy
> workspace-write until its Home Manager user layer migrates first; Codex does
> not compose the two models across config layers). Prior: 2026-08-15 (commit
> pending — the interactive-only Semble gate moved unchanged to
> `ai.codex.programs.semble.enable`; grammar and path customization now follow
> the same generated runtime program tree). Prior: 2026-08-14 (commit pending —
> the local shell now enables the flake-pinned Semble module with AWK and jq
> parsers plus repository path mappings, while the `!isCI` gate keeps the CI
> devenv-test closure unchanged). Prior: 2026-08-12 (commit pending — the job
> now carries always-on telemetry for issue #821's intermittent local-source
> store-path failure. The closure taxonomy below is untouched: nothing was added
> to the shell, and the cache key, prefix fallback and `gc-max-store-size-linux`
> bound are all unchanged. The new section at the end records only the ONE fact
> about that telemetry that is invisible from the code — the cache step now
> carries `id: nix-cache` because a later step reads its restore outputs. Every
> other rationale is commented at its own site in `devenv-test.yml` and is
> deliberately NOT restated here; a fragment that duplicates a comment is a
> second copy to keep true). Prior: 2026-08-05 (commit pending — the repo-aware
> Codex wrapper and the `nix-agentic-tools` permission profile are both DELETED;
> this shell converges on the legacy `workspace-write` sandbox that every other
> repository the maintainer runs already uses, and the beta permission model is
> locked out at the factory. Two measured facts drove it, both from
> `codex sandbox` on 0.146.1 with no model in the loop: the profile denied
> `~/.cache/nix` while the identical grant was live everywhere else, and it
> ALLOWED the primary checkout's working tree, which is the opposite of what its
> own comment claimed). Prior: 2026-08-05 (commit pending — records that
> `devenv-test` remains always-reporting but is no longer required by branch
> protection; the path-filter constraint is therefore optional rather than
> load-bearing). Prior: 2026-08-03 (commit pending — makes `devenv-test` an
> always-reporting required context while preserving the cold closure only for
> relevant paths). Prior: 2026-08-03 (commit pending — updates the
> consumer-export taxonomy after dev tools move beneath `pkgs.ai.devTools`;
> shell membership is unchanged). Prior: 2026-08-02 (commit pending — the repo's
> beta Codex permission profile explicitly grants the user-global Semble cache
> because beta profiles do not compose with the legacy user sandbox table).
> Prior: 2026-08-02 (commit pending — the repo-aware Codex wrapper now
> distinguishes runtime commands from administrative commands before injecting
> the worktree root and named profile; an argv-probe build lets enterTest verify
> runtime injection (including `apply` and `exec-server`) and doctor
> pass-through exactly). Prior: 2026-08-02 (PR #698 — introduced the wrapper and
> verified PATH precedence plus explicit-flag idempotence). Prior: 2026-07-22
> (PR #439). If you change what `devenv.nix` puts in the shell, which factories
> install CLI wrappers, or the `devenv-test.yml` cache wiring, re-verify this
> and bump the marker.

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
| Factory CLI wrappers     | kiro-cli-wrapped, copilot-cli                          | yes — enterTest exercises files fanout | package/build checks remain separate                  |
| Consumer overlay exports | `pkgs.ai.devTools.*`, MCP server packages              | never unless explicitly selected       | CI build matrix and cache-hit-parity                  |

## The decision rule

Adding a package to `devenv.nix`? Ask whether the on-demand diagnostic invokes
it. If not, put interactive-only tooling in the `!isCI` list. Do not use that
branch for validation policy: automatic guards belong in flake checks with their
own narrow closures.

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
