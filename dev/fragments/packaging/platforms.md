## Target Platforms

| System         | CI  | Packages | Notes                |
| -------------- | --- | -------- | -------------------- |
| x86_64-linux   | Yes | All      | Primary dev platform |
| aarch64-darwin | Yes | All      | macOS Apple Silicon  |

### Nightly Packaging Pattern

All binary packages track nightly/latest versions via inline hashes
and `config/update-matrix.nix`. Never defer to nixpkgs upstream —
always override `src` and `version` from the overlay's inline source.

When a package provides different artifacts per platform (e.g.,
`.tar.gz` on Linux, `.dmg` on Darwin):

1. Create a `<name>-sources.json` sidecar with version and
   per-platform `{url, hash}` entries keyed by Nix system string
2. Select the correct source in the `.nix` overlay via
   `ourPkgs.stdenv.hostPlatform.system`
3. Use `mkUpdateScript` from `overlays/lib.nix` to automate
   version bumps and hash prefetching for all platforms

Examples:

- `kiro-cli`: `kiro-cli-sources.json` with Linux tarball + Darwin `.dmg`
- `copilot-cli`: `copilot-cli-sources.json` with per-platform GitHub release tarballs
