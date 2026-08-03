# Overlay Package Index

Quick-reference for how each package is sourced, built, and updated.

## Source pattern

All packages pin `rev` + `hash` inline in their overlay `.nix` file. Versions
computed at eval time via `overlays/lib.nix:mkVersion`
(`{upstream}+{shortRev}`). Updates via the ninja DAG pipeline:
`nix run .#generate-update-ninja && ninja -j4 -v -f .update.ninja update-report`

- **Main-tracking**: `git ls-remote` for rev, `nix flake prefetch` for hash,
  `nix-update --version skip` for dep hashes. Config in `config.update.targets`
  (`config/update-targets.nix`).
- **Binary packages**: custom `updateScript` via `mkUpdateScript` in
  `overlays/lib.nix`. Per-platform hashes in `<name>-sources.json`.
- **GitHub repo-archive tarballs** (`fetchzip` consumers):
  `ghArchiveUpdateScript` in `overlays/lib.nix` — one `repo` derives both the
  archive URL and the release-tag version check, and prefetches with `--unpack`
  so the recorded hash is over the unpacked NAR. Grouped subtrees pass
  `sourcesFile` explicitly, since the default assumes
  `overlays/<pname>-sources.json`. A Rust package on this pattern must NOT keep
  an inline `cargoHash`: `ghArchiveUpdateScript` refreshes only the src hash, so
  the vendor hash would go stale on every bump. Override `cargoDeps` with
  `rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }` instead
  (IFD) so one hash covers both — see `generic/fblog.nix` and
  `git-tools/git-branchless.nix`.
- **Go packages with a sidecar `vendorHash`** (`gh`, `gluetun`, `oh-my-posh`,
  `otel-tui`): a Go vendor set cannot be derived from a lockfile the way
  `importCargoLock` derives one from `Cargo.lock`, so `vendorHash` has to be
  recorded — and it goes in the sidecar, never inline, because
  `ghArchiveUpdateScript` would otherwise leave it stale on every bump (the same
  transitive-hash gap as an inline `cargoHash`). `mkUpdateScript` rebuilds the
  sidecar from scratch, destroying any key it does not write itself, so each
  package passes `extraExtract = "${fixVendorHash}"` and reads
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
  the sidecar's version and running the update script.
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
- **Go toolchain gaps** (`gluetun`, `oh-my-posh`): declare the package's go.mod
  floor and let `vu.goToolchainForFloor` DERIVE the toolchain — `ourPkgs.go`
  while our pin satisfies the floor, otherwise the lowest `go-bin`
  (purpleclay/go-overlay) release that does, and a throw if nothing does. Never
  pin a toolchain version; a pin cannot tell a live gap from a rotted downgrade.
  `checks/go-toolchain-floor.nix` covers all three branches.
- **Version-independent URLs** (`dns-root-hints`): the version-equality early
  exit is not a valid change signal, so pass `alwaysPrefetch = true` to
  `mkUpdateScript`. It prefetches every run and decides whether to write by
  comparing the freshly built sidecar against the committed one.
- **Several majors of one upstream** (`pnpm_10`, `pnpm_11`): one shared builder
  (`generic/pnpm-major.nix`) parameterized by the major, with a two-line file
  per major so each gets its own `--override-filename` path and sidecar. The
  version check reads the registry's per-major channel, and an eval-time guard
  rejects a sidecar whose major does not match the attribute.
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
  `dist-tags` — the same shape `generic/pnpm-major.nix` uses. Note
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
  not version-tracked). Currently only `kiro-memory-distiller`
  (`packages/kiro-cli/memory/`). Its whole system — the distiller pipeline, the
  v3 hook set, the buffer/archive tiers, and the `openmemory-mem` backend seam —
  is documented end-to-end in
  [`packages/kiro-cli/docs/kiro-auto-memory.md`](../packages/kiro-cli/docs/kiro-auto-memory.md).

## Package table

