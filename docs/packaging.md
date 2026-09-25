# Package Build and Update Reference

Quick-reference for how each package is sourced, built, and updated.

## Source pattern

Main-tracking packages pin `rev` + `hash` inline in their native recipe under
`packages/<owner>/packages/`. Binary/release packages use owner-local sidecars
described below. Versions are computed at eval time via
`lib/packaging.nix:mkVersion` (`{upstream}+{shortRev}`). Updates use the
composed registry and ninja DAG:
`nix run .#generate-update-ninja && ninja -j4 -v -f .update.ninja update-report`

- **Main-tracking**: `git ls-remote` for rev, `nix flake prefetch` for hash,
  `nix-update --version skip` for dep hashes. Config in `config.update.targets`
  (owner `registry.nix` contributions, alongside root workspace policy).
- **Binary packages**: custom `updateScript` via `mkUpdateScript` in
  `lib/packaging.nix`. Per-platform hashes in the owner's `sources.json`.
- **GitHub repo-archive tarballs** (`fetchzip` consumers):
  `ghArchiveUpdateScript` in `lib/packaging.nix` — one `repo` derives both the
  archive URL and the release-tag version check, and prefetches with `--unpack`
  so the recorded hash is over the unpacked NAR. Recipes pass
  `sourcesFile = repoPath ./relative/sources.json` explicitly. A Rust package on
  this pattern must NOT keep an inline `cargoHash`: `ghArchiveUpdateScript`
  refreshes only the src hash, so the vendor hash would go stale on every bump.
  Override `cargoDeps` with
  `rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }` instead
  (IFD) so one hash covers both — see
  `packages/fblog/packages/ai/generic/fblog/package.nix` and
  `packages/git-branchless/packages/ai/gitTools/git-branchless/package.nix`.
- **Go packages with a sidecar `vendorHash`** (`beads`, its paired nested
  `dolt`, `gh`, `gluetun`, `kimchi`, `oh-my-posh`, `otel-tui` — kimchi records
  the hash for its nested `proxy-helper`, not for a top-level Go build): a Go
  vendor set cannot be derived from a lockfile the way `importCargoLock` derives
  one from `Cargo.lock`, so `vendorHash` has to be recorded — and it goes in the
  sidecar, never inline, because `ghArchiveUpdateScript` would otherwise leave
  it stale on every bump (the same transitive-hash gap as an inline
  `cargoHash`). `mkUpdateScript` rebuilds the sidecar from scratch, destroying
  any key it does not write itself, so each package passes
  `extraExtract = "${fixVendorHash}"` and reads
  `sources.vendorHash or lib.fakeHash` to cover the window between the two
  writes. `vu.mkGoVendorFix` builds `<attr>.goModules` through the flake's own
  `packages` output and scrapes the `got:` hash out of a `-go-modules` mismatch;
  it is also exposed standalone as `passthru.fixVendorHash`, because a nixpkgs
  or toolchain bump can invalidate a vendor hash with no version bump at all.
  `passthru` must be MERGED — `buildGoModule` hangs `goModules` and
  `overrideModAttrs` there and warns loudly if an overlay drops them. Two traps:
  `postPatch` is an INPUT to `goModules`, so changing which test files are
  removed changes the vendor hash; and a vendorHash is NOT validated by "it
  built", because an identically-named fixed-output path already in the local
  store is accepted without building. Force the real computation by perturbing
  the sidecar's version and running the update script. Beads composes two of
  these standard scripts: each independently checks its upstream, while one
  public update script keeps Beads and its exact Dolt runtime on the same update
  branch and PR.
