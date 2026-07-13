# Overlay Package Index

Quick-reference for how each package is sourced, built, and updated.

## Source pattern

All packages pin `rev` + `hash` inline in their overlay `.nix` file.
Versions computed at eval time via `overlays/lib.nix:mkVersion`
(`{upstream}+{shortRev}`). Updates via the ninja DAG pipeline:
`nix run .#generate-update-ninja && ninja -j4 -v -f .update.ninja update-report`

- **Main-tracking**: `git ls-remote` for rev, `nix flake prefetch` for hash,
  `nix-update --version skip` for dep hashes. Config in `config/update-matrix.nix`.
- **Binary packages**: custom `updateScript` via `mkUpdateScript` in `overlays/lib.nix`.
  Per-platform hashes in `<name>-sources.json`.
- **Flake inputs**: consumed from `inputs.<name>.packages`, updated via `nix flake update`.
- **In-repo source**: packaged from a path in this repo (no upstream rev/hash,
  not version-tracked). Currently only `kiro-memory-distiller`
  (`packages/kiro-cli/memory/`). Its whole system — the distiller pipeline, the
  v3 hook set, the buffer/archive tiers, and the `openmemory-mem` backend seam —
  is documented end-to-end in
  [`packages/kiro-cli/docs/kiro-auto-memory.md`](../packages/kiro-cli/docs/kiro-auto-memory.md).

## Package table

| Package               | Group      | Source               | Build                     | nixpkgs               | Tests         | Smoke               |
| --------------------- | ---------- | -------------------- | ------------------------- | --------------------- | ------------- | ------------------- |
| agnix                 | root       | GitHub main          | cargo                     | —                     | cargo test    | --version + MCP/LSP |
| claude-code           | root       | GCS manifest         | pre-built binary          | —                     | —             | binary              |
| copilot-cli           | root       | GitHub releases      | pre-built binary          | `github-copilot-cli`  | —             | binary              |
| kimchi                | root       | GitHub releases      | pre-built binary (bun)    | —                     | —             | --version           |
| kiro-cli              | root       | AWS manifest         | pre-built binary          | `kiro-cli`            | —             | binary              |
| kiro-gateway          | root       | GitHub main          | python                    | —                     | pytest (1413) | —                   |
| kiro-memory-distiller | root       | in-repo              | bun wrapper               | —                     | bun test (80) | stdin exit 0        |
| context7-mcp          | mcpServers | GitHub main          | pnpm (nixpkgs override)   | `context7-mcp`        | vitest (2)    | version check       |
| effect-mcp            | mcpServers | GitHub main          | pnpm                      | —                     | —             | MCP stdin           |
| git-intel-mcp         | mcpServers | GitHub main          | npm                       | —                     | vitest (40)   | MCP stdin           |
| github-mcp            | mcpServers | GitHub main          | go (nixpkgs override)     | `github-mcp-server`   | go test       | MCP stdin           |
| kagi-mcp              | mcpServers | GitHub main          | python                    | —                     | —             | MCP stdin           |
| mcp-language-server   | mcpServers | GitHub main          | go (nixpkgs override)     | `mcp-language-server` | go test       | MCP stdin           |
| mcp-proxy             | mcpServers | GitHub main          | python (nixpkgs override) | `mcp-proxy`           | pytest        | MCP stdin           |
| nixos-mcp             | mcpServers | flake input          | —                         | —                     | upstream      | MCP stdin           |
| openmemory-mcp        | mcpServers | GitHub main          | npm                       | `openmemory-mem`      | bun test (30) | MCP stdin + mem     |
| serena-mcp            | mcpServers | flake input          | —                         | —                     | —             | MCP stdin           |
| sympy-mcp             | mcpServers | GitHub main          | python                    | —                     | pytest (62)   | MCP stdin           |
| modelcontextprotocol  | mcpServers | GitHub main          | npm + python              | —                     | pytest        | all 6 bins          |
| git-absorb            | gitTools   | GitHub main          | cargo (nixpkgs override)  | `git-absorb`          | cargo test    | --version           |
| git-branchless        | gitTools   | flake input          | cargo (upstream overlay)  | —                     | upstream      | —                   |
| git-revise            | gitTools   | GitHub main          | python (nixpkgs override) | `git-revise`          | pytest        | nixpkgs             |
| agnix-mcp             | mcpServers | mainProgram override | —                         | —                     | —             | —                   |
| agnix-lsp             | lspServers | mainProgram override | —                         | —                     | —             | —                   |
