# Overlays & Packages

agentic-tools exports packages via Nix overlays. Apply the overlay to
your nixpkgs, and the packages become available in `pkgs`.

## Overlays

| Overlay                      | What it adds                                          |
| ---------------------------- | ----------------------------------------------------- |
| `overlays.default`           | All overlays composed                                 |
| `overlays.ai-clis`           | `github-copilot-cli`, `kiro-cli`, `kiro-gateway`      |
| `overlays.coding-standards`  | `coding-standards`                                    |
| `overlays.git-tools`         | `agnix`, `git-absorb`, `git-branchless`, `git-revise` |
| `overlays.mcp-servers`       | `nix-mcp-servers.*`                                   |
| `overlays.stacked-workflows` | `stacked-workflows-content`                           |

Most users should apply `overlays.default`:

```nix
nixpkgs.overlays = [inputs.agentic-tools.overlays.default];
```

## Package Reference

### AI CLIs

| Package              | Description               |
| -------------------- | ------------------------- |
| `github-copilot-cli` | GitHub Copilot CLI        |
| `kiro-cli`           | Kiro CLI                  |
| `kiro-gateway`       | Python proxy API for Kiro |

### Git Tools

| Package          | Description                              |
| ---------------- | ---------------------------------------- |
| `agnix`          | Linter, LSP, and MCP for AI config files |
| `git-absorb`     | Automatic fixup commit routing           |
| `git-branchless` | Anonymous branching, in-memory rebases   |
| `git-revise`     | In-memory commit rewriting               |

### MCP Servers

Available under `pkgs.nix-mcp-servers.*`:

| Package                   | Description                       | Credentials                    |
| ------------------------- | --------------------------------- | ------------------------------ |
| `context7-mcp`            | Library documentation lookup      | None                           |
| `effect-mcp`              | Effect-TS documentation           | None                           |
| `fetch-mcp`               | HTTP fetch + HTML-to-markdown     | None                           |
| `git-intel-mcp`           | Git repository analytics          | None                           |
| `git-mcp`                 | Git operations                    | None                           |
| `github-mcp`              | GitHub platform                   | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| `kagi-mcp`                | Kagi search and summarization     | `KAGI_API_KEY`                 |
| `mcp-language-server`     | LSP-to-MCP bridge                 | None                           |
| `mcp-proxy`               | stdio-to-HTTP bridge              | None                           |
| `nixos-mcp`               | NixOS/Nix documentation           | None                           |
| `openmemory-mcp`          | Persistent memory + vector search | None                           |
| `sequential-thinking-mcp` | Step-by-step reasoning            | None                           |
| `serena-mcp`              | Codebase-aware semantic tools     | None (optional API keys)       |
| `sympy-mcp`               | Symbolic mathematics              | None                           |

### Content Packages

| Package                     | Description                        | passthru                                           |
| --------------------------- | ---------------------------------- | -------------------------------------------------- |
| `coding-standards`          | Reusable coding standard fragments | `.fragments.*`, `.presets.all`, `.presets.minimal` |
| `stacked-workflows-content` | Skills, references, routing-table  | `.fragments.*`, `.skillsDir`, `.referencesDir`     |

## Content Package passthru

Content packages are Nix derivations (store paths with files) that also
carry typed data in `passthru` for eval-time composition.

### coding-standards

```nix
pkgs.coding-standards.passthru.fragments
# => {
#   coding-standards = { text = "..."; description = "..."; priority = 10; };
#   commit-convention = { ... };
#   config-parity = { ... };
#   tooling-preference = { ... };
#   validation = { ... };
# }

pkgs.coding-standards.passthru.presets.all
# => composed fragment with all 5 standards

pkgs.coding-standards.passthru.presets.minimal
# => coding-standards + commit-convention only
```

### stacked-workflows-content

```nix
pkgs.stacked-workflows-content.passthru.fragments.routing-table
# => { text = "..."; description = "Stacked workflow skill routing table"; }

"${pkgs.stacked-workflows-content}/skills/stack-fix"
# => /nix/store/...-stacked-workflows-content/skills/stack-fix/

pkgs.stacked-workflows-content.passthru.skillsDir
# => source path to skills directory (for symlinks)
```

## MCP Package passthru

MCP server packages carry metadata for composing MCP entries:

```nix
pkgs.nix-mcp-servers.github-mcp.mcpName
# => "github-mcp"

# Some packages carry mcpBinary (when it differs from mainProgram):
pkgs.agnix.mcpBinary
# => "agnix-mcp"

# Or mcpArgs (for subcommand-based servers):
pkgs.serena-mcp.mcpArgs
# => ["start-mcp-server"]
```

Use `lib.mkPackageEntry` to derive a complete MCP config entry:

```nix
lib.mkPackageEntry pkgs.nix-mcp-servers.github-mcp
# => { type = "stdio"; command = "/nix/store/.../github-mcp-server"; args = [...]; }
```
