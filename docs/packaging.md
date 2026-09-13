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
  `dolt`, `gh`, `gluetun`, `oh-my-posh`, `otel-tui`): a Go vendor set cannot be
  derived from a lockfile the way `importCargoLock` derives one from
  `Cargo.lock`, so `vendorHash` has to be recorded — and it goes in the sidecar,
  never inline, because `ghArchiveUpdateScript` would otherwise leave it stale
  on every bump (the same transitive-hash gap as an inline `cargoHash`).
  `mkUpdateScript` rebuilds the sidecar from scratch, destroying any key it does
  not write itself, so each package passes `extraExtract = "${fixVendorHash}"`
  and reads `sources.vendorHash or lib.fakeHash` to cover the window between the
  two writes. `vu.mkGoVendorFix` builds `<attr>.goModules` through the flake's
  own `packages` output and scrapes the `got:` hash out of a `-go-modules`
  mismatch; it is also exposed standalone as `passthru.fixVendorHash`, because a
  nixpkgs or toolchain bump can invalidate a vendor hash with no version bump at
  all. `passthru` must be MERGED — `buildGoModule` hangs `goModules` and
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
- **Upstream's own flake, re-exported** (`strictdoc`): same `//`-not-
  `overrideAttrs` contract as `semble`, and the same reason — identity with
  upstream's build. It replaced a first-party nixpkgs override that had to pin
  `reqif` forward and relax `pygments`; upstream's flake is a uv2nix set built
  from the repository's `uv.lock`, which pins every dependency to the artifact
  the release was tested against, so both adjustments are dead rather than
  merely unnecessary. The input carries NO `follows`: rewriting its nixpkgs
  would fork a package set this repo does not own, and leaving it alone is what
  makes the store path independent of a consumer's pin. What the shape costs a
  CONSUMER: the package is `mkApplication` over a venv, so `$out` is
  `bin/strictdoc` and nothing else — no interpreter, no `site-packages` — and
  its `dependencies` is a uv2nix name → extras ATTRSET, not nixpkgs' list of
  derivations. Anything wanting strictdoc as a LIBRARY has to go through that
  script's shebang. The one consumer that does is NOT an overlay:
  `packages/strictdoc-grammar/lib/mkExtract.nix`, which the `ai.strictdoc`
  devenv module and the `strictdoc-grammar-*` checks build. Wrapping belongs to
  the module that consumes a package, not to the overlay that converts it.
- **Patched grammar source, regenerated at build time**
  (`tree-sitter-strictdoc`): `pkgs.tree-sitter.buildGrammar` with
  `generate = true` plus a `preBuild` override naming the grammar's actual entry
  point (`grammar/<name>.js`) — its own `preBuild` runs a bare
  `tree-sitter generate` that assumes the grammar lives at the source root,
  which this one does not. The `patches` target the grammar DEFINITION, never
  the generated `src/parser.c`; skipping the `preBuild` override is a silent
  no-op that ships upstream's unpatched parser with a green build. See
  `packages/semble/.sdoc/dec-grammar-patch-not-fork.sdoc`
  (DEC-GRAMMAR-PATCH-NOT-FORK) and
  `checks/strictdoc/strictdoc-grammar-corpus.nix` for the regression gate.
- **In-repo source** (`strictdoc-toolchain-source`): a native package under the
  StrictDoc grammar owner assembles a filtered consumer flake.
  `nix build .#strictdoc-toolchain-source` exports the public grammar library,
  devenv module and installed scribe implementation with the repository's pinned
  upstream StrictDoc dependency. The explicit source lists exclude grammar
  values, project semantics, document corpus, board assets and tests. Its output
  uses fixed consumer paths even when the source owner is renamed. This source
  artifact has no independent upstream version or update target.

## Package table

