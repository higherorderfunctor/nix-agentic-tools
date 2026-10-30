# Diagnostic-lean devenv closure taxonomy

> **Last verified:** 2026-10-29 — the CI matrix reads `ciPackages`; the repo
> shell applies `buildOverlay`. Files-engine runtime checks cover delivery
> independently of local opt-ins.

The Devenv Diagnostic workflow (`.github/workflows/devenv-test.yml`) runs only
on `workflow_dispatch`. Its cold interactive shell closure is therefore an
operator-chosen diagnostic cost, not an automatic merge-path cost. The required
`test` context runs `nix flake check` and owns the deterministic invariants that
previously justified the runtime workflow:

- `instructions-drift` compares the committed instruction files with what the
  repository's `ai.*` entries deliver; `ai-module-files-ro-runtime` and
  `ai-module-transitions` prove copy type, mode, idempotence, adoption and
  retirement;
- `isolate-prek-hooks` executes the exact shared-hook rewriter in primary and
  linked worktrees;
- `repo-validation-policy`, `repo-lints`, and `shellcheck-corpus` prove
  lifecycle selection and scan the complete tracked validator corpus.

Home Manager supplies delegate-routing and the stacked-workflows router and
skills. Repository skills in `dev/ai.nix` cover project-specific operations;
`module-codex-skills-fanout` and `module-sws-skill-references-resolve` verify
the packages' delivery contracts independently of a developer's materialized
skill directories.

The repository no longer repeats instruction-file and Claude settings delivery
assertions in `enterTest`. ai-module's checks pin where the files plan lands
each file and by which method. Runtime checks execute the files engine on real
temporary directories, independently of a developer's checkout. The devenv
observer reports absent or changed native links without failing shell entry; it
reads the normalized plan and native link list only.

`devenv.nix` still evaluates an `isCI` branch for the manual diagnostic. It
omits tooling that enterTest never invokes, but it does not alter repository
validation declarations. A developer exporting `CI=1` gets fewer interactive
packages, never fewer guards.

`enterTest` no longer runs the full-corpus hook runner. The automatic flake
checks `repo-lints`, `formatting` and `shellcheck-corpus` cover those validators
from `config/repo-validation.nix`. The named `devenv:git-hooks:run` task remains
an explicit manual diagnostic using the same packaged runner and immutable
generated hook config. It is dependency-free: devenv's all-task traversal can
pull a sibling lane through a shared prerequisite, so adding activation edges
could make ordinary shell entry scan the full corpus.

## The five buckets

| Bucket                   | Examples                                               | Manual diagnostic closure?         | Automatic CI treatment                                |
| ------------------------ | ------------------------------------------------------ | ---------------------------------- | ----------------------------------------------------- |
| Diagnostic dependencies  | generation pipeline, coreutils-class tools, validators | yes                                | narrow flake checks realize only their declared tools |
| Interactive-only dev UX  | LSPs (`nixd`→llvm, `marksman`→dotnet, `taplo`)         | no — `lib.optionals (!isCI)`       | not invoked                                           |
| Validation hooks         | prek plus declared hook tools                          | yes — policy is unconditional      | validator-only projection; commit lifecycle excluded  |
| Factory CLI wrappers     | locally enabled launcher-bearing `ai.*` runtimes       | only with personal runtime opt-ins | package/build checks remain separate                  |
| Consumer overlay exports | `pkgs.ai.devTools.*`, MCP server packages              | never unless explicitly selected   | CI build matrix over `ciPackages`                     |

## The decision rule

Adding a package to `devenv.nix`? Ask whether the on-demand diagnostic invokes
it. If not, put interactive-only tooling in the `!isCI` list. Do not use that
branch for validation policy: automatic guards belong in flake checks with their
own narrow closures.

### Enabled runtimes with launcher packages enter the wrapper bucket

`lib/ai/app/mkBackendTransform.nix` installs each enabled runtime's non-null
launcher package: Claude, Codex, Kimchi and Kiro. github.com Copilot has no
launcher, so enabling it adds no runtime package to the closure. A consumer may
also set a launcher's package to null to keep configuration without installing
its binary. Repository runtime opt-ins and content selection are documented in
`dev/fragments/pipeline/generation-architecture.md`.

Measure the MARGINAL runtime cost: the store paths Kimchi adds to the existing
shell, excluding dependencies already present. Neither the executable's size
(which misses supporting assets) nor the full closure (which counts shared
dependencies again) measures that cost.

Kimchi now builds from source in
`packages/kimchi/packages/ai/kimchi/package.nix`. The former 1.0.10
binary-release measurements are obsolete; no current marginal size is recorded
here. Bun, pnpm and Go belong to the build inputs, so their download size is not
a runtime closure estimate. Measure the installed result and its actual
references.

Measure the marginal set on a bump rather than scaling any of these:

```bash
comm -23 \
  <(nix-store -qR "$(nix build --no-link --print-out-paths .#kimchi)" | sort) \
  <(nix-store -qR "$DEVENV_PROFILE" | sort)
```

For a locally enabled runtime, installation follows its `ai.*` enable and
package options. The shared installation block warns at shell entry when PATH
resolves that runtime outside the devenv profile.

### Harness permissions belong to each contributor

This repository's dev shell sets no harness permissions. Contributors set them
in their own user config. The repository declares only `project_doc_max_bytes`
for Codex project settings; the generated config also carries the module's model
and reasoning defaults. It does not override the user's approval policy or
permission profile. A Codex delegate that must run Nix needs a user config
without the workspace sandbox, because that sandbox blocks the Nix daemon
socket.

The `codexForRepository` wrapper that injected `--cd` and `--profile` remains
gone. Codex may still have an environment-only wrapper for `SHELL` and the
sandbox-safe Git SSH command.

Two earlier measurements still constrain any future project permission profile:

- **The old mixed model denied `~/.cache/nix`.** Automatic integration roots now
  lower into a selected custom permission profile as direct filesystem writes,
  so the later migration need not restate them by hand.
- **It ALLOWED the primary checkout's working tree.** The profile's own comment
  claimed it granted the shared Git directory "without granting write access to
  the main checkout's working files". `extends = ":workspace"` plus
  `:workspace_roots."." = "write"` made that false from the start. The stated
  security property never existed.

`dev/ai.nix` retains the Semble package, AWK and jq grammars, and mappings for
its non-standard Bash, Gitignore, JSON and Markdown paths. The retained
`install = !isCI` setting omits the package during the manual diagnostic while
keeping CLI guidance for enabled supported runtimes. The program delivers no MCP
server here. Its devenv facet owns and invalidates
`${config.devenv.state}/semble-cache`; this configuration uses that
project-local cache instead of the user-global cache.

Integration roots remain available to workspace-write and named-profile
consumers. The repository no longer asserts a Codex sandbox policy or repeats
the generic project-config delivery check in `enterTest`. A permission model
mixed across the user and project layers remains the ai module's shell-entry
warning. The old `--profile` wrapper and stale whole-file profile assertions are
gone: `ai.codex.profiles` was removed, and
`packages/chatgpt-codex/lib/launcher-flags.nix` owns the launcher flags.

With Semble enabled, contributors can verify the grammar/path-customized package
and project-local cache interactively; `CI=1` keeps its installation out of the
diagnostic closure.

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
