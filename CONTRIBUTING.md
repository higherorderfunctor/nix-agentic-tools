# Contributing to nix-agentic-tools

<!-- TODO: refine with maintainer input -->

## Development Setup

All tools are provided by the devenv shell. No global installs required.

```bash
devenv shell          # enter dev shell with all tools
```

## Build & Validation Commands

> **Last verified:** 2026-10-26 — context measurements estimate Copilot tuning
> costs; generation includes devenv.yaml; lock resolution remains an explicit
> network operation.

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural/module eval,
                              # runtime contracts, and validator corpus scans
                              # (does NOT build the package output set)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter the devenv shell with all tools
treefmt                       # Format all files (formats only — lints nothing)
devenv tasks run devenv:git-hooks:run # Manual-stage local all-files diagnostic

# Regenerate instructions, repo documents and devenv.yaml. `--mode before` is
# load-bearing: without it devenv runs the aggregate and skips the leaves.
devenv tasks run --mode before generate:all

# After adding or changing a flake input, sync its devenv lock (may use network).
devenv update <input>
```

For context tuning, run `bash dev/scripts/measure-context.sh` for corpus totals
or supply repository-relative paths, including deleted paths:

```bash
bash dev/scripts/measure-context.sh packages/chatgpt-codex/checks/module-eval.nix
```

The initial soft engineering target is **128 KiB for Copilot context plus
matched native instructions**, counting each file once: roughly 32K tokens at 4
bytes/token, with sensitivity about 26K–44K at 5–3 bytes/token. This chosen
target is neither a GitHub limit nor a pass/fail gate. Estimates exclude diff,
system, organization, and retrieved content; path matching approximates native
globs. Local `AGENTS.md` and its child indexes are excluded from Copilot totals.
Codex's configured project-document byte budget is a separate contract.

## Tests

```bash
devenv test           # run all devenv checks
nix flake check       # linters + evaluation (does NOT build packages)
```

## Generation Architecture

> **Last verified:** 2026-10-29 — shared guidance is individually named
> always-on rules, selected per runtime through existing rule disables. Copilot
> writes its own GitHub files and does not contribute to shared AGENTS.md. Local
> AGENTS.md and `.agents/rules/` are generated and gitignored; drift compares
> tracked GitHub instructions and human documents. `generate:all` waits on
> `ai:files-ready`, writes repo documents and devenv.yaml, and leaves
> devenv.lock to an explicit network update.
>
> **Settled — do not relitigate.** Rendering and writing the instruction files
> in the generator, beside `ai.*`, is what this replaced. The generator owned
> AGENTS.md, so disabling its runtime delivery dropped every Codex rule
> (Semble's CLI rule among them) with no diagnostic. One writer per file, and
> that writer is `ai.*`. Full lineage:
> `git show f77d34ac:dev/fragments/pipeline/generation-architecture.md`.

Two kinds of generated content, two owners:

- **Agent instructions** — `dev/generate.nix` returns `rules`: one named
  always-on rule per published coding-standard fragment and source in an
  unscoped registry category, plus one scoped rule per scoped category. Scoped
  rules carry composed text, scope globs as `matcher`, source documents as
  `references`, and the matcher-derived `fileMatch` default. `dev/ai.nix`
  assigns `ai.rules`; `ai.*` renders and writes enabled runtimes' files through
  its generated tree. Codex and Kimchi share local AGENTS.md, with a path-scoped
  index and readable child indexes under `.agents/rules/` when shorter. Claude
  receives `.claude/rules/`, and Copilot receives `.github/instructions/`. Kiro
  participates only in shared root AGENTS.md. All local instruction projections
  are gitignored; GitHub instructions are committed read-only copies. An
  explicitly declared unnamed Copilot context independently writes
  `.github/copilot-instructions.md`; this repository declares none.
- **Human documents** — README.md and CONTRIBUTING.md are not agent steering.
  `dev/repo-docs.nix` renders them from `dev/generate.nix` and builds each with
  the same builder as the agent files (`lib/generated.nix`'s `mkTree`, the
  evaluated treefmt config, and the same named guards `ai.guards` selects);
  `generate:repo:*` copies them out.

`dev/ai.nix` enables only github.com Copilot and bounds its reviewer
instructions with an explicit category allowlist and
`ai.copilot.github.rules.<name>.enable = false` for every other shared rule.
Newly registered categories stay out until selected. The operator's Home Manager
already provides the local runtimes and programs, so the committed devenv config
leaves them disabled. Contributors enable Claude, Codex, Kimchi, Kiro CLI, peer
communication and Semble in ignored `devenv.local.nix`; repository settings for
Claude, Codex, Kimchi, peer communication and Semble remain in `dev/ai.nix`.
Kiro is enabled locally only to probe the kiro-cli build on main. It receives no
repository skills, program rules or scoped steering; `dev/ai.nix` suppresses
those contributions next to their sources and declares no Kiro MCP servers,
hooks or environment. Its shared root AGENTS.md remains available, including the
always-loaded `architecture` category. The other local runtimes inherit all
named shared rules. The fragment-shadow guard accepts content-free runtime
disables but rejects same-key replacement text or sources, including disabled
replacements. Peer communication's Copilot disable remains part of its
repository settings; Semble excludes Copilot. Home Manager supplies
delegate-routing and the stacked-workflows router and skills.
`instructions-reviewer-policy` checks the emitted instruction set, always-on
metadata, the absence of Copilot from shared AGENTS.md, opted-in local content
retention, Kiro isolation, and the shadow guard.

`ai.*` genuinely cannot express the human documents: they are not context or
rules of any runtime. Everything instruction-shaped goes through `ai.*`.

Older checkouts may still hold instruction files the files engine never
recorded. The engine prunes only paths in its state, so those files can be
deleted by hand.

### Source Layout

- `dev/ai.nix` — this repository's `ai.*` configuration, imported by
  `devenv.nix` and evaluated by the drift check. Its generated trees use the
  default `ai.formatter`, which is this flake's exported treefmt module, so a
  committed file is already in the same house style as `nix fmt` produces.
- `dev/fragments/` — dev-only instruction fragments; its
  `architecture/architecture.md` is always-loaded repository architecture
  guidance, registered in `config/fragment-categories.nix`.
- `dev/generate.nix` — fragment composition into content, plus the two human
  documents.
- `lib/ai/transformers/` — the per-runtime renderers `ai.*` uses.
- `lib/facets/registry.nix` — native metadata assembly shared by flake and
  document generation. Workspace categories come from
  `config/fragment-categories.nix`; package categories and descriptions come
  from owner `registry.nix` files. Options live in `lib/fragments-registry.nix`
  and `lib/documentation.nix`.
- `packages/coding-standards/fragments/` — published coding standards, delivered
  as named rules.

### Committed files and the drift check

`checks/instructions/instructions-drift.nix` evaluates `dev/ai.nix` with both
`isCI` values and requires identical instruction plans. It compares the tracked
`.github/instructions/` tree and `.github/copilot-instructions.md` when
generated with the built files the Copilot writer's plan points at. README.md
and CONTRIBUTING.md compare against the `repo-*` packages. Local AGENTS.md and
child indexes have no tracked bytes to compare; generated composition, audience
rules and the configured Codex byte limit remain checked. `treefmt.nix` excludes
none of the committed instruction files: they come out of the generated tree in
the house format, and `checks.formatting` reads them like any tracked file.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions, repo docs, devenv.yaml
```

