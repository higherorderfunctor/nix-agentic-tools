# Home-Manager Setup

System-level AI CLI configuration via home-manager. This sets up Claude
Code, Copilot CLI, and Kiro CLI with shared config, stacked workflow
skills, and MCP servers.

## 1. Add the flake input

```nix
# flake.nix
{
  inputs.nix-agentic-tools = {
    url = "github:higherorderfunctor/nix-agentic-tools";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

## 2. Apply the overlay

The overlay provides all packages: AI CLIs, git tools, MCP servers, and
content packages.

```nix
# In your nixpkgs configuration:
nixpkgs.overlays = [
  inputs.nix-agentic-tools.overlays.default
];
```

This adds to your `pkgs`:

| Overlay             | Packages                                              |
| ------------------- | ----------------------------------------------------- |
| `ai-clis`           | `github-copilot-cli`, `kiro-cli`, `kiro-gateway`      |
| `coding-standards`  | `coding-standards` (fragment content)                 |
| `git-tools`         | `agnix`, `git-absorb`, `git-branchless`, `git-revise` |
| `mcp-servers`       | `nix-mcp-servers.*` (14 servers)                      |
| `stacked-workflows` | `stacked-workflows-content` (skills, references)      |

You can also apply individual overlays:
`overlays.ai-clis`, `overlays.git-tools`, `overlays.mcp-servers`, etc.

## 3. Import the modules

```nix
# In your home-manager configuration:
imports = [
  inputs.nix-agentic-tools.homeManagerModules.default
];
```

This imports all modules: `ai`, `copilot-cli`, `kiro-cli`, `mcp-servers`,
`stacked-workflows`. Import individual modules if you prefer:

```nix
imports = [
  inputs.nix-agentic-tools.homeManagerModules.ai
  inputs.nix-agentic-tools.homeManagerModules.stacked-workflows
];
```

## 4. Minimal configuration

```nix
# Enable the unified AI module for Claude Code
ai = {
  enable = true;
  claude.enable = true;
};

# Enable stacked workflows (git presets + skills)
stacked-workflows = {
  enable = true;
  gitPreset = "full";     # or "minimal" or "none"
  integrations.claude.enable = true;
};
```

## 5. Full configuration example

```nix
{pkgs, ...}: {
  # ── Unified AI config ──────────────────────────────────────────────
  ai = {
    enable = true;
    claude.enable = true;
    copilot.enable = true;
    kiro.enable = true;

    # Shared skills (fan out to all enabled CLIs)
    skills = {
      my-review = ./skills/review;
    };

    # Shared instructions with path scoping
    instructions.coding-standards = {
      text = ''
        ## Standards

        ${pkgs.coding-standards.passthru.presets.all.text}
      '';
      paths = ["src/**"];
      description = "Project coding standards";
    };

    # LSP servers (auto-sets ENABLE_LSP_TOOL=1 for Claude)
    lspServers.nixd = {
      package = pkgs.nixd;
      binary = "nixd";
      extensions = ["nix"];
    };

    # Normalized settings (translated per ecosystem)
    settings = {
      model = "claude-sonnet-4";
      telemetry = false;
    };

    environmentVariables = {
      SOME_VAR = "value";
    };
  };

  # ── Stacked workflows ──────────────────────────────────────────────
  stacked-workflows = {
    enable = true;
    gitPreset = "full";
    integrations = {
      claude.enable = true;
      copilot.enable = true;
      kiro.enable = true;
    };
  };

  # ── MCP servers ────────────────────────────────────────────────────
  services.mcp-servers.servers = {
    github-mcp = {
      enable = true;
      settings.credentials.file = "/run/secrets/github-token";
    };
    nixos-mcp.enable = true;
    context7-mcp.enable = true;
  };

  # ── Per-CLI overrides (optional) ───────────────────────────────────
  # These override ai.* settings at normal priority (ai.* uses mkDefault)
  programs.copilot-cli = {
    settings.model = "gpt-4o";  # override ai.settings.model for Copilot
  };
}
```

## 6. Verify

```bash
home-manager switch

# Check generated files
ls ~/.claude/rules/       # Claude instructions
ls ~/.claude/skills/      # Wired skills
ls ~/.copilot/            # Copilot config
ls ~/.kiro/               # Kiro config
cat ~/.claude/settings.json  # Claude settings (merged)
```

## What gets generated

| ai.\* option           | Claude                      | Copilot                             | Kiro                         |
| ---------------------- | --------------------------- | ----------------------------------- | ---------------------------- |
| `skills`               | `~/.claude/skills/{name}`   | `~/.copilot/skills/{name}`          | `~/.kiro/skills/{name}`      |
| `instructions`         | `~/.claude/rules/{name}.md` | `~/.copilot/instructions/{name}.md` | `~/.kiro/steering/{name}.md` |
| `lspServers`           | `ENABLE_LSP_TOOL=1`         | `lsp-config.json`                   | `lsp.json`                   |
| `settings.model`       | `settings.model`            | `settings.model`                    | `chat.defaultModel`          |
| `settings.telemetry`   | —                           | —                                   | `telemetry.enabled`          |
| `environmentVariables` | —                           | wrapped in binary                   | wrapped in binary            |

## Next steps

- [The Unified ai.\* Module](../concepts/unified-ai-module.md) — how
  fanout works, mkDefault priority, per-CLI overrides
- [Credentials & Secrets](../concepts/credentials.md) — sops-nix and
  agenix integration patterns
- [MCP Server Configuration](../guides/mcp-servers.md) — per-server
  settings and tools reference
