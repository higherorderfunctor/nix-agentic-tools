# agentic-tools

Stacked commit workflows, MCP servers, and declarative configuration for
AI coding CLIs (Claude Code, Copilot, Kiro). Works without Nix; Nix
unlocks overlays, home-manager modules, and devshell integration.

## Quick Start (Nix)

Add as a flake input:

```nix
{
  inputs.agentic-tools = {
    url = "github:higherorderfunctor/agentic-tools";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import home-manager modules:

```nix
imports = [inputs.agentic-tools.homeManagerModules.default];
```

## Quick Start (Non-Nix)

### Prerequisites

Stacked workflow skills require the following tools installed:

- [git-branchless](https://github.com/arxanas/git-branchless) -- anonymous branching, in-memory rebases, smartlog
- [git-absorb](https://github.com/tummychow/git-absorb) -- automatic fixup commit routing
- [git-revise](https://github.com/mystor/git-revise) -- in-memory commit rewriting

### Installation

Copy the skills you need into your project:

```bash
# Claude Code
cp -r skills/stack-* .claude/skills/

# Kiro
cp -r skills/stack-* .kiro/skills/

# GitHub Copilot
cp -r skills/stack-* .github/skills/
```

Each skill is self-contained with a `SKILL.md` and bundled reference docs.

## Skills

Stacked commit workflow skills using git-branchless, git-absorb, and git-revise.

<!-- dprint-ignore -->

| Skill            | Description                                                                           |
| ---------------- | ------------------------------------------------------------------------------------- |
| `/stack-fix`     | Absorb fixes into correct stack commits                                               |
| `/stack-split`   | Split a large commit into reviewable atomic commits                                   |
| `/stack-plan`    | Plan and build a commit stack from description, uncommitted work, or existing commits |
| `/stack-submit`  | Sync, validate, push stack, and create stacked PRs                                    |
| `/stack-summary` | Analyze stack quality, flag violations, produce planner-ready summary                 |
| `/stack-test`    | Run tests or formatters across every commit in a stack                                |

## Home-Manager Modules

Declarative configuration for AI coding CLIs. All modules are no-ops when
`enable = false`.

### copilot-cli

Declarative Copilot CLI configuration: settings, MCP servers, agents,
skills, and instructions. Mirrors upstream `programs.claude-code` patterns.

```nix
programs.copilot-cli.enable = true;
```

### kiro-cli

Declarative Kiro CLI configuration: settings, MCP servers, steering files,
skills, agents, and hooks.

```nix
programs.kiro-cli.enable = true;
```

### stacked-workflows

Git config presets and AI tool integrations for stacked commit workflows.

```nix
stacked-workflows = {
  enable = true;
  gitPreset = "full";
};
```

### ai

Unified configuration across Claude Code, Copilot CLI, and Kiro CLI.
Shared skills, instructions, and environment variables fan out to each
enabled CLI at `mkDefault` priority.

```nix
ai = {
  enable = true;
  enableClaude = true;
  enableCopilot = true;
  enableKiro = true;
  skills = { stack-fix = ./skills/stack-fix; };
  instructions.coding-standards = {
    text = "Always use strict mode...";
    paths = [ "src/**" ];
    description = "Project coding standards";
  };
};
```

### mcp-servers

Declarative MCP server management with typed settings and credentials.

```nix
services.mcp-servers.servers.github-mcp.enable = true;
```

## Feature Matrix

<!-- dprint-ignore -->

| Feature                 | Without Nix      | With Nix                 |
| ----------------------- | ---------------- | ------------------------ |
| Stacked workflow skills | Copy `skills/`   | Injected via HM module   |
| MCP server packages     | Install manually | `nix build .#<server>`   |
| MCP server config       | Manual JSON      | Declarative HM module    |
| Git tool overlays       | Install manually | `nix build .#git-absorb` |
| Home-manager modules    | N/A              | Full declarative config  |
| DevShell integration    | N/A              | `mkAgenticShell`         |

## DevShell Usage

Per-project AI tool configuration without home-manager. The repo includes
a `.envrc` for [direnv](https://direnv.net/) integration (requires
[devenv](https://devenv.sh/getting-started/)).

```nix
devShells.default = inputs.agentic-tools.lib.mkAgenticShell pkgs {
  mcpServers.github-mcp = {
    enable = true;
    command = "github-mcp-server";
    args = ["--stdio"];
  };
  skills.stacked-workflows.enable = true;
};
```

## MCP Servers Reference

13 MCP servers packaged as Nix derivations (aws-mcp is external/HTTP-only).

```bash
nix build .#github-mcp
```

<!-- dprint-ignore -->

| Server                    | Description                                 |
| ------------------------- | ------------------------------------------- |
| `aws-mcp`                 | AWS documentation and recommendations       |
| `context7-mcp`            | Library documentation lookup                |
| `effect-mcp`              | Effect-TS documentation                     |
| `fetch-mcp`               | HTTP fetch with HTML-to-markdown conversion |
| `git-intel-mcp`           | Git repository analytics and insights       |
| `git-mcp`                 | Git repository operations                   |
| `github-mcp`              | GitHub platform integration                 |
| `kagi-mcp`                | Kagi search and summarization               |
| `mcp-proxy`               | MCP stdio-to-HTTP bridge proxy              |
| `nixos-mcp`               | NixOS and Nix documentation                 |
| `openmemory-mcp`          | Persistent memory with vector search        |
| `sequential-thinking-mcp` | Step-by-step reasoning                      |
| `sympy-mcp`               | Symbolic mathematics via SymPy              |

## Git Tool Overlays

Stacked workflow prerequisites packaged from latest release sources:

- **git-absorb** — automatic fixup commit routing
- **git-branchless** — anonymous branching, in-memory rebases, smartlog
- **git-revise** — in-memory commit rewriting

```bash
nix build .#git-absorb
nix build .#git-branchless
nix build .#git-revise
```

## License

Released under the [Unlicense](LICENSE).
