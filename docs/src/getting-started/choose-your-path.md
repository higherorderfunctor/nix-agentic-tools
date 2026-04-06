# Choose Your Path

nix-agentic-tools supports three configuration methods. Pick the one that
fits your workflow.

## Decision Tree

| Question                        | Answer | Path                          |
| ------------------------------- | ------ | ----------------------------- |
| Want system-wide AI CLI config? | Yes    | [Home-Manager](#home-manager) |
| Want per-project config only?   | Yes    | [DevEnv](#devenv)             |
| Just want the skills, no Nix?   | Yes    | [Copy skills](#no-nix)        |
| Building custom tooling?        | Yes    | [lib functions](#manual-lib)  |

## Home-Manager

**Best for:** System-level configuration that persists across all projects.

You get: unified `ai.*` module, typed MCP server management with
systemd services, stacked workflow git presets, per-CLI modules
(copilot-cli, kiro-cli).

```nix
imports = [inputs.nix-agentic-tools.homeManagerModules.default];

ai = {
  enable = true;
  claude.enable = true;
};

stacked-workflows.enable = true;
```

**Next:** [Home-Manager Setup](./home-manager.md)

## DevEnv

**Best for:** Per-project configuration via devenv shells.

You get: same `ai.*` unified module, per-ecosystem config
(`copilot.*`, `kiro.*`, `claude.code.*`), fragment-generated
instruction files, treefmt + git-hooks integration.

```nix
# devenv.yaml
inputs:
  nix-agentic-tools:
    url: github:higherorderfunctor/nix-agentic-tools
    inputs:
      nixpkgs:
        follows: nixpkgs

# devenv.nix
imports = [inputs.nix-agentic-tools.devenvModules.default];

ai = {
  enable = true;
  claude.enable = true;
};
```

**Next:** [DevEnv Setup](./devenv.md)

## Manual lib

**Best for:** Custom tooling, non-standard deployments, or wiring
config without the module system.

You get: `mkStdioEntry`, `mkPackageEntry`, `compose`, `mkFragment`,
frontmatter generators — pure functions for building MCP configs
and instruction files.

```nix
let
  at = inputs.nix-agentic-tools;
  entry = at.lib.mkPackageEntry pkgs.nix-mcp-servers.github-mcp;
in
  # entry = { type = "stdio"; command = "/nix/store/.../github-mcp-server"; args = [...]; }
```

**Next:** [Manual lib Usage](./manual-lib.md)

## No Nix

Skills work without Nix. Copy them into your project:

```bash
# Claude Code
cp -r packages/stacked-workflows/skills/stack-* .claude/skills/

# Kiro
cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/

# GitHub Copilot
cp -r packages/stacked-workflows/skills/stack-* .github/skills/
```

Prerequisites: [git-branchless](https://github.com/arxanas/git-branchless),
[git-absorb](https://github.com/tummychow/git-absorb),
[git-revise](https://github.com/mystor/git-revise).
