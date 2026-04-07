# lib API

All public functions exported by `inputs.nix-agentic-tools.lib`. Organized
by source module.

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
deduplicates by SHA-256 hash of text, concatenates with newlines.

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

MCP server entry builders and credential helpers.

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

HTTP mode entry. For external servers, returns `{ type = "http"; url = ...; }`.
For local servers, builds URL from host/port.

### mkStdioConfig

```nix
mkStdioConfig :: pkgs -> attrsOf serverConfig -> { mcpServers :: attrsOf McpEntry }
```

Convenience wrapper: build multiple stdio entries at once. Server
packages are looked up from `pkgs.nix-mcp-servers`.

### mkSecretsWrapper

```nix
mkSecretsWrapper :: { pkgs, name, package, credentialVars, settings } -> storePath
```

Generate a shell wrapper that reads credentials at runtime and execs
the server binary.

### mkCredentialsOption

```nix
mkCredentialsOption :: envVar -> NixOS option
```

Create a `nullOr (attrTag { file; helper; })` option for a credential
mapped to the given environment variable.

### evalSettings

```nix
evalSettings :: name -> settings -> evaluatedSettings
```

Evaluate settings through the NixOS module system using the server's
`settingsOptions`.

### hasCredentials

```nix
hasCredentials :: credentialVars -> settings -> bool
```

Check if any credentials are configured in the settings.

### mkCredentialsSnippet

```nix
mkCredentialsSnippet :: credentialVars -> settings -> string
```

Generate shell commands to read and export credentials.

## lib/ai-common.nix

Shared content generation for AI CLI modules.

### instructionModule

NixOS module type for shared instructions with `text`, `description`,
and `paths` fields. Used by `ai.instructions`.

### lspServerModule

NixOS module type for LSP server definitions with `package`, `binary`,
`args`, `extensions`, and `initializationOptions`. Used by
`ai.lspServers`.

### mkLspConfig

```nix
mkLspConfig :: name -> server -> attrset
```

Transform a typed LSP server to JSON format (`command`, `args`,
optional `initializationOptions`).

### mkCopilotLspConfig

```nix
mkCopilotLspConfig :: name -> server -> attrset
```

Same as `mkLspConfig` but adds `fileExtensions` mapping for Copilot.

### transformMcpServer

```nix
transformMcpServer :: server -> attrset
```

Transform a typed MCP server submodule value to ecosystem JSON.

### filterNulls

```nix
filterNulls :: attrset -> attrset
```

Recursively remove null values and empty sub-attrsets.

## lib/hm-helpers.nix

Shared helpers for AI CLI home-manager modules.

### mkContentOption / mkDirOption

Option builders for instruction/skill/steering content.

### mkSourceEntry / mkMarkdownEntries / mkSkillEntries

File entry builders that handle both path and string content.

### mkMcpServer

Transform an MCP server config for ecosystem JSON output.

### mkExclusiveAssertion

Generate an assertion that `foo` and `fooDir` are not both set.

### mkSettingsActivationScript

Generate a shell snippet that merges Nix-declared settings into an
existing mutable JSON config file using `jq`.

## lib/devshell.nix

### mkAgenticShell

```nix
mkAgenticShell :: pkgs -> userConfig -> derivation
```

Standalone devshell (no home-manager or devenv required). Evaluates
modules and produces a `mkShell` derivation.
