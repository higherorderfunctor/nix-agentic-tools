# The Unified ai.\* Module

The `ai.*` module is a single source of truth for shared configuration
across Claude Code, GitHub Copilot CLI, and Kiro CLI. Set it once;
the module fans out to each enabled CLI with ecosystem-specific
translation.

Both home-manager and devenv expose the same `ai.*` interface.

## Enabling CLIs

```nix
ai = {
  enable = true;        # master switch
  enableClaude = true;  # fan out to Claude Code
  enableCopilot = true; # fan out to Copilot CLI
  enableKiro = true;    # fan out to Kiro CLI
};
```

Each `enable*` flag controls whether shared config is written to that
CLI's config paths. You can enable any combination.

### Module Dependencies

- **Claude Code** uses `home.file` directly (HM) or `files.*`
  (devenv). No upstream module dependency -- the `ai` module writes
  rules and skills without importing `programs.claude-code`.
- **Copilot CLI** requires `programs.copilot-cli` to be imported.
  The assertion `ai.enableCopilot -> programs.copilot-cli exists`
  catches misconfigurations at eval time.
- **Kiro CLI** requires `programs.kiro-cli` to be imported, with
  the same assertion pattern.

## How Fanout Works

Every `ai.*` value is injected at `mkDefault` priority (1000). This
means per-CLI options set at normal priority (100 from `=`) always win.

```nix
# Shared: all CLIs get claude-sonnet-4
ai.settings.model = "claude-sonnet-4";

# Per-CLI override: Copilot gets gpt-4o instead
programs.copilot-cli.settings.model = "gpt-4o";
```

The priority chain:

1. `ai.settings.model` sets each CLI's model at `mkDefault`
2. `programs.copilot-cli.settings.model = "gpt-4o"` sets at normal priority
3. Normal priority (100) beats `mkDefault` (1000), so Copilot uses `gpt-4o`
4. Claude and Kiro still use `claude-sonnet-4` from the shared config

## Settings Mapping

Normalized settings are translated to ecosystem-specific keys:

| `ai.*` option          | Claude Code         | Copilot CLI       | Kiro CLI                     |
| ---------------------- | ------------------- | ----------------- | ---------------------------- |
| `settings.model`       | `settings.model`    | `settings.model`  | `settings.chat.defaultModel` |
| `settings.telemetry`   | --                  | --                | `settings.telemetry.enabled` |
| `environmentVariables` | --                  | wrapped in binary | wrapped in binary            |
| `lspServers`           | `ENABLE_LSP_TOOL=1` | `lsp-config.json` | `lsp.json`                   |

## Skills

Skills are directory paths. The format is identical across ecosystems --
only the destination changes:

```nix
ai.skills = {
  stack-fix = "${pkgs.stacked-workflows-content.passthru.skillsDir}/stack-fix";
};
```

| Ecosystem | Destination                                                        |
| --------- | ------------------------------------------------------------------ |
| Claude    | `~/.claude/skills/{name}` (HM) or `.claude/skills/{name}` (devenv) |
| Copilot   | `~/.copilot/skills/{name}` or `.github/skills/{name}`              |
| Kiro      | `~/.kiro/skills/{name}` or `.kiro/skills/{name}`                   |

## Instructions

Instructions use a shared semantic format. The body text is shared; each
ecosystem gets its own frontmatter wrapper.

```nix
ai.instructions.coding-standards = {
  text = "Always use strict mode in bash scripts.";
  paths = ["*.sh"];           # null = always loaded
  description = "Bash coding standard";
};
```

The module calls per-ecosystem frontmatter generators:

- **Claude** (`mkClaudeRule`): `---\ndescription: ...\npaths:\n  - "*.sh"\n---`
- **Copilot** (`mkCopilotInstruction`): `---\napplyTo: "*.sh"\n---`
- **Kiro** (`mkKiroSteering`): `---\nname: coding-standards\ninclusion: fileMatch\nfileMatchPattern: "*.sh"\n---`

When `paths` is null, Claude omits the paths frontmatter (always loaded),
Copilot uses `applyTo: "**"`, and Kiro uses `inclusion: always`.

## LSP Servers

LSP servers are typed with explicit packages:

```nix
ai.lspServers.nixd = {
  package = pkgs.nixd;
  binary = "nixd";          # defaults to attr name
  args = ["--stdio"];       # default
  extensions = ["nix"];
};
```

Fanout per ecosystem:

- **Claude**: sets `ENABLE_LSP_TOOL=1` in `programs.claude-code.settings.env`
- **Copilot**: writes JSON with `command`, `args`, and `fileExtensions` mapping
- **Kiro**: writes JSON with `command`, `args`, and optional `initializationOptions`

## Assertions

The module includes safety assertions:

- At least one CLI must be enabled when shared config exists
- `enableCopilot` requires `programs.copilot-cli` to be available
- `enableKiro` requires `programs.kiro-cli` to be available
- Claude has no assertion -- it uses `home.file` directly
