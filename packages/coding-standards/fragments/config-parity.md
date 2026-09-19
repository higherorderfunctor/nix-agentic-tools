## Config Parity

Three configuration methods exist with the same rough interface:

- **lib/** — manual functions for consumers wiring config directly
- **HM modules** (`modules/`) — declarative home-manager (system-level)
- **devenv modules** (`modules/devenv/`) — project-local dev shell

If a feature can be configured in HM, it must also be configurable in devenv and
vice versa. Gaps between methods are bugs unless a capability has an explicit
backend exclusion.

`ai.strictdoc` is explicitly devenv-only: it configures a project's document
toolchain, so Home Manager is out of scope. Native owner discovery contributes
its backend to `devenvModules.nix-agentic-tools`;
`checks/modules/options-doc.nix` requires its public option reference and
excludes only this namespace from the otherwise exact `ai.*` option-name/type
comparison. This export preserves the existing runtime contract: scribe and
board launchers require scripts in the consuming project. Grammar rendering
happens at evaluation; `generate:sgra` writes those rendered bytes in a separate
task invocation.

Surfaces to keep aligned across all three methods: skills,
instructions/steering, MCP servers, LSP servers, settings, hooks, agents,
environment variables, permissions.

The `ai.*` module (both HM and devenv) provides a unified interface that fans
out shared surfaces to enabled ecosystems (Claude, Codex, Copilot, Kimchi, Kiro)
with ecosystem-specific translation. A surface without a lossless native mapping
is an explicit exclusion, not a silent no-op.
