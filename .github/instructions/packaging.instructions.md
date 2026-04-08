---
applyTo: "nvfetcher.toml,packages/**/*.nix,packages/**/sources.nix"
---

## Naming Conventions

- Package overlays: `packages/<group>/<name>.nix`
- Dev fragments: `dev/fragments/<pkg>/<name>.md`
- nvfetcher keys use upstream project names (may differ from exported package names)
- Exported packages: lowercase with hyphens

Future conventions (introduced in later chunks):

- Server modules: `modules/mcp-servers/servers/<name>.nix`
- Skills: `packages/stacked-workflows/skills/<name>/SKILL.md`
- Published fragments: `packages/<pkg>/fragments/<name>.md`

## Target Platforms

| System         | CI  | Packages | Notes                |
| -------------- | --- | -------- | -------------------- |
| x86_64-linux   | Yes | All      | Primary dev platform |
| aarch64-darwin | Yes | All      | macOS Apple Silicon  |

### Nightly Packaging Pattern

All binary packages are tracked via nvfetcher for nightly/latest
versions. Never defer to nixpkgs upstream — always override `src`
and `version` from nvfetcher.

When a package provides different artifacts per platform (e.g.,
`.tar.gz` on Linux, `.dmg` on Darwin):

1. Add separate nvfetcher entries per platform (e.g., `kiro-cli` +
   `kiro-cli-darwin`) tracking the same version but different URLs
2. Select the correct source in the `.nix` overlay via
   `final.stdenv.hostPlatform.system`
3. Store per-platform hashes in `hashes.json` keyed by system

Examples:

- `kiro-cli`: Linux tarball + Darwin `.dmg` (via `undmg`)
- `copilot-cli`: per-platform tarballs from GitHub releases
