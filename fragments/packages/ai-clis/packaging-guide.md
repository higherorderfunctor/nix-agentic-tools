## AI CLI Packages

### Overview

Three AI coding CLI tools are packaged in `packages/ai-clis/`:

- **github-copilot-cli** — GitHub Copilot CLI, pre-built binary fetched
  from GitHub releases
- **kiro-cli** — Kiro CLI, pre-built binary fetched from AWS release
  channel
- **kiro-gateway** — Python proxy API for Kiro IDE and CLI, built from
  source with a Python runtime environment

Packages are exposed at top-level (`pkgs.github-copilot-cli`,
`pkgs.kiro-cli`, `pkgs.kiro-gateway`).

### Build Patterns

**Binary fetch** (copilot-cli, kiro-cli): These packages use
`overrideAttrs` on the existing nixpkgs derivation to pin the version
and source from nvfetcher. The overlay fetches the pre-built tarball
and overrides `src` and `version`.

**Python application** (kiro-gateway): Built with `mkDerivation` using
a `python.withPackages` environment. The source is fetched via
nvfetcher from a git repository.

### nvfetcher Version Tracking

All three packages are tracked in the root `nvfetcher.toml`. Each uses
a different source strategy:

- `github-copilot-cli` — GitHub releases with version pattern matching
- `kiro-cli` — AWS manifest endpoint (`curl` + `jq`)
- `kiro-gateway` — git commit tracking on the main branch

The `sources.nix` file maps nvfetcher output keys to package names
consumed by each `<package>.nix` file.

### The overrideAttrs Pattern

copilot-cli and kiro-cli override existing nixpkgs packages rather
than defining new derivations from scratch. This inherits upstream
build logic (install phases, meta, dependencies) while pinning to
nvfetcher-tracked versions:

```nix
prev.<package>.overrideAttrs (_: {
  inherit (nv) src version;
})
```

This pattern means upstream nixpkgs changes (new dependencies, build
fixes) are picked up automatically on nixpkgs bumps.

### Building and Updating

```bash
nix build .#github-copilot-cli  # Build Copilot CLI
nix build .#kiro-cli            # Build Kiro CLI
nix build .#kiro-gateway        # Build Kiro Gateway
nvfetcher                       # Update all source versions
```
