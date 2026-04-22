# lib API

Public functions exported by `inputs.nix-agentic-tools.lib.ai`, organized
by source module. Every flake-level helper lives under `lib.ai.*` —
there are no top-level `lib.<helper>` exports.

## lib/fragments.nix

Fragment composition library. Pure functions, no file I/O.

### mkFragment

```nix
mkFragment :: { text, description?, paths?, priority? } -> Fragment
```

Create a typed fragment. All optional fields default to `null`/`0`.

| Parameter     | Type                   | Default | Description                    |
| ------------- | ---------------------- | ------- | ------------------------------ |
| `text`        | string                 | --      | Instruction content (required) |
| `description` | nullOr string          | `null`  | Human label                    |
| `paths`       | nullOr (listOf string) | `null`  | File glob scoping              |
| `priority`    | int                    | `0`     | Sort order (higher = earlier)  |

### compose

```nix
compose :: { fragments, description?, paths?, priority? } -> Fragment
```

Compose multiple fragments into one. Sorts by priority descending,
then walks the sorted list and skips any fragment whose SHA-256
text hash has already been seen, then concatenates with newlines.

| Parameter     | Type                   | Default | Description                     |
| ------------- | ---------------------- | ------- | ------------------------------- |
| `fragments`   | listOf Fragment        | --      | Fragments to compose (required) |
| `description` | nullOr string          | `null`  | Label for the result            |
| `paths`       | nullOr (listOf string) | `null`  | Scoping for result              |
| `priority`    | int                    | `0`     | Priority of result              |

### render

```nix
render :: { composed, transform } -> string
```

Apply a transform function to a composed fragment to produce the final
string for a target ecosystem.

| Parameter   | Type               | Description                            |
| ----------- | ------------------ | -------------------------------------- |
| `composed`  | Fragment           | Composed fragment to render            |
| `transform` | Fragment -> string | Transform function from `transforms.*` |

Transforms are provided by `pkgs.fragments-ai.passthru.transforms`:

```nix
let
  t = pkgs.fragments-ai.passthru.transforms;
in {
  claude  = t.claude  { package = "name"; };  # curried factory
  copilot = t.copilot;                         # plain function
  kiro    = t.kiro    { name = "rule-name"; }; # curried factory
  agents  = t.agentsmd;                        # plain function (identity)
}
```

### mkFrontmatter

```nix
mkFrontmatter :: attrset -> string
```

Build a YAML frontmatter block (`---\nkey: value\n---\n`) from an
attrset. Used internally by ecosystem generators.

## lib/mcp.nix

MCP server entry builders. Exported under `lib.ai.<name>`.

### loadServer

```nix
loadServer :: name -> serverDef
```

Load a server module definition by name. Internal helper consumed
by `mkStdioEntry` for settings validation.

### mkPackageEntry

```nix
mkPackageEntry :: package -> McpEntry
```

Derive an MCP stdio entry from package passthru. Uses
`passthru.mcpBinary` and `passthru.mcpArgs` when present, falls back
to `meta.mainProgram`.

### mkStdioEntry

```nix
mkStdioEntry :: pkgs -> { package, name?, settings?, env?, args? } -> McpEntry
```

Full-featured stdio entry with typed settings, credential wrapping,
and environment injection. Loads the server module by name for
validation.

| Parameter  | Type          | Default                    | Description                 |
| ---------- | ------------- | -------------------------- | --------------------------- |
| `package`  | package       | --                         | Server package (required)   |
| `name`     | string        | `package.passthru.mcpName` | Server module name          |
| `settings` | attrset       | `{}`                       | Server-specific settings    |
| `env`      | attrset       | `{}`                       | Extra environment variables |
| `args`     | listOf string | `[]`                       | Extra CLI arguments         |

### mkHttpEntry

```nix
mkHttpEntry :: { name, host?, port?, settings? } -> McpEntry
```

HTTP mode entry. For external servers, returns
`{ type = "http"; url = ...; }`. For local servers, builds URL from
host/port.

### mkStdioConfig

```nix
mkStdioConfig :: pkgs -> attrsOf serverConfig -> { mcpServers :: attrsOf McpEntry }
```

Convenience wrapper: build multiple stdio entries at once. Server
packages are looked up from `pkgs.ai.*` (exposed by the
nix-agentic-tools overlay).

### mkMcpConfig

```nix
mkMcpConfig :: attrsOf McpEntry -> { mcpServers :: attrsOf McpEntry }
```

Wrap a pre-built map of MCP entries in the canonical
`{ mcpServers = ...; }` shape consumed by every CLI's MCP config.

### mapTools

```nix
mapTools :: (server -> tool -> result) -> attrsOf (listOf string) -> listOf result
```

Flatten an attrset-of-tool-lists into a single list, applying a
function to each `(server, tool)` pair.

## lib/devshell.nix

### mkAgenticShell

```nix
mkAgenticShell :: pkgs -> userConfig -> derivation
```

Standalone devshell (no home-manager or devenv required). Evaluates
modules and produces a `mkShell` derivation.

## externalServers

Static registry of remote MCP server URLs that don't ship with their
own package. Currently keyed by provider:

```nix
inputs.nix-agentic-tools.lib.ai.externalServers.aws-mcp
# => { type = "http"; url = "https://knowledge-mcp.global.api.aws"; }
```

## presets

```nix
inputs.nix-agentic-tools.lib.ai.presets.nix-agentic-tools-dev
```

Composed `Fragment` containing all coding-standards content
(`pkgs.coding-standards.passthru.fragments`) plus stacked-workflows
content (`pkgs.stacked-workflows-content.passthru.fragments`). Used
as a one-line "give me everything" instruction set for downstream
projects.

---

Functions defined in `lib/mcp.nix`, `lib/ai-common.nix`, and
`lib/hm-helpers.nix` that are NOT yet exported through the flake
`lib.ai` output (e.g., `mkSecretsWrapper`, `mkCredentialsOption`,
`mkLspConfig`, `mkContentOption`, `mkSkillEntries`) become public
as later chunks land their consumers and promote them to the
flake export surface.
