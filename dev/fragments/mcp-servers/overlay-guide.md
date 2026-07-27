## MCP Server Packages

> **Last verified:** 2026-07-27 (commit pending — absorbing
> `aihubmix-mcp` corrected three stale claims in the "Adding a New
> Server" checklist below: `overlays/mcp-servers/locks/` has never
> existed, `flake.nix` needs no per-package edit, and the top-level
> `modules/` directory is gone. It also adds the vendored-lockfile +
> local-patch shape and the pinned-with-an-annotation update class). If
> you add or remove an `overlays/mcp-servers/*.nix` file, or change how
> one is wired into the flake, and this fragment isn't updated in the
> same commit, stop and fix it.

### Overlay Architecture

MCP servers are packaged as Nix overlay files in `overlays/mcp-servers/`.
The unified overlay in `overlays/default.nix` exposes all servers under
`pkgs.ai.mcpServers.*`.

- `overlays/default.nix` — unified overlay entry point, imports each
  per-package `.nix` file with `{inputs, final, ...}`
- `overlays/lib.nix` — shared helpers: `ghLatestVersionCmd`,
  `mkGitRevUpdateScript`, `mkMcpSmokeTest`, `mkUpdateScript`,
  `mkVersion`, version readers
- `overlays/mcp-servers/<server>.nix` — individual server derivation
  (npm, Python, or Go) with inline `rev` + `hash`

### Build Patterns

Servers use one of three Nix builders depending on upstream language:

- **npm** (`buildNpmPackage` / pnpm override) — aihubmix-mcp, context7-mcp,
  effect-mcp, git-intel-mcp, gitlab-mcp, openmemory-mcp. Require `pnpmDeps`
  or `npmDeps` hash inline in the overlay file
- **Python** (`buildPythonApplication`) — kagi-mcp, mcp-proxy, sympy-mcp.
  Some use `pyproject = true` with hatchling or setuptools
- **Go** (`buildGoModule`) — github-mcp. Requires `vendorHash` inline in
  the overlay file

### Inline Hash Pattern

Each package pins `rev` and `hash` directly in its overlay `.nix` file.
No sidecar files or generated sources — everything is visible in one place:

```nix
# overlays/mcp-servers/context7-mcp.nix
rev = "c31528d...";
src = ourPkgs.fetchFromGitHub {
  owner = "upstash";
  repo = "context7";
  inherit rev;
  hash = "sha256-TMvDzD...";
};
```

Version is computed at eval time from the source manifest via `mkVersion`:

```nix
version = vu.mkVersion {
  upstream = vu.readPackageJsonVersion "${src}/packages/mcp/package.json";
  inherit rev;
};
# → "1.2.3+c31528d"
```

Dependency hashes (pnpmDeps, vendorHash) are also inline in the same file.

### An npm-REGISTRY server is not a GitHub server

`aihubmix-mcp` is the one server sourced from an npm-registry tarball
rather than a git repo, and three things follow that do NOT follow for the
`fetchFromGitHub` / `fetchgit` servers above:

- **No rev, so no `vu.mkVersion` and no `vu.readPackageJsonVersion`.** A
  flat `fetchurl` yields the `.tgz` FILE, not a tree, so there is nothing to
  `readFile` at eval time — and the URL embeds the version anyway. The
  version is a literal, and `sourceRoot = "package"` because npm tarballs
  extract under `package/`.
- **`vu.ghArchiveUpdateScript` / `vu.ghLatestVersionCmd` do not transfer**,
  on two counts: the source is not GitHub-hosted, and `ghArchiveUpdateScript`
  records a `nix-prefetch-url --unpack` hash — the UNPACKED-NAR value, which
  fails a flat `fetchurl`'s fixed-output check. For npm, the version source
  is the registry document's `dist-tags` (see `overlays/generic/pnpm-major.nix`
  for the `curl … | jq -r '.["dist-tags"]…'` shape).
