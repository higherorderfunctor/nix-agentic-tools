## Kiro generated agent file formats

> **Last verified:** 2026-09-30 — KAS/ACP loads and dispatches Markdown agent
> profiles, while `kiro-cli agent list`, validation, and default selection use a
> JSON-only registry.

Kiro has two agent-profile consumers with different file support. The KAS/ACP
loader discovers both `.json` and `.md` profiles and can dispatch either by
name. The Rust CLI's `agent list`, validation, and default-agent commands see
only JSON. Adding `name:` to Markdown does not make it visible to that registry.

`ai.kiro.agentFileType` selects the generated format for typed agents and
defaults to `"json"`, preserving the existing output. A typed
`ai.kiro.agents.<name>.fileType` overrides that default for one agent; `null`
inherits it. Portable semantic `ai.agents` records use the same default and can
set the override through `kiro.fileType`.

Raw string and path entries are already finished files. They retain the existing
JSON destination and bytes regardless of `agentFileType`.

### JSON

JSON profiles are written to `<configDir>/agents/<name>.json`. They work in both
the KAS/ACP dispatcher and the CLI registry. The renderer supplies `name` from
the attribute key when omitted and recursively drops null fields and empty
collections.

### Markdown

Markdown profiles are written to `<configDir>/agents/<name>.md`. The shared
`lib/frontmatter.nix` renderer writes every non-empty typed field except
`prompt` and the delivery-only `fileType` into YAML frontmatter. The prompt is
the Markdown body. Nested values such as `permissions` use JSON's inline syntax,
which is valid YAML and preserves their object and array shapes.

The accepted frontmatter keys come from KAS's
`CustomAgentFileFrontMatterSchema`, documented in
`docs/plans/kiro-v3-research-raw/phase2/f14-frontmatter.md`: `name`,
`description`, `tools`, `excludedTools`, `model`, `effortLevel`,
`includeMcpJson`, `includePowers`, `mcpServers`, `resources`, `permissions`,
`welcomeMessage`, `dispatchKind`, and `hooks`. `permissions` is
`{ rules = [{ capability, match?, exclude?, effect }]; policies?; }`.

Choose Markdown when dispatch through KAS/ACP is the only required path. Choose
JSON when the profile must also appear in or be managed by `kiro-cli agent`
commands.
