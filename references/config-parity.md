# Config Parity Reference

Architectural principle for the agentic-tools monorepo. Used by
repo-review's consistency-auditor to detect feature gaps across
configuration methods.

## Three Configuration Methods

| Method | Location | Consumer | Delivery |
|--------|----------|----------|----------|
| **lib/** | `lib/mcp.nix`, `lib/hm-helpers.nix` | Direct callers | Manual function calls |
| **HM modules** | `modules/` | NixOS/home-manager users | `home-manager switch` |
| **devenv modules** | `modules/devenv/` | Project contributors | `devenv shell` |

## Parity Matrix

Each row is a configuration surface. All three methods should support
it. Gaps are bugs.

| Surface | lib | HM | devenv |
|---------|-----|-----|--------|
| Skills | N/A (consumer copies) | `ai.skills`, per-CLI `.skills` | `ai.skills`, per-CLI `.skills` |
| Instructions/steering | N/A | `ai.instructions`, per-CLI | `ai.instructions`, per-CLI |
| MCP servers | `mkStdioEntry`, `mkHttpEntry` | `services.mcp-servers`, `enableMcpIntegration` | `claude.code.mcpServers`, per-CLI `.mcpServers` |
| LSP servers | N/A | `programs.copilot-cli.lspServers` | TBD |
| Settings | N/A | per-CLI `.settings` | `claude.code.*`, per-CLI `.settings` |
| Hooks | N/A | N/A (per-CLI runtime) | `claude.code.hooks`, git-hooks |
| Agents | N/A | per-CLI `.agents` | `claude.code.agents` |
| Environment vars | N/A | `ai.environmentVariables`, per-CLI | `claude.code.env` |
| Permissions | N/A | N/A (per-CLI runtime) | `claude.code.permissions` |

## Audit Checklist (for repo-review)

When auditing config parity:

1. For each HM module option, check if an equivalent devenv module
   option exists (and vice versa)
2. For each `ai.*` option, verify it fans out to ALL enabled ecosystems
   in BOTH HM and devenv contexts
3. Check that option names and types are consistent across methods
4. Verify that `mkDefault` is used for ai.* fanout so per-ecosystem
   overrides win in both HM and devenv
5. Check that generated file paths match what each ecosystem actually
   reads (e.g., `.claude/rules/`, `.kiro/steering/`, `.github/instructions/`)