- **npm publishes no lockfile in the tarball**, but `fetchNpmDeps` requires
  one. Vendor it beside the overlay as
  `overlays/mcp-servers/<name>-package-lock.json` and `cp` it in from
  `postPatch`. That exact name is load-bearing: `treefmt.nix`'s global
  excludes and `devenv.nix`'s cspell excludes are both keyed on the
  `*-package-lock.json` glob, so biome does not restyle a file whose
  canonical formatter is npm.

### A local patch is an update-cadence decision, not a detail

`patches = [ ./<name>-<topic>.patch ]` against upstream's PUBLISHED BUILD
OUTPUT (not source) is maximally fragile: any upstream rebuild of the
patched file breaks it, and no update script can re-author a patch.

Before wiring a `config.update.targets` row for such a package, actually
test the patch against the current upstream release. If it does not apply,
a targets row lands a target that reports HELD BACK on its FIRST sweep and
every sweep after, permanently occupying a channel meant for TRANSIENT
failures. Pin it instead, and make the lag loud the cheap way:

1. a `config.update.excludePatterns` entry recording the exclusion and why;
2. a non-blocking annotation step in `.github/workflows/update.yml` — the
   family that already holds the copilot-cli SEA detector and the pnpm
   new-major detector — comparing upstream's version against one DERIVED
   from the repo (`nix eval --raw .#packages.<system>.<name>.version`),
   never a literal;
3. the reasoning, measured, in the overlay's own header.

`aihubmix-mcp` is the worked example.

### Adding a New Server

1. Create `overlays/mcp-servers/<name>.nix` using the appropriate builder,
   with inline `rev`, `hash`, and any dependency hashes. Route every build
   input through `ourPkgs`, never `final`.
2. Import it in `overlays/default.nix` under `mcpServerDrvs`.
3. Put any support files (vendored lockfile, patches) FLAT beside it as
   `overlays/mcp-servers/<name>-<kind>.<ext>`. There is no
   `overlays/mcp-servers/locks/` directory — earlier revisions of this list
   claimed one and it has never existed.
4. Nothing to do in `flake.nix`: it flattens `pkgs.ai.mcpServers` into
   `packages.<system>` wholesale, so a new overlay entry appears
   automatically.
5. Add a `config.checks.cacheHitParity.<name>` row in
   `config/cache-hit-parity-targets.nix` with
   `consumerPath = ["ai" "mcpServers" "<name>"]`. Absence from nixpkgs is
   NOT an exemption — the check compares our pin against a consumer pin,
   never against nixpkgs.
6. Add a `dev/data.nix` `mcpServerMeta.<name>` row (description +
   credentials); it drives the README server table and its count.
7. Add the per-package barrel `packages/<name>/` with
   `lib/mk<Name>.nix`. Register it in `packages/default.nix`. Add
   `modules/mcp-server.nix` ONLY if the server is to be run as a managed
   service — that also means an entry in `serverNames` in
   `packages/mcp-services/modules/homeManager/default.nix`. There is no
   top-level `modules/` directory.
8. Register a `config.update.targets.<name>` row in
   `config/update-targets.nix` — or, if the package cannot be swept, an
   `excludePatterns` entry plus an annotation step (previous section).
9. Regenerate the instruction files:
   `devenv tasks run --mode before generate:instructions`, and the README:
   `devenv tasks run --mode before generate:repo`.

### Updating

```bash
nix build .#<server-name>       # Build a single server
nix run .#update                # Run all updates via config.update.targets
nix flake check                 # Verify evaluation
```

Updates use two mechanisms depending on package type:

- **Main-tracking packages**: `mkGitRevUpdateScript` fetches the latest
  commit via `git ls-remote`, then `nix-update --version skip` refreshes
  all hashes
- **Per-platform binaries**: `mkUpdateScript` fetches the latest release
  version, prefetches each platform's binary, and writes to `sources.json`.
  For a GitHub-released upstream, pair it with `ghLatestVersionCmd` (reads
  the `releases/latest` redirect — no API token, no rate limit) instead of
  hand-rolling a `curl api.github.com | jq` version check.
