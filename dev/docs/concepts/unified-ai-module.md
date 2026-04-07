# The Unified ai.\* Module

The `ai.*` module is a single source of truth for shared configuration
across Claude Code, GitHub Copilot CLI, and Kiro CLI. Set it once;
the module fans out to each enabled CLI with ecosystem-specific
translation.

Both home-manager and devenv expose the same `ai.*` interface.

## Enabling CLIs

```nix
ai = {
  claude.enable = true;   # fan out to Claude Code
  copilot.enable = true;  # fan out to Copilot CLI
  kiro.enable = true;     # fan out to Kiro CLI
};
```

Each `ai.<cli>.enable` is the sole gate for that ecosystem. There is
no master `ai.enable` switch — setting any sub-enable activates the
corresponding fanout. Each per-CLI enable also implicitly flips the
upstream module's enable option (`programs.claude-code.enable`,
`programs.copilot-cli.enable`, `programs.kiro-cli.enable`) via
`mkDefault`, so consumers don't need to set enable twice.

Each submodule also exposes a `package` option for overriding the
default package:

```nix
ai.claude = {
  enable = true;
  package = pkgs.claude-code;  # override with custom build
};
```

### Module Dependencies

- **Claude Code** uses `home.file` directly (HM) or `files.*`
  (devenv). No upstream module dependency -- the `ai` module writes
  rules and skills without importing `programs.claude-code`.
- **Copilot CLI** requires `programs.copilot-cli` to be imported.
  The assertion `ai.copilot.enable -> programs.copilot-cli exists`
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

{{#include ../generated/snippets/ai-mapping-table.md}}

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

The module applies per-ecosystem transforms via
`pkgs.fragments-ai.passthru.transforms`:

- **Claude** (`transforms.claude`): `---\ndescription: ...\npaths:\n  - "*.sh"\n---`
- **Copilot** (`transforms.copilot`): `---\napplyTo: "*.sh"\n---`
- **Kiro** (`transforms.kiro`): `---\nname: coding-standards\ninclusion: fileMatch\nfileMatchPattern: "*.sh"\n---`

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

The module includes safety assertions (always evaluated, not gated
on any enable):

- At least one CLI must be enabled when shared config exists
- `copilot.enable` requires `programs.copilot-cli` to be available
- `kiro.enable` requires `programs.kiro-cli` to be available
- Claude has no upstream-module assertion — it uses `home.file` directly

When `ai.claude.buddy` is set (see Buddy Customization guide), two
additional assertions apply:

- `buddy.peak != buddy.dump` (or both null)
- `buddy.rarity == "common" -> buddy.hat == "none"`
