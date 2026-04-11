# nix-update Migration

Drop nvfetcher, custom hash scripts, and hashes.json sidecar. Replace
with nix-update and inline hashes in .nix files. Restructure the
modelcontextprotocol/servers mono-repo as parallel-friendly derivations.

## What gets deleted

- `config/nvfetcher/nvfetcher.toml`
- `overlays/sources/generated.nix`, `overlays/sources/generated.json`
- `overlays/sources/hashes.json`
- `overlays/sources/locks/*.json`
- `dev/scripts/update-hashes.sh`
- `dev/scripts/update-locks.sh`
- `nv-sources` overlay in `flake.nix` and `devenv.nix`
- `merge`/`hashDefaults`/`dummyHash`/`nvSrc` machinery in `overlays/default.nix`
- nvfetcher from CI shell and devenv packages

## Self-contained overlay files

Every package .nix file owns its own fetcher call with inline version,
source hash, and dep hashes. No external sidecar. nix-update rewrites
these values in place.

Each package provides `passthru.updateScript` for nix-update to call
via `--use-update-script`. Standard GitHub packages use the nixpkgs
`nix-update-script` helper. Exotic version sources (AWS manifest, npm
registry, scoped tags) define custom scripts using
`update-source-version`.

### Package ecosystem mapping

| Package | Builder | Dep hash | Update source |
|---|---|---|---|
| agnix | buildRustPackage | cargoHash | GitHub main |
| any-buddy | pre-built binary | — | GitHub main |
| claude-code | buildNpmPackage | npmDepsHash | npm registry |
| copilot-cli | pre-built binary | — | GitHub releases (per-platform) |
| context7-mcp | pnpm (nixpkgs override) | pnpmDepsHash | GitHub scoped tag |
| effect-mcp | pnpm (stdenv + pnpmConfigHook) | pnpmDepsHash | GitHub main |
| git-intel-mcp | buildNpmPackage | npmDepsHash | GitHub main |
| github-mcp | buildGoModule (nixpkgs override) | vendorHash | GitHub releases |
| kagi-mcp | buildPythonApplication | — | GitHub main |
| kiro-cli | pre-built binary | — | AWS manifest (per-platform) |
| kiro-gateway | pre-built binary | — | GitHub main |
| mcp-language-server | buildGoModule (nixpkgs override) | vendorHash | GitHub main |
| mcp-proxy | buildPythonApplication (nixpkgs override) | — | GitHub main |
| nixos-mcp | flake input | — | nix flake update |
| openmemory-mcp | buildNpmPackage | npmDepsHash | GitHub main |
| serena-mcp | flake input | — | nix flake update |
| sympy-mcp | buildPythonApplication | — | GitHub main |
| git-absorb | buildRustPackage | cargoHash | GitHub main |
| git-branchless | buildRustPackage | cargoHash | GitHub main |
| git-revise | buildPythonApplication | — | GitHub main |

Flake input packages (nixos-mcp, serena-mcp) are updated by
`nix flake update`, not nix-update.

## modelcontextprotocol/servers mono-repo

Split into parallel-friendly derivations under
`pkgs.ai.mcpServers.modelContextProtocol.*`:

**JS packages** (share pnpm-lock.yaml):
- `js-build.nix` — single pnpm derivation builds all JS servers from
  the mono-repo's lockfile. Output: `$out/servers/{name}/dist/`
- `sequential-thinking.nix` — makeWrapper pointing at js-build output
- `filesystem.nix` — makeWrapper
- `memory.nix` — makeWrapper

**Python packages** (each has own uv.lock/pyproject.toml):
- `fetch.nix` — independent buildPythonApplication
- `git.nix` — independent buildPythonApplication
- `time.nix` — independent buildPythonApplication

`passthru.updateScript` lives on the js-build derivation. When the
mono-repo rev changes, all sub-packages rebuild.

Directory structure: `overlays/mcp-servers/modelcontextprotocol/`

## overlays/default.nix simplification

Drops all nvfetcher machinery. Each import returns a self-contained
derivation. The file becomes pure grouping + `ensureUnfreeCheck`:

```nix
{inputs, ...}: final: prev: let
  guard = builtins.mapAttrs (_: ensureUnfreeCheck);
  flatDrvs = {
    agnix = import ./agnix.nix {inherit inputs final;};
    # ...
  };
  mcpServerDrvs = { /* ... */ };
  gitToolDrvs = { /* ... */ };
in {
  ai = guard flatDrvs // {
    mcpServers = guard mcpServerDrvs;
  };
  gitTools = guard gitToolDrvs;
}
```

## Update pipeline

### Local

```bash
nix-update --flake <pkg> --use-update-script --commit
```

Per package: runs updateScript → checks upstream → updates version +
rev + all hashes inline → generates lockfiles if needed → commits.

Packages with no upstream change: prints "already up to date", skips.

Full update:

```bash
for pkg in $(nix eval .#packages.x86_64-linux --apply builtins.attrNames --json | jq -r '.[]' | grep -vE '^(instructions-|docs)'); do
  nix-update --flake "$pkg" --use-update-script --commit
done
```

### CI (future — after local works)

```
Phase 1 (ubuntu): nix-update loop, commits per-package
Phase 2 (per-platform): nix-fast-build --skip-cached, cachix daemon pushes
Phase 3 (per-platform): devenv print-dev-env, cachix warm
Phase 4 (ubuntu): push (only if all phases pass)
```

No hash computation in CI. No lockfile generation. nix-update did it
all in Phase 1.

## Consumer experience

After CI passes, all packages are in cachix. Consumers adding
`nix-agentic-tools.cachix.org` as a substituter never build anything.
`devenv shell` on any platform pulls from cachix.

## Migration order

1. Migrate overlay files one at a time (inline fetcher + hashes + updateScript)
2. After each package: verify `nix-update --flake <pkg> --use-update-script` works
3. After all packages: delete nvfetcher config, generated files, custom scripts
4. Update overlays/default.nix (remove nv machinery)
5. Full local end-to-end test
6. Port to CI
