# CI-lean closure taxonomy

> **Last verified:** 2026-08-17 (commit pending — the repository moved from the
> legacy Codex sandbox to the mergeable `repo-worktrees` permission profile; the
> common Git directory is a direct filesystem grant, sibling worktrees are
> workspace roots, and module/integration caches lower into the selected named
> profile). Prior: 2026-08-15 (commit pending — the interactive-only Semble gate
> moved unchanged to `ai.codex.programs.semble.enable`; grammar and path
> customization now follow the same generated runtime program tree). Prior:
> 2026-08-14 (commit pending — the local shell now enables the flake-pinned
> Semble module with AWK and jq parsers plus repository path mappings, while the
> `!isCI` gate keeps the CI devenv-test closure unchanged). Prior: 2026-08-12
> (commit pending — the job now carries always-on telemetry for issue #821's
> intermittent local-source store-path failure. The closure taxonomy below is
> untouched: nothing was added to the shell, and the cache key, prefix fallback
> and `gc-max-store-size-linux` bound are all unchanged. The new section at the
> end records only the ONE fact about that telemetry that is invisible from the
> code — the cache step now carries `id: nix-cache` because a later step reads
> its restore outputs. Every other rationale is commented at its own site in
> `devenv-test.yml` and is deliberately NOT restated here; a fragment that
> duplicates a comment is a second copy to keep true). Prior: 2026-08-05 (commit
> pending — the repo-aware Codex wrapper and the `nix-agentic-tools` permission
> profile are both DELETED; this shell converges on the legacy `workspace-write`
> sandbox that every other repository the maintainer runs already uses, and the
> beta permission model is locked out at the factory. Two measured facts drove
> it, both from `codex sandbox` on 0.146.1 with no model in the loop: the
> profile denied `~/.cache/nix` while the identical grant was live everywhere
> else, and it ALLOWED the primary checkout's working tree, which is the
> opposite of what its own comment claimed). Prior: 2026-08-05 (commit pending —
> records that `devenv-test` remains always-reporting but is no longer required
> by branch protection; the path-filter constraint is therefore optional rather
> than load-bearing). Prior: 2026-08-03 (commit pending — makes `devenv-test` an
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

The `devenv-test` CI gate (`.github/workflows/devenv-test.yml`) runs
`devenv test` on ephemeral runners, so **everything in the shell closure is
download cost on every cold run** and feeds the `cache-nix-action` cache size.
`devenv.nix` therefore evaluates an `isCI` branch (see the comment block at its
`isCI` binding — EVAL-time, distinct from the RUNTIME `$CI` guard in
`processes.docs.exec`).

The job reports on every pull request rather than carrying a
`pull_request.paths` filter: its first step queries the changed files and every
closure-producing step is conditional on the same path set. An irrelevant pull
request therefore reports success after one API call; a relevant one still pays
for and waits on the runtime gate. Pushes to `main` retain the workflow-level
path filter because they are not merge gates.

**The constraint that FORCED this shape is gone, but the shape remains.** It was
built because branch protection required the `devenv-test` context, and GitHub
leaves a required context pending forever when its workflow never starts — so a
paths filter would have deadlocked every unrelated PR. `devenv-test` was
un-required on 2026-08-05 (see the git-workflow fragment), so a workflow-level
paths filter is now _possible_ again. It has not been reinstated, and the
always-report shape is still the cheaper thing to reason about. If you do
reinstate one, re-check the ruleset first — putting the context back under
branch protection while a paths filter is live would resurrect exactly the
deadlock this design was built to avoid.

## The four buckets

| Bucket                   | Examples                                                                  | CI closure?                                                                                                                                            | Where decided                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Gate dependencies        | generation pipeline, coreutils-class tools, `check-jsonschema`, `cspell`… | YES — unconditional `packages`                                                                                                                         | the gate runs materialize tasks + enterTest; these feed them                                                          |
| Interactive-only dev UX  | LSPs (`nixd`→llvm, `marksman`→dotnet, `taplo`), git-hooks suite           | NO — `lib.optionals (!isCI)` / `lib.optionalAttrs (!isCI)`                                                                                             | humans use them; CI never invokes them                                                                                |
| Factory CLI wrappers     | kiro-cli-wrapped (~693 MB), copilot-cli (~219 MB)                         | YES (currently) — ride in via `mkKiro`/`mkCopilot` whenever `ai.*` modules are enabled, and enterTest needs the modules enabled for their files fanout | gating the PACKAGE needs a factory-level option (HM-parity implications) — open decision, deliberately not improvised |
| Consumer overlay exports | `pkgs.ai.devTools.*`, MCP server packages                                 | NEVER in the shell                                                                                                                                     | they are shipped artifacts: built by the CI `build` matrix (`.#packages`) and `cache-hit-parity`, not shell members   |

## The decision rule

Adding a package to `devenv.nix`? Ask: **does the CI gate (materialize tasks +
enterTest assertions) invoke it?** If not, it goes in the `!isCI` list. When in
doubt, `CI=1 devenv test` locally is the oracle — green means the gate never
needed it.

### Codex ships unwrapped, on a named permission profile

This repository used to supply a `codexForRepository` wrapper through
`ai.codex.package`, injecting `--cd` and `--profile nix-agentic-tools` for
runtime command families only. The wrapper remains gone: Codex is the plain
package, and the selected permission policy lives in the normal user/project
config stack rather than a separate `--profile` config layer. The project uses
`default_permissions = "repo-worktrees"`, the same named policy as Home Manager.
Codex merges entries under the same permission-profile name across those layers.

The earlier named-profile attempt failed because a legacy
`sandbox_mode = "workspace-write"` remained in the user layer. Codex does not
compose the legacy and named models, so that configuration dropped the named
policy rather than merging it. The current design removes legacy settings from
every owned layer. Two measurements still constrain its shape:

- **The old mixed model denied `~/.cache/nix`.** Automatic integration roots now
  lower into the selected custom permission profile as direct filesystem writes,
  so user and project contributions survive their layer boundary.
- **It ALLOWED the primary checkout's working tree.** The profile's own comment
  claimed it granted the shared Git directory "without granting write access to
  the main checkout's working files". `extends = ":workspace"` plus
  `:workspace_roots."." = "write"` made that false from the start. The stated
  security property never existed.

`devenv.nix` declares the topology the factory cannot infer: the sibling
worktree collection is a workspace root, while the shared common Git directory
is a direct filesystem grant. Keeping the latter out of `workspace_roots`
prevents Codex from synthesizing `<common-dir>/.git`, the path that makes
git-branchless fail in linked worktrees. The repository enables Semble only
outside CI, pins it to this flake, adds AWK and jq Tree-sitter grammars, and
maps its non-standard Bash, Gitignore, JSON, and Markdown paths. Its devenv
facet contributes `${config.devenv.state}/semble-cache` automatically and
invalidates indexes in that scoped root when the effective package changes. Its
instruction facet stays off because the tracked, fragment-generated `AGENTS.md`
already carries the same search workflow and devenv cannot replace that real
file with a `files.*` symlink. The user-global cache is no longer in play for
this shell. Keeping `ai.codex.programs.semble.enable = !isCI` is load-bearing:
the CI gate does not invoke Semble and must not realize its model, MCP, or
grammar closure.

The effective Nix cache root and scoped Semble cache are contributed by their
owning devenv modules and must not be hand-written. The shared common Git
directory is explicit repository-topology policy; the linked-worktree `.git`
pointer must stay absent. enterTest asserts the wrapper injects no `--profile`,
that the project config selects `repo-worktrees` and carries no legacy sandbox
keys, that no stale whole-file profile remains in `CODEX_HOME`, and that the
direct filesystem/workspace roots are present (the interactive-only Semble root
is deliberately absent in CI).

Two proofs to preserve when touching the gates: with `CI` unset the shell must
contain grammar/path-customized Semble and its scoped cache root, while
`CI=1 devenv test` must stay green without either in the CI closure.

## The job also carries always-on #821 telemetry

`devenv-test.yml` records a run-context file before `devenv test`, runs devenv
with `--no-tui --trace-to json:file:… --verbose`, takes a forensic snapshot on
any non-success outcome, and uploads all of it as one 7-day artifact. It is
diagnostics for issue #821 (an intermittent
`path '/nix/store/…-references' is not valid` during shell configuration), not a
fix, and it changes nothing about the shell closure.

Why each individual choice is the way it is — uploading on success, the compound
scope gate, the cancellation arm on the snapshot's `if:`, the strict-mode header
alongside a `probe` helper that turns exit status into data, the tiered
store-path parse — is commented at the site in `devenv-test.yml`. Read it there;
it is not restated here.

One coupling is invisible from either end, which is the only reason it is
written down at all: **the cache step's `id: nix-cache` is load-bearing.** The
run-context step reads that step's restore outputs, and nothing at the cache
step hints that anything depends on its id. Removing or renaming it blanks those
fields silently — the run-context file still writes, with empty values. (Which
outputs, specifically, is left to the workflow: enumerating them here is how
this paragraph would rot the next time one is added.)
