# Overlay Package Index

Quick-reference for how each package is sourced, built, and maintained.
See `memory/project_nvfetcher_overlay_pattern.md` for the full pattern
documentation. This file will become a fragment for the doc site and
AI instruction fanout.

## Source preference order

1. **Flake input** — upstream has a nix flake with package output → add as flake input, skip nvfetcher
2. **nixpkgs override** — package in nixpkgs → `overrideAttrs` to pin version + src from nvfetcher
3. **GitHub releases** (nvfetcher) — not in nixpkgs → build from source, match upstream build tool
4. **GitHub main/commit** (nvfetcher) — no releases → track main branch
5. **npm/PyPI** — last resort, only when no GitHub source exists

## Package table

| Package                 | Group      | Source                                       | Build                               | nixpkgs               | Versioning                      | Dep Hashes                 | Unfree | Notes                                                                                                            |
| ----------------------- | ---------- | -------------------------------------------- | ----------------------------------- | --------------------- | ------------------------------- | -------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------- |
| agnix                   | root       | nvfetcher: GitHub release                    | cargo (from-scratch)                | —                     | release tags                    | cargoHash (nvfetcher)      | no     | multi-binary: CLI + LSP + MCP. Has flake but devShell only, no pkg output                                        |
| any-buddy               | root       | nvfetcher: GitHub release                    | bun (from-scratch)                  | —                     | release tags                    | —                          | no     | Buddy salt brute-forcer                                                                                          |
| claude-code             | root       | nvfetcher: npm registry                      | npm (nixpkgs override)              | `claude-code`         | npm latest                      | npmDepsHash (hashes.json)  | yes    | Proprietary. npm IS the primary distribution                                                                     |
| copilot-cli             | root       | nvfetcher: GitHub release binary             | pre-built binary (nixpkgs override) | `github-copilot-cli`  | release tags                    | —                          | yes    | Proprietary pre-built binary, per-platform. NB: nixpkgs `copilot-cli` is AWS Copilot (different tool, free)      |
| kiro-cli                | root       | nvfetcher: AWS manifest                      | pre-built binary (nixpkgs override) | `kiro-cli`            | AWS manifest                    | —                          | yes    | Proprietary pre-built binary, per-platform                                                                       |
| kiro-cli-darwin         | root       | nvfetcher: AWS manifest                      | pre-built .dmg                      | —                     | AWS manifest (same as kiro-cli) | —                          | yes    | Darwin variant of kiro-cli                                                                                       |
| kiro-gateway            | root       | nvfetcher: GitHub main                       | python (from-scratch)               | —                     | main branch commit              | —                          | no     | No releases. TODO: check if pnpm/npm                                                                             |
| context7-mcp            | mcpServers | nvfetcher: GitHub tag (scoped)               | pnpm (nixpkgs override)             | `context7-mcp`        | npm latest → GitHub tag         | pnpmDepsHash (hashes.json) | no     | Scoped tag `@upstash/context7-mcp@<ver>` needs url.name workaround. Uses runCommandLocal unpack                  |
| effect-mcp              | mcpServers | nvfetcher: npm registry                      | npm (from-scratch)                  | —                     | npm latest                      | npmDepsHash (hashes.json)  | no     | TODO: switch to GitHub (tim-smart/effect-mcp). Has flake but devShell only. Build with pnpm (has pnpm-lock.yaml) |
| fetch-mcp               | mcpServers | nvfetcher: PyPI                              | python (from-scratch)               | `mcp-server-fetch`\*  | PyPI latest                     | —                          | no     | \*Not in pinned nixpkgs rev. TODO: switch to GitHub (modelcontextprotocol/servers mono-repo) after nixpkgs bump  |
| git-intel-mcp           | mcpServers | nvfetcher: GitHub main                       | npm (from-scratch)                  | —                     | main branch commit              | npmDepsHash (hashes.json)  | no     | No releases. TODO: verify build tool matches lockfile                                                            |
| git-mcp                 | mcpServers | nvfetcher: PyPI                              | python (from-scratch)               | `mcp-server-git`\*    | PyPI latest                     | —                          | no     | \*Not in pinned nixpkgs rev. TODO: switch to GitHub (modelcontextprotocol/servers mono-repo) after nixpkgs bump  |
| github-mcp              | mcpServers | nvfetcher: GitHub release                    | go (nixpkgs override)               | `github-mcp-server`   | release tags                    | vendorHash (hashes.json)   | no     | Strips "v" prefix from nvfetcher version                                                                         |
| kagi-mcp                | mcpServers | nvfetcher: PyPI                              | python (from-scratch)               | —                     | PyPI latest                     | —                          | no     | TODO: switch to GitHub (kagisearch/kagimcp). Also tracks kagiapi dependency                                      |
| mcp-language-server     | mcpServers | nvfetcher: GitHub release                    | go (nixpkgs override)               | `mcp-language-server` | release tags                    | vendorHash (hashes.json)   | no     |                                                                                                                  |
| mcp-proxy               | mcpServers | nvfetcher: PyPI                              | python (nixpkgs override)           | `mcp-proxy`           | PyPI latest                     | —                          | no     | TODO: switch to GitHub (sparfenyuk/mcp-proxy)                                                                    |
| nixos-mcp               | mcpServers | flake input: `mcp-nixos`                     | — (flake input)                     | —                     | flake follows                   | —                          | no     | Consumed via `inputs.mcp-nixos.packages`                                                                         |
| openmemory-mcp          | mcpServers | nvfetcher: npm registry                      | npm (from-scratch)                  | —                     | npm latest                      | npmDepsHash (hashes.json)  | no     | TODO: switch to GitHub (openmemory/openmemory). 655-line typed settings module                                   |
| sequential-thinking-mcp | mcpServers | nvfetcher: npm registry                      | npm (from-scratch)                  | —                     | npm latest                      | npmDepsHash (hashes.json)  | no     | TODO: switch to GitHub (modelcontextprotocol/servers mono-repo)                                                  |
| serena-mcp              | mcpServers | flake input: `serena`                        | — (flake input)                     | —                     | flake follows                   | —                          | no     | Consumed via `inputs.serena.packages`                                                                            |
| sympy-mcp               | mcpServers | nvfetcher: GitHub main                       | python (nixpkgs-like from-scratch)  | —                     | main branch commit              | —                          | no     | No releases. Overrides own derivation                                                                            |
| git-absorb              | gitTools   | nvfetcher: GitHub release                    | cargo (nixpkgs override)            | `git-absorb`          | release tags                    | cargoHash (nvfetcher)      | no     |                                                                                                                  |
| git-branchless          | gitTools   | nvfetcher: GitHub release                    | cargo (nixpkgs override)            | `git-branchless`      | release tags                    | cargoHash (nvfetcher)      | no     |                                                                                                                  |
| git-revise              | gitTools   | nvfetcher: GitHub release (via PyPI version) | python (nixpkgs override)           | `git-revise`          | PyPI version → GitHub "v" tag   | —                          | no     | Version tracked from PyPI, source from GitHub                                                                    |
| agnix-mcp               | mcpServers | — (mainProgram override of agnix)            | —                                   | —                     | —                               | —                          | no     | `overrideAttrs { meta.mainProgram = "agnix-mcp"; }`                                                              |
| agnix-lsp               | lspServers | — (mainProgram override of agnix)            | —                                   | —                     | —                               | —                          | no     | `overrideAttrs { meta.mainProgram = "agnix-lsp"; }`                                                              |

## Dep hash computation

Hashes in `hashes.json` that nvfetcher can't compute (pnpmDepsHash, vendorHash):

```bash
# Set to dummy in hashes.json, then:
nix build .#<pkg> 2>&1 | grep "got:" | awk '{print $2}'
# For pnpm packages, build just the deps (faster):
nix build .#<pkg>.pnpmDeps 2>&1 | grep "got:" | awk '{print $2}'
```

Target: automated in the update script for CI (hourly Copilot-driven).

## TODO items visible in table

Packages marked TODO above need source strategy changes (npm/PyPI → GitHub).
These require `nvfetcher.toml` edits + `nvfetcher -o .nvfetcher -k keyfile.toml` + hash recomputation. See `docs/plan.md` "Audit all overlay source + build tools" backlog item.
