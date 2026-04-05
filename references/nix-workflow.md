# Nix Workflow Reference

Conventions and gotchas for working with Nix in this repository.

## Stage Before Nix Commands

Nix flakes only see git-tracked files. **Always `git add` new (untracked)
files before running any Nix command that references them.** This includes:

- `nix build`, `nix develop`, `nix flake check`
- `nix eval` (e.g., `nix eval --raw .#lib.mkClaudeRouting`)
- Any command that runs inside `nix develop --command ...`

Untracked files are invisible to the flake. A build failure with
"No such file or directory" for a file you just created means it
hasn't been staged.

```bash
# Wrong: file exists but Nix can't see it
echo '...' > overlays/new-tool.nix
nix build  # fails: file not found

# Right: stage first
echo '...' > overlays/new-tool.nix
git add overlays/new-tool.nix
nix build  # works
```

## DevShell

Enter the development environment:

```bash
nix develop
```

This provides all tools: git-branchless, git-absorb, git-revise, agnix,
alejandra, dprint, cspell, nvfetcher.

## Adding a Package

1. **Add to `nvfetcher.toml`** — track upstream version
2. **Run `nvfetcher -o overlays/.nvfetcher`** — regenerate sources
3. **Create `overlays/<name>.nix`** — build recipe (see existing overlays
   for Rust, Python, and npm patterns)
4. **Add hash to `overlays/hashes.json`** — `cargoHash` for Rust,
   `npmDepsHash` for npm (use empty string, build to get correct hash)
5. **Wire into `flake.nix`** — dev-only tools go in devShell overlays,
   consumer packages go in default overlay + packages output

### Patterns by language

- **Rust**: `buildRustPackage` + `cargoHash` (see `overlays/agnix.nix`)
- **Python**: `buildPythonApplication` + pyproject (see `overlays/git-revise.nix`)
- **npm**: `buildNpmPackage` + `npmDepsHash`

## Formatting

```bash
dprint fmt          # format all files (markdown, JSON, Nix via alejandra)
dprint check        # check without modifying
nix fmt             # same as dprint fmt (nix fmt wraps dprint)
```

dprint handles markdown, JSON, and Nix files. Nix formatting uses
alejandra as a dprint exec plugin (`dprint.json`). The
`overlays/.nvfetcher/` directory is excluded via dprint config.

## Linting

```bash
agnix --strict .    # lint all agent config files
cspell lint '**/*.md' --no-progress  # spellcheck markdown
```

## Checks

```bash
nix flake check     # runs all checks:
                    #   agent-configs (agnix --strict)
                    #   formatting (dprint check)
                    #   spelling (cspell)
                    #   structural (symlinks, frontmatter, freshness)
```

Only tracked files are included — `git add` new files first.
