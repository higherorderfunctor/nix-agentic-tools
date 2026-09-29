# Nix Workflow Reference

Conventions and gotchas for working with Nix in this repository.

## Stage Before Nix Commands

Nix flakes only see git-tracked files. **Always `git add` new (untracked) files
before running any Nix command that references them.** This includes:

- `nix build`, `nix develop`, `nix flake check`
- `nix eval` (e.g., `nix eval --raw .#lib.ai.apps.mkClaude`)
- Any command that runs inside `nix develop --command ...`

Untracked files are invisible to the flake. A build failure with "No such file
or directory" for a file you just created means it hasn't been staged.

```bash
# Wrong: file exists but Nix can't see it
echo '...' > packages/new-tool/packages/ai/new-tool/package.nix
nix build  # fails: file not found

# Right: stage first
echo '...' > packages/new-tool/packages/ai/new-tool/package.nix
git add packages/new-tool/packages/ai/new-tool/package.nix
nix build  # works
```

## Devenv Shell

Enter the development environment:

```bash
devenv shell    # or: direnv allow (auto-activates on cd)
```

This provides all tools: git-branchless, git-absorb, git-revise, agnix, treefmt
(alejandra, prettier, taplo, biome), cspell.

## Adding a Package

1. **Create `packages/<owner>/packages/<namespace>/<name>/package.nix`** —
   follow the source and hash patterns in
   [Packaging](../../../docs/packaging.md)
2. **Co-locate consumer modules, helpers, and checks** in the owner directory;
   owner discovery supplies the overlay, flat outputs, and backend imports
3. **Declare update and cache metadata** in the owner's `registry.nix`; keep
   workspace-only development tools in the repository shell
4. **Run `nix flake check`** to verify

### Patterns by language

- **Rust**: `buildRustPackage` + `cargoHash` (see
  `packages/agnix/packages/ai/agnix/package.nix`)
- **Python**: `buildPythonApplication` + pyproject (see
  `packages/git-revise/packages/ai/gitTools/git-revise/package.nix`)
- **npm**: `buildNpmPackage` + `npmDepsHash`

## Formatting

```bash
treefmt             # format all files (Nix, markdown, JSON, TOML)
treefmt --fail-on-change  # check without modifying (CI mode)
```

treefmt orchestrates per-language formatters: alejandra (Nix), prettier
(markdown), biome (JSON), taplo (TOML). Config is in `treefmt.nix`, consumed by
devenv's built-in treefmt module. Generated lockfiles under owner `src/`
directories are excluded.

## Linting

```bash
agnix --strict .    # lint all agent config files
cspell lint '**/*.md' --no-progress  # spellcheck markdown
```

## Checks

```bash
nix flake check     # runs all checks:
                    #   formatting and repository lints
                    #   structural and module evaluation
                    #   runtime contracts and validator corpus scans
```

Only tracked files are included — `git add` new files first.
