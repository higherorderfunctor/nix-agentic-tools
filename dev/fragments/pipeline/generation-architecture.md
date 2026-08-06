## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks, organized by
scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md, AGENTS.md,
  Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md, CONTRIBUTING.md) from
  fragments + nix-evaluated data
- `generate:all` — runs all scopes

Each task wraps a `nix build .#<derivation>` and copies output to the working
tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `config/fragment-categories.nix` — the fragment-category registry: each
  category's scope globs and fragment sources. Option declared in
  `lib/fragments-registry.nix`.
- `dev/fragments/` — dev-only instruction fragments. Composed into instruction
  files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by both devenv
  tasks and flake derivations.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published skill-routing rule.
- `lib/ai/transformers/` — AI ecosystem renderers, exported through the `lib/ai`
  barrel.

### What Stays in Module System

Skills and immutable CLI configuration generally use `files.*` (devenv) or
`home.file` (HM), producing symlinks to store paths with no repository
generation step. Runtime-writable files are an intentional exception: for
example, Codex's user `config.toml` is reconciled by Home Manager activation,
while project config remains statically owned by devenv. Codex named profile
files are immutable whole-file layers: Home Manager links them directly, while a
devenv pre-shell task safely materializes repository declarations into the user
CODEX_HOME where native `--profile` lookup requires them. That path is currently
unreachable — `ai.codex.profiles` is LOCKED OUT and fails evaluation (see the
lockout comment in `packages/chatgpt-codex/lib/mkCodex.nix`) — so no repository
here drives the materializer; it is described because the code is retained for
re-enablement. These app-level materialization tasks are separate from the
repository instruction generator described here.

Instruction files are the exception: they are **copies**, not symlinks,
materialized on every shell entry by `generate:instructions:materialize`
(`before = ["devenv:enterShell"]`). Kiro cannot read symlinked steering — it
discovers by scanning the directory and the scan skips symlinks — and the
git-tracked outputs cannot be symlinks either, since a store symlink commits as
an absolute `/nix/store` path. See the devenv files-internals fragment.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions + repo documents

# A leaf can be run directly when only one projection is intentionally wanted:
devenv tasks run generate:instructions:claude # just CLAUDE.md + rules
```

The aggregate form requires `--mode before`; without it devenv runs the named
aggregate but skips its dependency leaves.
