## Config Parity

Three configuration methods exist with the same rough interface:

- **lib/** — manual functions for consumers wiring config directly
- **HM modules** (`modules/`) — declarative home-manager (system-level)
- **devenv modules** (`modules/devenv/`) — project-local dev shell

If a feature can be configured in HM, it must also be configurable in
devenv and vice versa. Gaps between methods are bugs.

Surfaces to keep aligned across all three methods: skills,
instructions/steering, MCP servers, LSP servers, settings, hooks,
agents, environment variables, permissions.

The `ai.*` module (both HM and devenv) provides a unified interface
that fans out to all enabled ecosystems (Claude, Copilot, Kiro) with
ecosystem-specific translation.