- **npm packages with a sidecar `npmDepsHash`** (`bruno`): override the BUILDER
  (`pkg.override { buildNpmPackage = …; }`), never `overrideAttrs`.
  `buildNpmPackage` is a `lib.extendMkDerivation` whose `extendDrvArgs` computes
  `npmDeps = fetchNpmDeps { hash = npmDepsHash; src; postPatch; }` from the
  INCOMING args, so an `npmDepsHash` set through `overrideAttrs` composes on top
  of that output and is INERT — measured on bruno: the version moved to 4.0.0
  while `npmDeps` stayed `bruno-3.5.2-npm-deps` with 3.5.2's hash, and the build
  produced no error at all. Re-point `src` by overriding the upstream fetcher
  (`pkg.src.override { tag; hash; }`) so an upstream `postFetch` survives
  byte-identically. That `postFetch` is why the src hash is ALSO in the sidecar
  and why neither hash comes from a prefetch: it mutates the tree the hash
  covers, so `nix-prefetch-url --unpack` records a different value than the
  fetcher produces. Pass `platforms = {}` to `mkUpdateScript` (version only) and
  `extraExtract = "${fixNpmDepsHash}"`; `vu.mkNpmDepsFix` restores `srcHash`
  then `npmDepsHash`, in that order because `npmDeps` is derived from `src`. It
  is also `passthru.fixNpmDepsHash`, for a nixpkgs-side change that invalidates
  a hash with no version bump.
- **pnpm packages with a sidecar `pnpmDepsHash`** (`kimchi`): the only owner on
  this shape today, because it is also the only pnpm package whose release
  source is pinned by a repo-owned `mkUpdateScript` rather than rev-bumped by
  `nix-update`. `pnpmDeps` reads `sources.pnpmDepsHash or lib.fakeHash` for the
  same reason the Go bullet does, and `packageLib.mkHashFix` with
  `hashFixTargets.pnpmDeps` supplies the repair. Order matters within the chain:
  the pnpm fixer is passed as `extraAfter` to `mkGoUpdateExtract`, so it runs
  after the Go floor and vendor hash rather than racing them. It is also
  `passthru.fixPnpmDepsHash`, which `fix_sidecar_hashes` discovers. Like the
  vendor-hash fixer, it is not validated by "it built": at an unchanged version
  a cached pnpm-deps path satisfies it, so it repairs an input bump only when
  that path cannot be substituted. A pnpm package WITHOUT that attr still has no
  automatic repair, which is the remaining half of the Mode D gap in
  `docs/update-pipeline-transitive-hash-gap.md`. Its `pnpmDeps` and `src` FODs
  carry the version in their names, so a bump that forgets a hash fails the
  fetch instead of substituting the previous release's cached output.
- **Go toolchain gaps** (`gluetun`, `oh-my-posh`): declare the package's go.mod
  floor and let `vu.goToolchainForFloor` DERIVE the toolchain — `ourPkgs.go`
  while our pin satisfies the floor, otherwise the lowest `go-bin`
  (purpleclay/go-overlay) release that does, and a throw if nothing does. Never
  pin a toolchain version; a pin cannot tell a live gap from a rotted downgrade.
  `checks/packaging/go-toolchain-floor.nix` covers all three branches.
- **Version-independent URLs** (`dns-root-hints`): the version-equality early
  exit is not a valid change signal, so pass `alwaysPrefetch = true` to
  `mkUpdateScript`. It prefetches every run and decides whether to write by
  comparing the freshly built sidecar against the committed one.
- **Several majors of one upstream** (`pnpm_10`, `pnpm_11` — but NOT `pnpm_12`,
  see below): one shared builder (`packages/pnpm/lib/mkMajor.nix`) parameterized
  by the major, with a two-line file per major so each gets its own
  `--override-filename` path and sidecar. The version check reads the registry's
  per-major channel, and an eval-time guard rejects a sidecar whose major does
  not match the attribute.
- **A major that leaves the family** (`pnpm_12`): the shared builder is only
  correct while every major is the same KIND of artifact. pnpm 12 moved its
  implementation out of the npm package into per-platform native binaries
  (`@pnpm/exe.<platform>`), leaving `package/pnpm` a placeholder text file — so
  there is no `pkgs.pnpm_12` to override and nixpkgs' own generic expression
  cannot build a 12.x tarball either. `pnpm_12` is therefore a standalone
  prebuilt-binary derivation on the `chatgpt-codex` shape with a per-platform
  sidecar, and it carries its OWN major guard rather than inheriting
  `mkMajor.nix`'s. See the header of
  `packages/pnpm/packages/ai/generic/pnpm_12/package.nix`.
