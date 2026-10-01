## Kiro native agent formats

> **Last verified:** 2026-09-30 — KAS/ACP loads and dispatches Markdown agent
> profiles, while `kiro-cli agent list`, validation, and default selection use a
> JSON-only registry.

Kiro has two agent-profile consumers with different file support. The KAS/ACP
loader discovers both `.json` and `.md` profiles and can dispatch either by
name. The Rust CLI's `agent list`, validation, and default-agent commands see
only JSON. Adding `name:` to Markdown does not make it visible to that registry.

`ai.kiro.native.agents.<name>.format` selects the generated format for one typed
native record. It accepts `"json"` or `"markdown"` and defaults to `"json"`,
preserving the existing output. Normalized root `ai.agents` records lower into
this typed native layer and therefore keep the JSON default.

Raw string and path forms under `ai.kiro.agents` are already materialized files,
so they have no `format` option. A raw Markdown path keeps its `.md` suffix;
other raw entries keep their existing `.json` destination and bytes.

### JSON

JSON profiles are written to `<configDir>/agents/<name>.json`. They work in both
the KAS/ACP dispatcher and the CLI registry. The renderer supplies `name` from
the attribute key when omitted and recursively drops null fields and empty
collections. The delivery-only `format` field is not written into the profile.

### Markdown

Markdown profiles are written to `<configDir>/agents/<name>.md`. The shared
`lib/frontmatter.nix` renderer receives each non-empty field except `prompt` as
its raw Nix value. The prompt becomes the Markdown body, and `format` is not
written into the profile.

The frontmatter emitter supports scalars and lists of scalars. A Markdown agent
with a nested non-null field fails module evaluation with an assertion naming
the agent and field and explaining that JSON carries it. This includes object
fields such as `mcpServers`, `permissions`, and `hooks`, plus a `resources` list
containing knowledge-base records. There is no JSON-in-YAML fallback.

The accepted frontmatter keys come from KAS's
`CustomAgentFileFrontMatterSchema`, documented in
`docs/plans/kiro-v3-research-raw/phase2/f14-frontmatter.md`: `name`,
`description`, `tools`, `excludedTools`, `model`, `effortLevel`,
`includeMcpJson`, `includePowers`, `mcpServers`, `resources`, `permissions`,
`welcomeMessage`, `dispatchKind`, and `hooks`.

Choose Markdown when dispatch through KAS/ACP is the only required path. Choose
JSON when the profile must also appear in or be managed by `kiro-cli agent`
commands, or when it carries nested configuration.
