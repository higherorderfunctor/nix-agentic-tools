## MCP Server Packages

> **Last verified:** 2026-08-04 (commit pending — the local-patch section
> claimed "excludePattern + detector, OR a targets row — never both" as though
> it covered every patch, but it was written about patching published BUILD
> OUTPUT only. openmemory-mcp's loopback-bind patch is a SOURCE patch on a
> package that runs tsc itself, and it correctly KEEPS its targets row; a new
> subsection draws that line, and records why a held-back sweep is the desired
> signal for a security patch rather than a nuisance). Prior: 2026-08-02 (commit
> pending — adds Semble's identity-preserving external-flake MCP role, which
> shares its CLI derivation and is updated with the flake input rather than a
> package target). Prior: 2026-07-27 (commit pending — absorbing `aihubmix-mcp`
> corrected three stale claims in the "Adding a New Server" checklist below:
> `overlays/mcp-servers/locks/` has never existed, `flake.nix` needs no
> per-package edit, and the top-level `modules/` directory is gone. It also adds
> the vendored-lockfile + local-patch shape and the excluded-with-an-annotation
> update class, which is about sweepability and not about lagging upstream). If
> you add or remove an `overlays/mcp-servers/*.nix` file, or change how one is
> wired into the flake, and this fragment isn't updated in the same commit, stop
> and fix it.

### Overlay Architecture

MCP servers are packaged as Nix overlay files in `overlays/mcp-servers/`. The
unified overlay in `overlays/default.nix` exposes all servers under
`pkgs.ai.mcpServers.*`.

- `overlays/default.nix` — unified overlay entry point, imports each per-package
  `.nix` file with `{inputs, final, ...}`
- `overlays/lib.nix` — shared helpers: `ghLatestVersionCmd`,
  `mkGitRevUpdateScript`, `mkMcpSmokeTest`, `mkUpdateScript`, `mkVersion`,
  version readers
- `overlays/mcp-servers/<server>.nix` — individual server derivation (npm,
  Python, or Go) with inline `rev` + `hash`

### Build Patterns

Servers use one of three Nix builders depending on upstream language:

- **npm** (`buildNpmPackage` / pnpm override) — aihubmix-mcp, context7-mcp,
  effect-mcp, git-intel-mcp, gitlab-mcp, openmemory-mcp. Require `pnpmDeps` or
  `npmDeps` hash inline in the overlay file
- **Python** (`buildPythonApplication`) — kagi-mcp, mcp-proxy, sympy-mcp. Some
  use `pyproject = true` with hatchling or setuptools
- **Go** (`buildGoModule`) — github-mcp. Requires `vendorHash` inline in the
  overlay file

Semble is the explicit non-builder exception. `semble-mcp` is a plain attr/meta
view of `inputs.llm-agents.packages.${system}.semble`: it changes
`meta.mainProgram` and shares the upstream CLI's exact derivation. It has no
local source pin or update-target row; normal flake-input automation updates
`llm-agents`.

### Inline Hash Pattern

Each package pins `rev` and `hash` directly in its overlay `.nix` file. No
sidecar files or generated sources — everything is visible in one place:

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

`aihubmix-mcp` is the one server sourced from an npm-registry tarball rather
than a git repo, and three things follow that do NOT follow for the
`fetchFromGitHub` / `fetchgit` servers above:

- **No rev, so no `vu.mkVersion` and no `vu.readPackageJsonVersion`.** A flat
  `fetchurl` yields the `.tgz` FILE, not a tree, so there is nothing to
  `readFile` at eval time — and the URL embeds the version anyway. The version
  is a literal, and `sourceRoot = "package"` because npm tarballs extract under
  `package/`.
- **`vu.ghArchiveUpdateScript` / `vu.ghLatestVersionCmd` do not transfer**, on
  two counts: the source is not GitHub-hosted, and `ghArchiveUpdateScript`
  records a `nix-prefetch-url --unpack` hash — the UNPACKED-NAR value, which
  fails a flat `fetchurl`'s fixed-output check. For npm, the version source is
  the registry document's `dist-tags` (see `overlays/generic/pnpm-major.nix` for
  the `curl … | jq -r '.["dist-tags"]…'` shape).
- **npm publishes no lockfile in the tarball**, but `fetchNpmDeps` requires one.
  Vendor it beside the overlay as
  `overlays/mcp-servers/<name>-package-lock.json` and `cp` it in from
  `postPatch`. That exact name is load-bearing: `treefmt.nix`'s global excludes
  and `devenv.nix`'s cspell excludes are both keyed on the `*-package-lock.json`
  glob, so biome does not restyle a file whose canonical formatter is npm.

### A local patch is an update-cadence decision, not a detail

`patches = [ ./<name>-<topic>.patch ]` against upstream's PUBLISHED BUILD OUTPUT
(not source) is maximally fragile: any upstream rebuild of the patched file
breaks it, and no update script can re-author a patch.

The decision this drives is about SWEEPABILITY, not about which version to
carry. Tracking `dist-tags.latest` is normal and expected; what the patch costs
is the ability to get there AUTOMATICALLY. A targets row on such a package goes
RED the first time upstream rebuilds the patched file, occupying a channel meant
for TRANSIENT failures. So carry whatever version the operator wants, bump it BY
HAND, and make the machinery honest:

1. a `config.update.excludePatterns` entry recording the exclusion and why;
2. a non-blocking annotation step in `.github/workflows/update.yml` — the family
   that already holds the copilot-cli SEA detector and the pnpm new-major
   detector — comparing upstream's version against one DERIVED from the repo
   (`nix eval --raw .#packages.<system>.<name>.version`), never a literal;