- **Hand-bumped, with currency annotated instead of swept** (`aihubmix-mcp`): a
  package carrying a local patch against upstream's published BUILD OUTPUT
  cannot ride the sweep — no update script can re-author a patch. This says
  nothing about WHICH version to carry: `aihubmix-mcp` tracks npm
  `dist-tags.latest` and is still excluded, because getting there meant
  re-authoring the patch by hand (upstream rewrote the patched file 288 -> 624
  lines and 2 of 3 hunks stopped applying). A `config.update.targets` row would
  go RED the next time that happens, permanently occupying a channel meant for
  TRANSIENT failures. Bump it by hand, record the exclusion in
  `config.update.excludePatterns`, and add a non-blocking annotation step to
  `.github/workflows/update.yml` comparing upstream's version against one
  DERIVED from the repo (never a literal) — exclusion + detector OR a targets
  row, never both. The npm-registry version source is the registry document's
  `dist-tags` — the same shape `packages/pnpm/lib/mkMajor.nix` uses. Note
  `ghArchiveUpdateScript` / `ghLatestVersionCmd` do NOT transfer to an
  npm-registry package: the source is not GitHub-hosted, and the former records
  a `nix-prefetch-url --unpack` hash, which fails a flat `fetchurl`'s
  fixed-output check.
- **Flake inputs**: consumed from `inputs.<name>.packages`, updated via
  `nix flake update`.
- **Pinned external derivation** (`semble`, `semble-mcp`): Semble is selected
  directly from the unfollowed `llm-agents` input so the standalone and consumer
  overlay paths remain byte-identical to Numtide's cached output. The MCP role
  is a plain attr/meta overlay selecting `semble-mcp`; it shares the same
  `drvPath` and `outPath` as the CLI. Do not apply `overlays.shared-nixpkgs`,
  rebuild with local packages, or use `overrideAttrs`.
- **In-repo source**: packaged from a path in this repo (no upstream rev/hash,
  not version-tracked). **No package uses this shape today** —
  `kiro-memory-distiller` was the only one, and it was removed on 2026-09-01
  along with the openmemory-mcp backend it fed. The shape is kept in this
  taxonomy because nothing about it was wrong; it simply has no consumer.

## Model weights: `pkgs.ai.fetchHuggingFaceModel`

nixpkgs already ships `pkgs.fetchFromHuggingFace`: `fetchgit` with Git LFS, a
`repoId`, a `rev` or `tag`, `repoType`, `domain`, `sparseCheckout` (with
`nonConeMode` for exact paths or gitignore-style globs), every other `fetchgit`
option, `hash`, `meta` and `passthru`. `pkgs.ai.fetchHuggingFaceModel` is a thin
wrapper over it. It comes from this repo's overlay and is built on your own
`pkgs`, so your `allowUnfree` settings apply:

```nix
pkgs.ai.fetchHuggingFaceModel {
  repoId = "minishlab/potion-base-32M";
  rev = "1e5a03f8eeb2c98b928fbbd846f22f816360919f";
  files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
  hash = "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=";
  license = pkgs.lib.licenses.mit;
}
```

The result is a directory holding the selected files, with subdirectories kept.
A tool that loads a model from a local directory can be pointed straight at it.
Git LFS downloads only the selected files, so a repository's other weight
formats are never fetched.

Every nixpkgs argument passes through, except as listed below:

- **`backend` defaults to `"lfs"`.** nixpkgs defaults to `"xet"`, which throws
  "not implemented yet".
- **`files`: exact repo paths.** They become `nonConeMode = true` plus anchored
  `sparseCheckout` patterns (`"config.json"` becomes `"/config.json"`), with
  `*`, `?` and `[` escaped so they match literally. Paths must be relative,
  unique ignoring case, and free of empty, `.` and `..` segments.
- **`sparseCheckout` for globs.** Pass it instead of `files` to pick file types,
  for example `["/*.json" "/*.safetensors"]`. The wrapper defaults `nonConeMode`
  to true here too. In cone mode every entry is a directory and every file at
  the repository root is always checked out, so `"/*.json"` would also fetch
  `README.md`, `.gitattributes` and the rest of the root. Passing both `files`
  and `sparseCheckout` is an error.