`generate:all` orders the instruction and repository projection writers:
`ai:files-ready`, by which the files engine has written the enabled runtimes'
instruction projections (the `.github/` files in the committed configuration);
then `devenv:files` for the other gitignored links, `generate:devenv-yaml`, and
`generate:repo`. It is not a second writer. The aggregate form requires
`--mode before`; without it devenv runs the named aggregate but skips its
dependency leaves.

`generate:devenv-yaml` projects the root flake inputs and their locked revisions
into devenv.yaml. After adding or changing an input, run `devenv update <input>`
to sync devenv.lock separately: resolving its transitive inputs can require
network access, so it is outside `generate:all`. The pure
`checks.devenv-inputs-drift` check compares devenv.yaml with its generator and
checks each declared input's locked rev and narHash against flake.lock,
resolving root edges rather than assuming lock node names match input names. It
reports the generation or lock-update command needed to repair drift. It
compares only each root input's own lock entry: transitive nodes can still
differ (today `go-overlay/git-hooks`, because `config/generate-devenv-yaml.nix`
emits only `nixpkgs` follows), and extra undeclared root inputs in devenv.lock
are ignored.

## Updating Dependencies

The `Update` workflow (`.github/workflows/update.yml`) sweeps every input and
package four times a day and opens one PR per dependency that moved. Run it on
demand, optionally for named targets:

```bash
gh workflow run update.yml -f targets=nixpkgs,agnix
```

Branch CI builds each update PR. A red one is a dependency that needs a fix
pushed to its `update/<name>` branch.

## Code Standards

Coding standards, ordering rules, DRY principle, and Bash strict mode are
documented in
[Coding Standards](packages/coding-standards/fragments/coding-standards.md).
Devshell activation generates each runtime's instructions from these named
sources; local `AGENTS.md` and `.agents/rules/` are generated and gitignored.

## Linting

Run the meta-formatter before committing:

```bash
treefmt              # format everything (formats only — lints nothing)
treefmt <file>       # format a single file after editing
```

Linting is separate from formatting: the linters (deadnix, statix, shellcheck,
cspell) run as prek pre-commit hooks on staged files, which `--no-verify` skips
locally.

`nix flake check` is the CI gate. Besides formatting, structural checks and
module evaluation, it runs the same linters over every tracked file
(`checks.repo-lints`, plus `checks.shellcheck-corpus`), so spelling is checked
in CI even when a local commit skipped the hooks.

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`,
`style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

## Adding a Package

### AI CLI or MCP Server

See [Packaging](docs/packaging.md) and the scoped architecture routing in the
devshell-generated `AGENTS.md` for recipe patterns and package-specific
guidance.

### General pattern

1. Create `packages/<owner>/packages/<namespace>/<name>/package.nix` with inline
   `rev` + `hash`
2. Add update, cache, and documentation entries to the owner's `registry.nix`
3. Put consumer modules, helpers, and checks in the same owner directory
4. Add HM and devenv modules in `packages/<owner>/modules/` when applicable
5. Run `nix flake check` to verify

See [Repository ownership and layout](docs/repository-layout.md) for a worked
tree. Register checks through the owner's native `checks.nix` module.

Owner discovery exports native package namespaces, flat flake packages, and
backend modules automatically. New owners need no root export entry.

See [Change Propagation](dev/fragments/monorepo/change-propagation.md) — when
removing or renaming a concept, all surfaces must be updated in the same commit.

## Adding a Fragment

Fragments are composable instruction blocks. `dev/generate.nix` composes them
into named rules that `ai.*` writes for every runtime (AGENTS.md, Claude,
Copilot, Kiro), and into CONTRIBUTING.md.

<!-- TODO: refine with maintainer input -->

| Fragment type                    | Location                                         | Exported? |
| -------------------------------- | ------------------------------------------------ | --------- |
| Dev-only (monorepo/tooling)      | `dev/fragments/<pkg>/<name>.md`                  | No        |
| Published coding standards       | `packages/coding-standards/fragments/<name>.md`  | Yes       |
| Published delegate-routing rule  | `packages/delegate-routing/fragments/<name>.md`  | Yes       |
| Published SWS skill-routing rule | `packages/stacked-workflows/fragments/<name>.md` | Yes       |

To add a dev-only fragment:

1. Create `dev/fragments/<pkg>/<name>.md`
2. Add the name to `config.fragments.categories.<pkg>.sources` in
   `config/fragment-categories.nix` (scope globs for the category live alongside
   it as `.scopes`)
3. Run `devenv tasks run --mode before generate:all` to regenerate

To add a published fragment (consumed by external users):

1. Create `packages/<owner>/fragments/<name>.md`
2. Use the owner's `lib/fragments.nix` directory discovery to expose the
   fragment through its native content recipe and public library. Existing
   content owners discover markdown files automatically.
3. If the fragment also belongs in this repository's generated instructions, add
   it to the relevant owner `registry.nix` category or workspace category in
   `config/fragment-categories.nix`
4. Run `devenv tasks run --mode before generate:all` to regenerate everything

## Pull Requests

<!-- TODO: refine with maintainer input -->

- One logical change per PR
- CI must pass (formatting, linting, spelling, module evaluation)
- Committed generated files (README.md, CONTRIBUTING.md, `.github/`
  instructions) must be regenerated if their source fragments changed: run
  `devenv tasks run --mode before generate:all`. `nix flake check` fails on
  drift.
- Keep commits atomic using the stacked workflow skills (`/stack-plan`,
  `/stack-fix`, `/stack-submit`)