| Package               | Group      | Source                  | Build                     | nixpkgs               | Tests         | Smoke               |
| --------------------- | ---------- | ----------------------- | ------------------------- | --------------------- | ------------- | ------------------- |
| agnix                 | root       | GitHub main             | cargo                     | —                     | cargo test    | --version + MCP/LSP |
| chatgpt-codex         | root       | GitHub releases         | pre-built binary (musl)   | —                     | —             | --version           |
| claude-code           | root       | GCS manifest            | pre-built binary          | —                     | —             | binary              |
| copilot-cli           | root       | GitHub releases         | pre-built binary          | `github-copilot-cli`  | —             | binary              |
| kimchi                | root       | GitHub releases         | pre-built binary (bun)    | —                     | —             | --version           |
| kiro-cli              | root       | AWS manifest            | pre-built binary          | `kiro-cli`            | —             | binary              |
| kiro-gateway          | root       | GitHub main             | python                    | —                     | pytest (1413) | —                   |
| kiro-memory-distiller | root       | in-repo                 | bun wrapper               | —                     | bun test (80) | stdin exit 0        |
| semble                | root       | flake input (unchanged) | python                    | —                     | upstream      | --help              |
| aihubmix-mcp          | mcpServers | npm tarball (manual)    | npm (vendored lock+patch) | —                     | —             | MCP stdio marker    |
| context7-mcp          | mcpServers | GitHub main             | pnpm (nixpkgs override)   | `context7-mcp`        | vitest (2)    | version check       |
| effect-mcp            | mcpServers | GitHub main             | pnpm                      | —                     | —             | MCP stdin           |
| git-intel-mcp         | mcpServers | GitHub main             | npm                       | —                     | vitest (40)   | MCP stdin           |
| github-mcp            | mcpServers | GitHub main             | go (nixpkgs override)     | `github-mcp-server`   | go test       | MCP stdin           |
| kagi-mcp              | mcpServers | GitHub main             | python                    | —                     | —             | MCP stdin           |
| mcp-language-server   | mcpServers | GitHub main             | go (nixpkgs override)     | `mcp-language-server` | go test       | MCP stdin           |
| mcp-proxy             | mcpServers | GitHub main             | python (nixpkgs override) | `mcp-proxy`           | pytest        | MCP stdin           |
| nixos-mcp             | mcpServers | flake input             | —                         | —                     | upstream      | MCP stdin           |
| openmemory-mcp        | mcpServers | GitHub main             | npm                       | `openmemory-mem`      | bun test (30) | MCP stdin + mem     |
| serena-mcp            | mcpServers | flake input             | —                         | —                     | —             | MCP stdin           |
| semble-mcp            | mcpServers | same as `semble`        | —                         | —                     | upstream      | MCP initialize      |
| sympy-mcp             | mcpServers | GitHub main             | python                    | —                     | pytest (62)   | MCP stdin           |
| modelcontextprotocol  | mcpServers | GitHub main             | npm + python              | —                     | pytest        | all 6 bins          |
| git-absorb            | gitTools   | GitHub main             | cargo (nixpkgs override)  | `git-absorb`          | cargo test    | --version           |
| git-branchless        | gitTools   | flake input             | cargo (upstream overlay)  | —                     | upstream      | —                   |
| git-revise            | gitTools   | GitHub main             | python (nixpkgs override) | `git-revise`          | pytest        | nixpkgs             |
| oxlint                | devTools   | GitHub main             | pnpm (nixpkgs override)   | `oxlint`              | installCheck  | --type-aware        |
| tsgolint              | devTools   | GitHub main             | go (nixpkgs override)     | `tsgolint`            | upstream      | --help              |
| arkenfox              | generic    | GitHub archive          | files only                | —                     | —             | —                   |
| bruno                 | generic    | GitHub tag (fetcher)    | npm (nixpkgs override)    | `bruno`               | —             | —                   |
| btop                  | generic    | GitHub archive          | cmake (nixpkgs override)  | `btop`                | —             | --version           |
| bun                   | generic    | GitHub releases         | pre-built binary          | `bun`                 | —             | —                   |
| catppuccin-btop       | generic    | GitHub archive          | files only                | —                     | —             | —                   |
| dns-root-hints        | generic    | InterNIC (no version)   | files only                | —                     | —             | —                   |
| fblog                 | generic    | GitHub archive          | cargo (nixpkgs override)  | `fblog`               | —             | --version           |
| gh                    | generic    | GitHub archive          | go (nixpkgs override)     | `gh`                  | — (doCheck 0) | --version           |
| gluetun               | generic    | GitHub archive          | go (linux only)           | —                     | — (subPkg)    | starts + exits      |
| oh-my-posh            | generic    | GitHub archive          | go (nixpkgs override)     | `oh-my-posh`          | go test       | --version           |
| otel-tui              | generic    | GitHub archive          | go (nixpkgs override)     | `otel-tui`            | go test       | --version           |
| pnpm_10               | generic    | npm `latest-10` tag     | files only (nixpkgs ovr)  | `pnpm_10`             | —             | --version           |
| pnpm_11               | generic    | npm `latest-11` tag     | files only (nixpkgs ovr)  | `pnpm_11`             | —             | --version           |
| agnix-mcp             | mcpServers | mainProgram override    | —                         | —                     | —             | —                   |
| agnix-lsp             | lspServers | mainProgram override    | —                         | —                     | —             | —                   |