3. the reasoning, measured, in the overlay's own header.

Keep the two mechanisms mutually exclusive: excludePattern + detector, OR a
targets row — never both. The day the patch can be dropped (upstream grows the
feature, or the change lands upstream), delete the exclusion and the detector in
the SAME commit that adds the targets row.

`aihubmix-mcp` is the worked example, and it also shows the trap: when it moved
to `dist-tags.latest` the patch had to be re-authored by hand (hunk 1 applied
with fuzz, hunks 2 and 3 failed outright), which is precisely why being current
did not make it sweepable. Structure such a patch to minimize anchors — a single
contiguous prepend at the top of the file, where upstream's first import lines
are the most stable context available, plus the smallest possible insertions
elsewhere. And confirm it applies with NO fuzz: `patch` taking a hunk with fuzz
means it guessed at the location.

### Patching SOURCE keeps its targets row — the rule above is about dist

Everything above is scoped to patching upstream's published BUILD OUTPUT. A
package that builds from source in-tree (runs `tsc` / `cargo` / `go build`
itself) is a different class, and the exclusion-plus-annotation dance is the
WRONG shape for it:

- Source anchors track upstream's own code, which moves far less often than a
  rebuilt `dist/`. The aihubmix failure mode — a rebuild with no source change
  invalidating every hunk — cannot occur.
- Express it as `substituteInPlace … --replace-fail` in `postPatch`, not as a
  `.patch` file. `--replace-fail` is positional-anchor-free and turns drift into
  a loud build failure; a `.patch` can apply with FUZZ and silently land in the
  wrong place.
- So keep the `config.update.targets` row. A held-back sweep here is the SIGNAL,
  not a channel-occupying nuisance: it means upstream touched the exact lines
  being patched, which is precisely when a human must look.

For a SECURITY patch that inverts an upstream default, failing the sweep is the
DESIRED behavior — auto-sweeping past it would silently restore the unsafe
default. Prefer edits that also make the compiler your backstop: if the patched
signature is threaded through callers, a partial application fails to typecheck
rather than compiling into a half-patched binary.

`openmemory-mcp` is the worked example. Upstream calls `listen(port)` with no
host and ships no bind knob, so the daemon binds every interface; the overlay
patches `src/core/cfg.ts`, `src/server/server.ts` and `src/server/index.ts` to
thread a required `host` defaulting to loopback, backed by a `postInstallCheck`
positive control and negative-control-verified (neutering `postPatch` reddens
the build; breaking an anchor reddens `substituteInPlace`).

### Adding a New Server

1. Create `overlays/mcp-servers/<name>.nix` using the appropriate builder, with
   inline `rev`, `hash`, and any dependency hashes. Route every build input
   through `ourPkgs`, never `final`.
2. Import it in `overlays/default.nix` under `mcpServerDrvs`.
3. Put any support files (vendored lockfile, patches) FLAT beside it as
   `overlays/mcp-servers/<name>-<kind>.<ext>`. There is no
   `overlays/mcp-servers/locks/` directory — earlier revisions of this list
   claimed one and it has never existed.
4. Nothing to do in `flake.nix`: it flattens `pkgs.ai.mcpServers` into
   `packages.<system>` wholesale, so a new overlay entry appears automatically.
5. Add a `config.checks.cacheHitParity.<name>` row in
   `config/cache-hit-parity-targets.nix` with
   `consumerPath = ["ai" "mcpServers" "<name>"]`. Absence from nixpkgs is NOT an
   exemption — the check compares our pin against a consumer pin, never against
   nixpkgs.
6. Add a `dev/data.nix` `mcpServerMeta.<name>` row (description + credentials);
   it drives the README server table and its count.
7. Add the per-package barrel `packages/<name>/` with `lib/mk<Name>.nix`.
   Register it in `packages/default.nix`. Add `modules/mcp-server.nix` ONLY if
   the server is to be run as a managed service — that also means an entry in
   `serverNames` in `packages/mcp-services/modules/homeManager/default.nix`.
   There is no top-level `modules/` directory.
8. Register a `config.update.targets.<name>` row in `config/update-targets.nix`
   — or, if the package cannot be swept, an `excludePatterns` entry plus an
   annotation step (previous section).
9. Regenerate the instruction files:
   `devenv tasks run --mode before generate:instructions`, and the README:
   `devenv tasks run --mode before generate:repo`.

For an external package role such as `semble-mcp`, replace steps 1 and 8 with a
direct input-package selection and input update automation. Still register both
the CLI and MCP roles in cache-hit parity, and add a sibling-derivation
assertion so a future `overrideAttrs` cannot create a redundant build.

### Updating

```bash
nix build .#<server-name>       # Build a single server
nix run .#update                # Run all updates via config.update.targets
nix flake check                 # Verify evaluation
```

Updates use two mechanisms depending on package type:

- **Main-tracking packages**: `mkGitRevUpdateScript` fetches the latest commit
  via `git ls-remote`, then `nix-update --version skip` refreshes all hashes
- **Per-platform binaries**: `mkUpdateScript` fetches the latest release
  version, prefetches each platform's binary, and writes to `sources.json`. For
  a GitHub-released upstream, pair it with `ghLatestVersionCmd` (reads the
  `releases/latest` redirect — no API token, no rate limit) instead of
  hand-rolling a `curl api.github.com | jq` version check.
