## MCP Server Packages

### Overlay Architecture

MCP servers are packaged as a Nix overlay in `packages/mcp-servers/`.
The overlay exposes all servers under `pkgs.nix-mcp-servers.*`.

- `default.nix` — overlay entry point, calls each server package via
  `callPkg` which auto-injects `nv-sources` and optional `inputs`
- `sources.nix` — merges nvfetcher `generated.nix` with `hashes.json`
  sidecar, producing `nv-sources.<name>` with version, src, and
  optional dependency hashes
- `<server>.nix` — individual server derivation (npm, Python, or Go)

### Build Patterns

Servers use one of three Nix builders depending on upstream language:

- **npm** (`buildNpmPackage`) — context7-mcp, effect-mcp, git-intel-mcp,
  openmemory-mcp, sequential-thinking-mcp. Require `npmDepsHash` in
  `hashes.json` and a lockfile in `locks/`
- **Python** (`buildPythonApplication`) — fetch-mcp, git-mcp, kagi-mcp,
  mcp-proxy, sympy-mcp. Some use `pyproject = true` with hatchling or
  setuptools
- **Go** (`buildGoModule`) — github-mcp. Requires `vendorHash` in
  `hashes.json`

### hashes.json Sidecar Pattern

nvfetcher tracks source tarballs but cannot compute dependency hashes
(npmDepsHash, vendorHash). These are stored in `hashes.json` alongside
`generated.nix`. The `sources.nix` file merges both at evaluation time:

```
generated.nix  →  { pname, version, src }
hashes.json    →  { npmDepsHash } or { vendorHash }
merged         →  nv-sources.<name> = { pname, version, src, npmDepsHash, ... }
```

To update a dependency hash: build the package, copy the hash from the
error message, and update `hashes.json`.

### Adding a New Server

1. Add an nvfetcher entry in the root `nvfetcher.toml`
2. Run `nvfetcher` to regenerate `packages/mcp-servers/.nvfetcher/generated.nix`
3. Create `packages/mcp-servers/<name>.nix` using the appropriate builder
4. If the builder needs dependency hashes, add them to `hashes.json`
5. For npm packages, add a lockfile to `packages/mcp-servers/locks/`
6. Register the package in `packages/mcp-servers/default.nix` (both
   `callPkg` and the `nix-mcp-servers` attrset)
7. Export it in `flake.nix` under `packages`
8. Add a server module in `modules/mcp-servers/servers/<name>.nix`

### Building and Updating

```bash
nix build .#<server-name>       # Build a single server
nvfetcher                       # Update all source versions
nix flake check                 # Verify evaluation
```

After `nvfetcher` updates versions, rebuild to check for hash mismatches.
Fix any broken hashes in `hashes.json`, then rebuild again.
