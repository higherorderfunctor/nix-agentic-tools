# Configuration Parity

nix-agentic-tools provides three configuration methods. All three must
support the same features. Gaps between methods are bugs.

## The Three Methods

| Method                                 | Scope                            | Best for                            |
| -------------------------------------- | -------------------------------- | ----------------------------------- |
| **Home-manager modules** (`modules/`)  | System-wide (`~/.claude/`, etc.) | Persistent, user-level config       |
| **DevEnv modules** (`modules/devenv/`) | Project-local (`.claude/`, etc.) | Per-project config                  |
| **lib functions** (`lib/`)             | Manual wiring                    | Custom tooling, non-standard setups |

## Parity Matrix

Every configurable surface must be available in all three methods:

| Surface                 | HM Module                 | DevEnv Module                   | lib                                           |
| ----------------------- | ------------------------- | ------------------------------- | --------------------------------------------- |
| Skills                  | `ai.skills`               | `ai.skills`                     | Manual file placement                         |
| Instructions / steering | `ai.instructions`         | `ai.instructions`               | `render` + `transforms.{claude,copilot,kiro}` |
| MCP servers             | `services.mcp-servers`    | `claude.code.mcpServers`        | `mkStdioEntry`, `mkStdioConfig`               |
| LSP servers             | `ai.lspServers`           | `ai.lspServers`                 | `mkLspConfig`, `mkCopilotLspConfig`           |
| Settings                | `ai.settings`             | `ai.settings`                   | Per-CLI JSON generation                       |
| Environment variables   | `ai.environmentVariables` | `ai.environmentVariables`       | Manual wiring                                 |
| Credentials             | `settings.credentials.*`  | `mkStdioEntry` with credentials | `mkSecretsWrapper`                            |
| Hooks                   | Per-CLI module            | Per-CLI module                  | Manual                                        |
| Agents                  | Per-CLI module            | Per-CLI module                  | Manual                                        |
| Permissions             | Per-CLI module            | Per-CLI module                  | Manual                                        |

## Why Parity Matters

Users choose a method based on their deployment context, not feature
needs. A user switching from devenv to home-manager (or vice versa)
should not lose capabilities. If they discover a feature only works in
one method, that's a bug.

## Shared Implementation

Both HM and devenv `ai.*` modules import from the same source:

- `lib/ai-common.nix` -- frontmatter generators, LSP transforms,
  instruction/LSP types, settings utilities
- `lib/fragments.nix` -- fragment composition (shared by both and
  by standalone lib consumers)
- `lib/mcp.nix` -- MCP entry builders, credential helpers

This means a new transform in `pkgs.fragments-ai.passthru.transforms`
automatically benefits all three methods.

## How to Report Parity Issues

If you find a feature that works in one method but not another:

1. Check the [parity matrix](#parity-matrix) above to confirm it's
   expected to work
2. Open an issue with:
   - Which method has the feature
   - Which method is missing it
   - A minimal config reproducing the gap
3. Label the issue `parity-bug`

The structural check (`nix flake check`) validates some cross-references
automatically, but not all parity guarantees can be checked statically.
