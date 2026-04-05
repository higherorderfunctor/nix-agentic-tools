# Config Parity Reference

Architectural principle for the agentic-tools monorepo. Used by
repo-review's consistency-auditor to detect feature gaps across
configuration methods.

## Three Configuration Methods

| Method             | Location                            | Consumer                 | Delivery              |
| ------------------ | ----------------------------------- | ------------------------ | --------------------- |
| **lib/**           | `lib/mcp.nix`, `lib/hm-helpers.nix` | Direct callers           | Manual function calls |
| **HM modules**     | `modules/`                          | NixOS/home-manager users | `home-manager switch` |
| **devenv modules** | `modules/devenv/`                   | Project contributors     | `devenv shell`        |

## Parity Matrix

Each row is a configuration surface. All three methods should support
it. Gaps are bugs unless marked N/A with rationale.

| Surface               | lib                           | HM                                                     | devenv                                                 |
| --------------------- | ----------------------------- | ------------------------------------------------------ | ------------------------------------------------------ |
| Agents                | N/A                           | per-CLI `.agents` (copilot: md, kiro: json)            | per-CLI `.agents` (copilot: md, kiro: json)            |
| Environment vars      | N/A                           | `ai.environmentVariables`, per-CLI `.environmentVars`  | `ai.environmentVariables`, per-CLI, shared `env`       |
| Hooks                 | N/A                           | kiro `.hooks`; Claude upstream; copilot N/A (no hooks) | kiro `.hooks`; Claude upstream; copilot N/A (no hooks) |
| Instructions/steering | N/A                           | `ai.instructions`, per-CLI                             | `ai.instructions`, per-CLI                             |
| LSP servers           | N/A                           | `ai.lspServers`, copilot + kiro `.lspServers`          | `ai.lspServers`, copilot + kiro `.lspServers`          |
| MCP servers           | `mkStdioEntry`, `mkHttpEntry` | per-CLI `.mcpServers` + `.enableMcpIntegration`        | per-CLI `.mcpServers` (typed submodule)                |
| Permissions           | N/A                           | Claude upstream only; copilot/kiro N/A                 | Claude upstream only; copilot/kiro N/A                 |
| Settings              | N/A                           | `ai.settings`, per-CLI `.settings` (typed + freeform)  | `ai.settings`, per-CLI `.settings` (typed + freeform)  |
| Skills                | N/A                           | `ai.skills`, per-CLI `.skills`                         | `ai.skills`, per-CLI `.skills`                         |

### Per-Surface Notes

**Agents** -- Not fanned out from `ai.*` because each ecosystem uses
different agent formats (Copilot: markdown, Kiro: JSON, Claude:
upstream YAML). Configure per-CLI directly.

**Environment vars** -- HM `ai.environmentVariables` fans to Copilot
and Kiro (wrapper scripts). Claude Code's upstream HM module does not
expose an `environmentVariables` option, so HM ai cannot fan to it.
In devenv, `ai.environmentVariables` sets shared `env` (covers all
processes including Claude) plus per-CLI options.

**Hooks** -- Only Kiro has a hooks concept in our modules. Claude
hooks are managed by the upstream `claude.code.hooks` option. Copilot
CLI has no hooks support.

**LSP servers** -- Claude Code does not have an LSP config option, so
`ai.lspServers` fans to Copilot and Kiro only.

**MCP servers** -- HM uses `enableMcpIntegration` to bridge
`programs.mcp.servers` into each CLI. devenv uses typed submodules
per CLI. The `ai.*` module does not have its own `mcpServers` to avoid
double-injection.

**Permissions** -- Only Claude Code has a permissions concept. Managed
by the upstream module in both HM and devenv contexts.

### Settings Type Coverage

Typed options with `freeformType` fallback for unknown keys:

| CLI     | HM typed keys                                                   | devenv typed keys                                               |
| ------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| Claude  | upstream `claude.code.*` (model, hooks, agents, etc.)           | upstream `claude.code.*`                                        |
| Copilot | `model`, `theme`                                                | `model`, `theme`                                                |
| Kiro    | `chat.defaultModel`, `chat.enableThinking`, `telemetry.enabled` | `chat.defaultModel`, `chat.enableThinking`, `telemetry.enabled` |

### Normalized Settings (ai.settings)

The `ai.settings` submodule provides ecosystem-agnostic keys that fan
out per CLI at `mkDefault` priority (both HM and devenv):

| ai.settings key | Claude                                        | Copilot                  | Kiro                              |
| --------------- | --------------------------------------------- | ------------------------ | --------------------------------- |
| `model`         | `programs.claude-code.settings.model` (if HM) | `copilot.settings.model` | `kiro.settings.chat.defaultModel` |
| `telemetry`     | N/A (no upstream option)                      | N/A (no upstream option) | `kiro.settings.telemetry.enabled` |

## Audit Checklist (for repo-review)

When auditing config parity:

1. For each HM module option, check if an equivalent devenv module
   option exists (and vice versa)
2. For each `ai.*` option, verify it fans out to ALL enabled ecosystems
   in BOTH HM and devenv contexts
3. Check that option names and types are consistent across methods
4. Verify that `mkDefault` is used for ai.\* fanout so per-ecosystem
   overrides win in both HM and devenv
5. Check that generated file paths match what each ecosystem actually
   reads (e.g., `.claude/rules/`, `.kiro/steering/`, `.github/instructions/`)
