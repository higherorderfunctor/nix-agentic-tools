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

## License

Released under the [Unlicense](LICENSE).