- **`rev` must be a full 40-hex commit, and `tag` is refused.** Branches and
  tags can move, and the default name and version come from the commit. The
  commit is the `sha` field of
  `https://huggingface.co/api/models/<owner>/<repo>`, or an entry in the
  repository's commit history.
- **`license` defaults to `lib.licenses.unfree`, on purpose.** nixpkgs has no
  `licenses.unknown`, and check-meta counts a derivation with no `meta.license`
  as free (`hasUnfreeLicense` requires `meta.license` to be set). So weights
  whose licence nobody stated need `allowUnfree` (or an `allowUnfreePredicate`)
  to evaluate, and Hydra-style public caches will not build them. That does not
  stop you pushing them to a cache of your own. Read the `license:` field of the
  repository's `README.md` front matter at the pinned `rev` and pass the
  matching `lib.licenses.*` value. Pass it as `license`, not `meta.license`.
- **`licenseFile` / `attribution`** are optional, for licences that require the
  notice to travel with the work when the repository does not ship it. If the
  repository ships its own `LICENSE`, select it instead. Setting either wraps
  the fetched tree in a derivation that symlinks its top-level entries and adds
  `LICENSE` / `ATTRIBUTION` at the root. The build fails if the fetched tree
  already has that name, in any case. The wrapper links the same fetched tree,
  exposed as `passthru.fetched`, so the weights are stored once. Both layers
  carry the same `meta`, licence included.
- **`name`** defaults to the lowercased repo plus the short rev (nixpkgs uses
  `"source"`), and `meta.description` to
  `<repoId> at <short rev> (Hugging Face)`. `pname` is always the lowercased
  repo and `version` the short rev, so an `allowUnfreePredicate` on
  `lib.getName` survives rev bumps and `name` overrides. `meta.position` points
  at your `rev`, not at the wrapper.
- **No `.override`.** The one nixpkgs attaches would call `fetchFromHuggingFace`
  directly, skipping the defaults and checks above, and keep the old name after
  a rev change. Call the wrapper again instead. `.overrideAttrs` is kept.

Getting the hash works as for any fixed-output fetcher. Pass
`hash = lib.fakeHash`, build, and copy the `got:` value. The store path depends
only on the name and hash, and the default name does not encode the selection.
So set `hash = lib.fakeHash` again after every change to `files` or
`sparseCheckout`, or Nix finds the old path already valid and silently returns
the old tree.

`packages/hugging-face/checks.nix` tests the wrapper offline: a stub fetcher
records what it passes to nixpkgs, and the real fetcher is only evaluated.
Fetching itself is nixpkgs' to test.

## Package table

