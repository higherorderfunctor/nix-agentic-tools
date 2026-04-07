# Contributing to nix-agentic-tools

<!-- TODO: refine with maintainer input -->

## Development Setup

All tools are provided by the devenv shell. No global installs required.

```bash
devenv shell          # enter dev shell with all tools
devenv up docs        # start doc preview at localhost:3000
```

## Build & Validation Commands

```bash
nix flake show                # List all outputs
nix flake check               # Linters + evaluation (does NOT build packages)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter devShell with all tools
nix run .#generate            # Regenerate instruction files from fragments
treefmt                       # Format all files (Nix, markdown, JSON, TOML, shell)
```

## Tests

```bash
devenv test           # run all devenv checks
nix flake check       # linters + evaluation (does NOT build packages)
```

## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks,
organized by scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md,
  AGENTS.md, Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md,
  CONTRIBUTING.md) from fragments + nix-evaluated data
- `generate:site:*` — doc site (mdbook) from authored prose +
  nix-evaluated reference pages and data snippets
- `generate:all` — runs all scopes

Each task wraps a `nix build .#<derivation>` and copies output to the
working tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `dev/docs/` — authored prose (getting-started guides, concepts,
  troubleshooting). Copied to `docs/src/` by `generate:site:prose`.
- `dev/fragments/` — dev-only instruction fragments. Composed into
  instruction files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by
  both devenv tasks and flake derivations.
- `docs/src/` — gitignored generated output. mdbook serves from here.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published routing table.
- `packages/fragments-ai/` — AI ecosystem transforms (passthru).
- `packages/fragments-docs/` — doc site transforms and generators
  (passthru).

### What Stays in Module System

Skills, settings.json, MCP config, and CLI settings use `files.*`
(devenv) or `home.file` (HM). These are symlinks to immutable store
paths — no generation step.

### Running Generation

```bash
devenv tasks run generate:instructions    # all instruction files
devenv tasks run generate:instructions:claude  # just CLAUDE.md + rules
devenv tasks run generate:repo            # README.md + CONTRIBUTING.md
devenv tasks run generate:site            # full doc site
devenv tasks run generate:all             # everything
```

## Updating Dependencies

```bash
devenv tasks run update:all   # update all nvfetcher sources and lock files
```

After updating, rebuild affected packages to verify hashes:

```bash
nix build .#<package>
```

If a hash mismatch occurs, copy the expected hash from the error and
update `packages/mcp-servers/hashes.json` (or the relevant sidecar).

## Code Standards

Coding standards, ordering rules, DRY principle, and Bash strict mode
are documented in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).
Do not duplicate — read those files first.

## Linting

Run the meta-formatter before committing:

```bash
treefmt              # format and lint everything
treefmt <file>       # format a single file after editing
```

All commits must pass `nix flake check` (includes formatting, linting,
spelling, structural checks, and module evaluation).

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`, `devshell`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

## Adding a Package

### AI CLI or MCP Server

See the **AI CLI Packages** and **MCP Server Packages** sections in
[AGENTS.md](AGENTS.md) for the full overlay pattern, nvfetcher
integration, and step-by-step instructions.

### General pattern

1. Add an nvfetcher entry in `nvfetcher.toml`
2. Run `nvfetcher` to update the generated sources
3. Create `packages/<group>/<name>.nix` using the appropriate builder
4. Register in `packages/<group>/default.nix`
5. Export in `flake.nix` under `packages`
6. Add a module under `modules/` (HM) and `modules/devenv/` (devenv)
7. Run `nix flake check` to verify

See [Change Propagation](AGENTS.md#change-propagation) — when removing
or renaming a concept, all surfaces must be updated in the same commit.

## Adding a Fragment

Fragments are composable instruction blocks used to build AI instruction
files (CLAUDE.md, AGENTS.md, Copilot, Kiro) and CONTRIBUTING.md.

<!-- TODO: refine with maintainer input -->

| Fragment type               | Location                                         | Exported? |
| --------------------------- | ------------------------------------------------ | --------- |
| Dev-only (monorepo/tooling) | `dev/fragments/<pkg>/<name>.md`                  | No        |
| Published coding standards  | `packages/coding-standards/fragments/<name>.md`  | Yes       |
| Published SWS routing table | `packages/stacked-workflows/fragments/<name>.md` | Yes       |

To add a dev-only fragment:

1. Create `dev/fragments/<pkg>/<name>.md`
2. Add the name to `devFragmentNames.<pkg>` in `dev/generate.nix`
3. Run `devenv tasks run generate:instructions` to regenerate

To add a published fragment (consumed by external users):

1. Create `packages/<pkg>/fragments/<name>.md`
2. Register it in `packages/<pkg>/default.nix` under `passthru.fragments`
3. Run `devenv tasks run generate:all` to regenerate everything

## Pull Requests

<!-- TODO: refine with maintainer input -->

- One logical change per PR
- CI must pass (formatting, linting, spelling, module evaluation)
- Generated files (CLAUDE.md, AGENTS.md, README.md, CONTRIBUTING.md,
  Copilot and Kiro instruction files) must be regenerated if their
  source fragments changed: run `devenv tasks run generate:all`
- Keep commits atomic using the stacked workflow skills
  (`/stack-plan`, `/stack-fix`, `/stack-submit`)
