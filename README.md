# agentic-tools

A Nix flake monorepo for AI coding CLI tools.

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
| Skill | Description |
|-------|-------------|
| `/stack-fix` | Absorb fixes into correct stack commits |
| `/stack-split` | Split a large commit into reviewable atomic commits |

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

## DevShell Usage

Per-project AI tool configuration without home-manager.

```nix
devShells.default = inputs.agentic-tools.lib.mkAgenticShell pkgs {
  name = "my-project";
};
```

## License

Released under the [Unlicense](LICENSE).