| Package              | Group      | Source                  | Build                     | nixpkgs               | Tests         | Smoke               |
| -------------------- | ---------- | ----------------------- | ------------------------- | --------------------- | ------------- | ------------------- |
| agnix                | root       | GitHub main             | cargo                     | —                     | cargo test    | --version + MCP/LSP |
| chatgpt-codex        | root       | GitHub releases         | pre-built binary (musl)   | —                     | —             | --version           |
| claude-code          | root       | GCS manifest            | pre-built binary          | —                     | —             | binary              |
| copilot-cli          | root       | GitHub releases         | pre-built binary          | `github-copilot-cli`  | —             | binary              |
| kimchi               | root       | GitHub archive          | bun + go (source)         | —                     | —             | --version           |
| kiro-cli             | root       | AWS manifest            | pre-built binary          | `kiro-cli`            | —             | binary              |
| kiro-gateway         | root       | GitHub main             | python                    | —                     | pytest (1413) | —                   |
| semble               | root       | flake input (unchanged) | python                    | —                     | upstream      | --help              |
| aihubmix-mcp         | mcpServers | npm tarball (manual)    | npm (vendored lock+patch) | —                     | —             | MCP stdio marker    |
| context7-mcp         | mcpServers | GitHub main             | pnpm (nixpkgs override)   | `context7-mcp`        | vitest (2)    | version check       |
| effect-mcp           | mcpServers | GitHub main             | pnpm                      | —                     | —             | MCP stdin           |
| git-intel-mcp        | mcpServers | GitHub main             | npm                       | —                     | vitest (40)   | MCP stdin           |
| github-mcp           | mcpServers | GitHub main             | go (nixpkgs override)     | `github-mcp-server`   | go test       | MCP stdin           |
| kagi-mcp             | mcpServers | GitHub main             | python                    | —                     | —             | MCP stdin           |
| mcp-language-server  | mcpServers | GitHub main             | go (nixpkgs override)     | `mcp-language-server` | go test       | MCP stdin           |
| mcp-proxy            | mcpServers | GitHub main             | python (nixpkgs override) | `mcp-proxy`           | pytest        | MCP stdin           |
| nixos-mcp            | mcpServers | flake input             | —                         | —                     | upstream      | MCP stdin           |
| serena-mcp           | mcpServers | flake input             | —                         | —                     | —             | MCP stdin           |
| semble-mcp           | mcpServers | same as `semble`        | —                         | —                     | upstream      | MCP initialize      |
| sympy-mcp            | mcpServers | GitHub main             | python                    | —                     | pytest (62)   | MCP stdin           |
| modelcontextprotocol | mcpServers | GitHub main             | npm + python              | —                     | pytest        | all 6 bins          |
| git-absorb           | gitTools   | GitHub main             | cargo (nixpkgs override)  | `git-absorb`          | cargo test    | --version           |
| git-branchless       | gitTools   | flake input             | cargo (upstream overlay)  | —                     | upstream      | —                   |
| git-revise           | gitTools   | GitHub main             | python (nixpkgs override) | `git-revise`          | pytest        | nixpkgs             |
| beads                | devTools   | GitHub stable pair      | go (nixpkgs overrides)    | `beads` + `dolt`      | go test       | version + wrapper   |
| gh                   | devTools   | GitHub archive          | go (nixpkgs override)     | `gh`                  | — (doCheck 0) | --version           |
| glab                 | devTools   | GitLab tag (fetcher)    | go (nixpkgs override)     | `glab`                | —             | --version           |
| oxlint               | devTools   | GitHub main             | pnpm (nixpkgs override)   | `oxlint`              | installCheck  | --type-aware        |
| tsgolint             | devTools   | GitHub main             | go (nixpkgs override)     | `tsgolint`            | upstream      | --help              |
| arkenfox             | generic    | GitHub archive          | files only                | —                     | —             | —                   |
| bruno                | generic    | GitHub tag (fetcher)    | npm (nixpkgs override)    | `bruno`               | —             | —                   |
| btop                 | generic    | GitHub archive          | cmake (nixpkgs override)  | `btop`                | —             | --version           |
| bun                  | generic    | GitHub releases         | pre-built binary          | `bun`                 | —             | —                   |
| catppuccin-btop      | generic    | GitHub archive          | files only                | —                     | —             | —                   |
| dns-root-hints       | generic    | InterNIC (no version)   | files only                | —                     | —             | —                   |
| fblog                | generic    | GitHub archive          | cargo (nixpkgs override)  | `fblog`               | —             | --version           |
| gluetun              | generic    | GitHub archive          | go (linux only)           | —                     | — (subPkg)    | starts + exits      |
| oh-my-posh           | generic    | GitHub archive          | go (nixpkgs override)     | `oh-my-posh`          | go test       | --version           |
| otel-tui             | generic    | GitHub archive          | go (nixpkgs override)     | `otel-tui`            | go test       | --version           |
| pnpm_10              | generic    | npm `latest-10` tag     | files only (nixpkgs ovr)  | `pnpm_10`             | —             | --version           |
| pnpm_11              | generic    | npm `latest-11` tag     | files only (nixpkgs ovr)  | `pnpm_11`             | —             | --version           |
| pnpm_12              | generic    | npm `latest-12` tag     | pre-built binary          | — (no `pnpm_12`)      | —             | --version           |
| agnix-mcp            | mcpServers | mainProgram override    | —                         | —                     | —             | —                   |
| agnix-lsp            | lspServers | mainProgram override    | —                         | —                     | —             | —                   |