| Package               | Group      | Source                  | Build                     | nixpkgs               | Tests         | Smoke                        |
| --------------------- | ---------- | ----------------------- | ------------------------- | --------------------- | ------------- | ---------------------------- |
| agnix                 | root       | GitHub main             | cargo                     | —                     | cargo test    | --version + MCP/LSP          |
| chatgpt-codex         | root       | GitHub releases         | pre-built binary (musl)   | —                     | —             | --version                    |
| claude-code           | root       | GCS manifest            | pre-built binary          | —                     | —             | binary                       |
| copilot-cli           | root       | GitHub releases         | pre-built binary          | `github-copilot-cli`  | —             | binary                       |
| kimchi                | root       | GitHub releases         | pre-built binary (bun)    | —                     | —             | --version                    |
| kiro-cli              | root       | AWS manifest            | pre-built binary          | `kiro-cli`            | —             | binary                       |
| kiro-gateway          | root       | GitHub main             | python                    | —                     | pytest (1413) | —                            |
| semble                | root       | flake input (unchanged) | python                    | —                     | upstream      | --help                       |
| aihubmix-mcp          | mcpServers | npm tarball (manual)    | npm (vendored lock+patch) | —                     | —             | MCP stdio marker             |
| context7-mcp          | mcpServers | GitHub main             | pnpm (nixpkgs override)   | `context7-mcp`        | vitest (2)    | version check                |
| effect-mcp            | mcpServers | GitHub main             | pnpm                      | —                     | —             | MCP stdin                    |
| git-intel-mcp         | mcpServers | GitHub main             | npm                       | —                     | vitest (40)   | MCP stdin                    |
| github-mcp            | mcpServers | GitHub main             | go (nixpkgs override)     | `github-mcp-server`   | go test       | MCP stdin                    |
| kagi-mcp              | mcpServers | GitHub main             | python                    | —                     | —             | MCP stdin                    |
| mcp-language-server   | mcpServers | GitHub main             | go (nixpkgs override)     | `mcp-language-server` | go test       | MCP stdin                    |
| mcp-proxy             | mcpServers | GitHub main             | python (nixpkgs override) | `mcp-proxy`           | pytest        | MCP stdin                    |
| nixos-mcp             | mcpServers | flake input             | —                         | —                     | upstream      | MCP stdin                    |
| serena-mcp            | mcpServers | flake input             | —                         | —                     | —             | MCP stdin                    |
| semble-mcp            | mcpServers | same as `semble`        | —                         | —                     | upstream      | MCP initialize               |
| sympy-mcp             | mcpServers | GitHub main             | python                    | —                     | pytest (62)   | MCP stdin                    |
| modelcontextprotocol  | mcpServers | GitHub main             | npm + python              | —                     | pytest        | all 6 bins                   |
| git-absorb            | gitTools   | GitHub main             | cargo (nixpkgs override)  | `git-absorb`          | cargo test    | --version                    |
| git-branchless        | gitTools   | flake input             | cargo (upstream overlay)  | —                     | upstream      | —                            |
| git-revise            | gitTools   | GitHub main             | python (nixpkgs override) | `git-revise`          | pytest        | nixpkgs                      |
| beads                 | devTools   | GitHub stable pair      | go (nixpkgs overrides)    | `beads` + `dolt`      | go test       | version + wrapper            |
| gh                    | devTools   | GitHub archive          | go (nixpkgs override)     | `gh`                  | — (doCheck 0) | --version                    |
| glab                  | devTools   | GitLab tag (fetcher)    | go (nixpkgs override)     | `glab`                | —             | --version                    |
| oxlint                | devTools   | GitHub main             | pnpm (nixpkgs override)   | `oxlint`              | installCheck  | --type-aware                 |
| strictdoc             | devTools   | flake input (unchanged) | uv2nix (upstream flake)   | —                     | —             | —                            |
| tsgolint              | devTools   | GitHub main             | go (nixpkgs override)     | `tsgolint`            | upstream      | --help                       |
| arkenfox              | generic    | GitHub archive          | files only                | —                     | —             | —                            |
| bruno                 | generic    | GitHub tag (fetcher)    | npm (nixpkgs override)    | `bruno`               | —             | —                            |
| btop                  | generic    | GitHub archive          | cmake (nixpkgs override)  | `btop`                | —             | --version                    |
| bun                   | generic    | GitHub releases         | pre-built binary          | `bun`                 | —             | —                            |
| catppuccin-btop       | generic    | GitHub archive          | files only                | —                     | —             | —                            |
| dns-root-hints        | generic    | InterNIC (no version)   | files only                | —                     | —             | —                            |
| fblog                 | generic    | GitHub archive          | cargo (nixpkgs override)  | `fblog`               | —             | --version                    |
| gluetun               | generic    | GitHub archive          | go (linux only)           | —                     | — (subPkg)    | starts + exits               |
| oh-my-posh            | generic    | GitHub archive          | go (nixpkgs override)     | `oh-my-posh`          | go test       | --version                    |
| otel-tui              | generic    | GitHub archive          | go (nixpkgs override)     | `otel-tui`            | go test       | --version                    |
| pnpm_10               | generic    | npm `latest-10` tag     | files only (nixpkgs ovr)  | `pnpm_10`             | —             | --version                    |
| pnpm_11               | generic    | npm `latest-11` tag     | files only (nixpkgs ovr)  | `pnpm_11`             | —             | --version                    |
| pnpm_12               | generic    | npm `latest-12` tag     | pre-built binary          | — (no `pnpm_12`)      | —             | --version                    |
| tree-sitter-strictdoc | generic    | GitHub main (patched)   | tree-sitter buildGrammar  | —                     | corpus check  | parser loads + language attr |
| agnix-mcp             | mcpServers | mainProgram override    | —                         | —                     | —             | —                            |
| agnix-lsp             | lspServers | mainProgram override    | —                         | —                     | —             | —                            |
