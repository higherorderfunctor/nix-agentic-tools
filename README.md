# nix-agentic-tools

Stacked commit workflows, MCP servers, and declarative configuration for
AI coding CLIs (Claude Code, Copilot, Kiro). Works without Nix; Nix
unlocks overlays, home-manager modules, and devshell integration.

## Quick Start

<details>
<summary><strong>Non-Nix (copy skills into your project)</strong></summary>

Prerequisites: [git-branchless](https://github.com/arxanas/git-branchless),
[git-absorb](https://github.com/tummychow/git-absorb),
[git-revise](https://github.com/mystor/git-revise).

```bash
# Claude Code
cp -r packages/stacked-workflows/skills/stack-* .claude/skills/

# Kiro
cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/

# GitHub Copilot
cp -r packages/stacked-workflows/skills/stack-* .github/skills/
```

Each skill is self-contained with a `SKILL.md` and bundled reference docs.

</details>

<details>
<summary><strong>Home-Manager (system-level declarative config)</strong></summary>

```nix
# flake.nix
inputs.nix-agentic-tools = {
  url = "github:higherorderfunctor/nix-agentic-tools";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Apply overlay
nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

# Home-manager config
imports = [inputs.nix-agentic-tools.homeManagerModules.default];

ai = {
  enable = true;
  claude.enable = true;
  copilot.enable = true;
  kiro.enable = true;
};

stacked-workflows = {
  enable = true;
  gitPreset = "full";
  integrations.claude.enable = true;
};

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = "/run/secrets/github-token";
};
```

See [Home-Manager Setup](docs/src/getting-started/home-manager.md) for
the full guide.

</details>

<details open>
<summary><strong>DevEnv (per-project dev shell)</strong></summary>

```yaml
# devenv.yaml
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
    inputs:
      nixpkgs:
        follows: nixpkgs
```

```nix
# devenv.nix
{inputs, ...}: {
  imports = [inputs.nix-agentic-tools.devenvModules.default];

  ai = {
    enable = true;
    claude.enable = true;
  };

  claude.code = {
    enable = true;
    mcpServers.github-mcp = {
      type = "stdio";
      command = "github-mcp-server";
      args = ["--stdio"];
    };
  };
}
```

See [DevEnv Setup](docs/src/getting-started/devenv.md) for the full
guide.

</details>

## Skills

Stacked commit workflow skills using git-branchless, git-absorb, and
git-revise.

<!-- prettier-ignore -->
| Skill | Description |
|-------|-------------|
| `/stack-fix` | Absorb fixes into correct stack commits |
| `/stack-plan` | Plan and build a commit stack from description or existing commits |
| `/stack-split` | Split a large commit into reviewable atomic commits |
| `/stack-submit` | Sync, validate, push stack, and create stacked PRs |
| `/stack-summary` | Analyze stack quality, flag violations, produce planner-ready summary |
| `/stack-test` | Run tests or formatters across every commit in a stack |

## Packages

<details>
<summary><strong>MCP Servers</strong> (14 servers)</summary>

<!-- prettier-ignore -->
| Server | Description | Credentials |
|--------|-------------|-------------|
| `context7-mcp` | Library documentation lookup | None |
| `effect-mcp` | Effect-TS documentation | None |
| `fetch-mcp` | HTTP fetch + HTML-to-markdown | None |
| `git-intel-mcp` | Git repository analytics | None |
| `git-mcp` | Git operations | None |
| `github-mcp` | GitHub platform integration | Required |
| `kagi-mcp` | Kagi search and summarization | Required |
| `mcp-language-server` | LSP-to-MCP bridge | None |
| `mcp-proxy` | stdio-to-HTTP bridge proxy | None |
| `nixos-mcp` | NixOS and Nix documentation | None |
| `openmemory-mcp` | Persistent memory + vector search | None |
| `sequential-thinking-mcp` | Step-by-step reasoning | None |
| `serena-mcp` | Codebase-aware semantic tools | Optional |
| `sympy-mcp` | Symbolic mathematics | None |

```bash
nix build .#github-mcp
```

</details>

<details>
<summary><strong>Git Tools</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `agnix` | Linter, LSP, and MCP for AI config files |
| `git-absorb` | Automatic fixup commit routing |
| `git-branchless` | Anonymous branching, in-memory rebases |
| `git-revise` | In-memory commit rewriting |

```bash
nix build .#git-absorb
```

</details>

<details>
<summary><strong>AI CLIs</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `claude-code` | Claude Code CLI |
| `github-copilot-cli` | GitHub Copilot CLI |
| `kiro-cli` | Kiro CLI |
| `kiro-gateway` | Python proxy API for Kiro |

</details>

<details>
<summary><strong>Content Packages</strong></summary>

<!-- prettier-ignore -->
| Package | Description |
|---------|-------------|
| `coding-standards` | Reusable coding standard fragments (DRY, conventional commits, etc.) |
| `stacked-workflows-content` | Skills, references, and routing-table fragment |

Content packages are derivations with `passthru.fragments` for
composable instruction building. See
[Fragments & Composition](docs/src/concepts/fragments.md).

</details>

## Feature Matrix

<!-- prettier-ignore -->
| Feature | Without Nix | Home-Manager | DevEnv |
|---------|-------------|--------------|--------|
| Stacked workflow skills | Copy skills/ | `stacked-workflows.enable` | `ai.skills.*` |
| MCP server packages | Install manually | `nix build .#<server>` | `nix build .#<server>` |
| MCP server config | Manual JSON | `services.mcp-servers.*` | `claude.code.mcpServers.*` |
| Typed MCP settings | N/A | Per-server typed options | N/A (raw JSON) |
| MCP credentials | Manual env vars | `file` or `helper` | Manual env vars |
| Git tool packages | Install manually | Overlay + `nix build` | Overlay + `nix build` |
| Unified AI config | N/A | `ai.*` fans out to all CLIs | `ai.*` fans out to all CLIs |
| LSP server config | N/A | `ai.lspServers.*` | `ai.lspServers.*` |
| Fragment composition | N/A | `lib.compose` | `lib.compose` |

## Configuration

<details>
<summary><strong>Unified ai.* Module</strong></summary>

Single source of truth for shared config across Claude, Copilot, and
Kiro. Settings fan out at `mkDefault` priority — per-CLI overrides
always win.

```nix
ai = {
  enable = true;
  claude.enable = true;
  copilot.enable = true;

  skills.my-skill = ./skills/my-skill;

  instructions.standards = {
    text = "Use strict mode everywhere";
    paths = ["src/**"];
    description = "Project standards";
  };

  lspServers.nixd = {
    package = pkgs.nixd;
    extensions = ["nix"];
  };

  settings = {
    model = "claude-sonnet-4";
    telemetry = false;
  };
};
```

See [The Unified ai.\* Module](docs/src/concepts/unified-ai-module.md)
for the full fanout behavior and mapping table.

</details>

<details>
<summary><strong>MCP Servers (Home-Manager)</strong></summary>

```nix
services.mcp-servers.servers = {
  github-mcp = {
    enable = true;
    settings.credentials.file = config.sops.secrets.github-token.path;
  };
  nixos-mcp.enable = true;
  context7-mcp.enable = true;
};
```

See [MCP Server Configuration](docs/src/guides/mcp-servers.md) for
per-server settings and credential patterns.

</details>

<details>
<summary><strong>Stacked Workflows</strong></summary>

```nix
stacked-workflows = {
  enable = true;
  gitPreset = "full";     # or "minimal" or "none"
  integrations = {
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;
  };
};
```

See [Stacked Workflows](docs/src/guides/stacked-workflows.md) for git
presets and skill details.

</details>

## Documentation

Full documentation is available in `docs/`:

```bash
# Preview locally (requires mdbook)
mdbook serve docs/

# Or with devenv
devenv up  # starts docs server at localhost:3000
```

- [Getting Started](docs/src/getting-started/choose-your-path.md)
- [Core Concepts](docs/src/concepts/unified-ai-module.md)
- [Guides](docs/src/guides/home-manager.md)
- [API Reference](docs/src/reference/lib-api.md)
- [Troubleshooting](docs/src/troubleshooting.md)

## License

Released under the [Unlicense](LICENSE).
