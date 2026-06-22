## AI CLI Packages

### Overview

AI coding CLI tools are packaged as overlays under `overlays/`:

- **claude-code** — Claude Code CLI, pre-built binary
- **copilot-cli** — GitHub Copilot CLI, pre-built SEA binary fetched
  from GitHub releases
- **kimchi** — Kimchi coding-agent CLI (Cast AI), bun-compiled binary
  fetched from GitHub releases
- **kiro-cli** — Kiro CLI, pre-built binary fetched from AWS release
  channel
- **kiro-gateway** — Python proxy API for Kiro IDE and CLI, built from
  source with a Python runtime environment

Packages live under `pkgs.ai.*` and are flattened to top-level flake
outputs (`pkgs.claude-code`, `pkgs.copilot-cli`, `pkgs.kimchi`,
`pkgs.kiro-cli`, `pkgs.kiro-gateway`).

### Build Patterns

**overrideAttrs binary** (kiro-cli): overrides the existing nixpkgs
derivation to pin the version and `src` from a per-platform
`sources.json`, inheriting upstream install/wrapper logic.

**Standalone binary** (copilot-cli, kimchi): there is no nixpkgs base
to inherit, so these are fresh `stdenv.mkDerivation`s over a
per-platform release tarball selected from `sources.json`. On Linux
they run `autoPatchelfHook` to repoint the interpreter/rpath at the
nix glibc.

- copilot-cli installs a single SEA binary (`copilot`).
- kimchi ships an FHS tree (`bin/kimchi` + `share/kimchi/`, including a
  second ELF `share/kimchi/bin/proxy-helper`); the install copies the
  whole tree and autoPatchelf patches both ELFs. The binary resolves
  `share/` relative to itself, so the tree is preserved, not relocated.
  Apache-2.0 (free), so it passes the unfree guard unwrapped.

**Python application** (kiro-gateway): Built with `mkDerivation` using
a `python.withPackages` environment. The source is fetched via inline
`rev` + `hash` with `fetchFromGitHub`.

### Version Tracking

These packages pin versions inline (binary CLIs via a per-platform
`sources.json` sidecar). Each uses an update strategy managed by
`config/update-matrix.nix`:

- `copilot-cli` — per-platform `sources.json` + `mkUpdateScript` fetches
  latest GitHub release and prefetches per-platform binaries
- `kimchi` — per-platform `sources.json` + `mkUpdateScript` fetches the
  latest GitHub release tag and prefetches per-platform tarballs
- `kiro-cli` — per-platform `sources.json` + `mkUpdateScript` fetches
  latest version from AWS manifest endpoint
- `kiro-gateway` — inline `rev` + `hash` with `mkGitRevUpdateScript`
  for main-branch tracking; version via `mkVersion`

The `overlays/lib.nix` file provides `mkVersion`, `mkUpdateScript`,
and `mkGitRevUpdateScript` helpers consumed by each overlay file.

### The overrideAttrs Pattern

kiro-cli overrides an existing nixpkgs package rather than defining a
new derivation from scratch. This inherits upstream build logic
(install phases, meta, dependencies) while pinning to inline versions
and per-platform sources:

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
nix build .#copilot-cli         # Build Copilot CLI
nix build .#kimchi              # Build Kimchi CLI
nix build .#kiro-cli            # Build Kiro CLI
nix build .#kiro-gateway        # Build Kiro Gateway
nix run .#update                # Update all source versions via update matrix
```
