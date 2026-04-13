---
applyTo: "packages/ai-clis/**,packages/copilot-cli/**,packages/kiro-cli/**"
---

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
and source from a per-platform `sources.json` file. The overlay reads
the JSON at eval time and overrides `src` and `version`.

**Python application** (kiro-gateway): Built with `mkDerivation` using
a `python.withPackages` environment. The source is fetched via inline
`rev` + `hash` with `fetchFromGitHub`.

### Version Tracking

All three packages pin versions inline in their overlay `.nix` files.
Each uses a different update strategy managed by `config/update-matrix.nix`:

- `copilot-cli` — per-platform `sources.json` + `mkUpdateScript` fetches
  latest GitHub release and prefetches per-platform binaries
- `kiro-cli` — per-platform `sources.json` + `mkUpdateScript` fetches
  latest version from AWS manifest endpoint
- `kiro-gateway` — inline `rev` + `hash` with `mkGitRevUpdateScript`
  for main-branch tracking; version via `mkVersion`

The `overlays/lib.nix` file provides `mkVersion`, `mkUpdateScript`,
and `mkGitRevUpdateScript` helpers consumed by each overlay file.

### The overrideAttrs Pattern

copilot-cli and kiro-cli override existing nixpkgs packages rather
than defining new derivations from scratch. This inherits upstream
build logic (install phases, meta, dependencies) while pinning to
inline versions and per-platform sources:

```nix
ourPkgs.<package>.overrideAttrs (_: {
  inherit (sources) version;
  src = fetchurl { inherit (platformSrc) url hash; };
})
```

This pattern means upstream nixpkgs changes (new dependencies, build
fixes) are picked up automatically on nixpkgs bumps.

### Building and Updating

```bash
nix build .#github-copilot-cli  # Build Copilot CLI
nix build .#kiro-cli            # Build Kiro CLI
nix build .#kiro-gateway        # Build Kiro Gateway
nix run .#update                # Update all source versions via update matrix
```
