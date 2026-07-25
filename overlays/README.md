# Overlay Package Index

Quick-reference for how each package is sourced, built, and updated.

## Source pattern

All packages pin `rev` + `hash` inline in their overlay `.nix` file.
Versions computed at eval time via `overlays/lib.nix:mkVersion`
(`{upstream}+{shortRev}`). Updates via the ninja DAG pipeline:
`nix run .#generate-update-ninja && ninja -j4 -v -f .update.ninja update-report`

- **Main-tracking**: `git ls-remote` for rev, `nix flake prefetch` for hash,
  `nix-update --version skip` for dep hashes. Config in `config.update.targets`
  (`config/update-targets.nix`).
- **Binary packages**: custom `updateScript` via `mkUpdateScript` in `overlays/lib.nix`.
  Per-platform hashes in `<name>-sources.json`.
- **GitHub repo-archive tarballs** (`fetchzip` consumers): `ghArchiveUpdateScript`
  in `overlays/lib.nix` — one `repo` derives both the archive URL and the
  release-tag version check, and prefetches with `--unpack` so the recorded
  hash is over the unpacked NAR. Grouped subtrees pass `sourcesFile`
  explicitly, since the default assumes `overlays/<pname>-sources.json`.
  A Rust package on this pattern must NOT keep an inline `cargoHash`:
  `ghArchiveUpdateScript` refreshes only the src hash, so the vendor hash
  would go stale on every bump. Override `cargoDeps` with
  `rustPlatform.importCargoLock { lockFile = "${src}/Cargo.lock"; }`
  instead (IFD) so one hash covers both — see `generic/fblog.nix` and
  `git-tools/git-branchless.nix`.
- **Version-independent URLs** (`dns-root-hints`): the version-equality
  early exit is not a valid change signal, so pass `alwaysPrefetch = true`
  to `mkUpdateScript`. It prefetches every run and decides whether to write
  by comparing the freshly built sidecar against the committed one.
- **Several majors of one upstream** (`pnpm_10`, `pnpm_11`): one shared
  builder (`generic/pnpm-major.nix`) parameterized by the major, with a
  two-line file per major so each gets its own `--override-filename` path
  and sidecar. The version check reads the registry's per-major channel,
  and an eval-time guard rejects a sidecar whose major does not match the
  attribute.
- **Flake inputs**: consumed from `inputs.<name>.packages`, updated via `nix flake update`.
- **In-repo source**: packaged from a path in this repo (no upstream rev/hash,
  not version-tracked). Currently only `kiro-memory-distiller`
  (`packages/kiro-cli/memory/`). Its whole system — the distiller pipeline, the
  v3 hook set, the buffer/archive tiers, and the `openmemory-mem` backend seam —
  is documented end-to-end in
  [`packages/kiro-cli/docs/kiro-auto-memory.md`](../packages/kiro-cli/docs/kiro-auto-memory.md).

## Package table

| Package               | Group      | Source                | Build                     | nixpkgs               | Tests         | Smoke               |
| --------------------- | ---------- | --------------------- | ------------------------- | --------------------- | ------------- | ------------------- |
| agnix                 | root       | GitHub main           | cargo                     | —                     | cargo test    | --version + MCP/LSP |
| chatgpt-codex         | root       | GitHub releases       | pre-built binary (musl)   | —                     | —             | --version           |
| claude-code           | root       | GCS manifest          | pre-built binary          | —                     | —             | binary              |
| copilot-cli           | root       | GitHub releases       | pre-built binary          | `github-copilot-cli`  | —             | binary              |
| kimchi                | root       | GitHub releases       | pre-built binary (bun)    | —                     | —             | --version           |
| kiro-cli              | root       | AWS manifest          | pre-built binary          | `kiro-cli`            | —             | binary              |
| kiro-gateway          | root       | GitHub main           | python                    | —                     | pytest (1413) | —                   |
| kiro-memory-distiller | root       | in-repo               | bun wrapper               | —                     | bun test (80) | stdin exit 0        |
| context7-mcp          | mcpServers | GitHub main           | pnpm (nixpkgs override)   | `context7-mcp`        | vitest (2)    | version check       |
| effect-mcp            | mcpServers | GitHub main           | pnpm                      | —                     | —             | MCP stdin           |
| git-intel-mcp         | mcpServers | GitHub main           | npm                       | —                     | vitest (40)   | MCP stdin           |
| github-mcp            | mcpServers | GitHub main           | go (nixpkgs override)     | `github-mcp-server`   | go test       | MCP stdin           |
| kagi-mcp              | mcpServers | GitHub main           | python                    | —                     | —             | MCP stdin           |
| mcp-language-server   | mcpServers | GitHub main           | go (nixpkgs override)     | `mcp-language-server` | go test       | MCP stdin           |
| mcp-proxy             | mcpServers | GitHub main           | python (nixpkgs override) | `mcp-proxy`           | pytest        | MCP stdin           |
| nixos-mcp             | mcpServers | flake input           | —                         | —                     | upstream      | MCP stdin           |
| openmemory-mcp        | mcpServers | GitHub main           | npm                       | `openmemory-mem`      | bun test (30) | MCP stdin + mem     |
| serena-mcp            | mcpServers | flake input           | —                         | —                     | —             | MCP stdin           |
| sympy-mcp             | mcpServers | GitHub main           | python                    | —                     | pytest (62)   | MCP stdin           |
| modelcontextprotocol  | mcpServers | GitHub main           | npm + python              | —                     | pytest        | all 6 bins          |
| git-absorb            | gitTools   | GitHub main           | cargo (nixpkgs override)  | `git-absorb`          | cargo test    | --version           |
| git-branchless        | gitTools   | flake input           | cargo (upstream overlay)  | —                     | upstream      | —                   |
| git-revise            | gitTools   | GitHub main           | python (nixpkgs override) | `git-revise`          | pytest        | nixpkgs             |
| oxlint                | devTools   | GitHub main           | pnpm (nixpkgs override)   | `oxlint`              | installCheck  | --type-aware        |
| tsgolint              | devTools   | GitHub main           | go (nixpkgs override)     | `tsgolint`            | upstream      | --help              |
| arkenfox              | generic    | GitHub archive        | files only                | —                     | —             | —                   |
| btop                  | generic    | GitHub archive        | cmake (nixpkgs override)  | `btop`                | —             | --version           |
| bun                   | generic    | GitHub releases       | pre-built binary          | `bun`                 | —             | —                   |
| catppuccin-btop       | generic    | GitHub archive        | files only                | —                     | —             | —                   |
| dns-root-hints        | generic    | InterNIC (no version) | files only                | —                     | —             | —                   |
| fblog                 | generic    | GitHub archive        | cargo (nixpkgs override)  | `fblog`               | —             | --version           |
| pnpm_10               | generic    | npm `latest-10` tag   | files only (nixpkgs ovr)  | `pnpm_10`             | —             | --version           |
| pnpm_11               | generic    | npm `latest-11` tag   | files only (nixpkgs ovr)  | `pnpm_11`             | —             | --version           |
| agnix-mcp             | mcpServers | mainProgram override  | —                         | —                     | —             | —                   |
| agnix-lsp             | lspServers | mainProgram override  | —                         | —                     | —             | —                   |
