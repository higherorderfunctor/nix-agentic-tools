# Types

Custom NixOS module types used across nix-agentic-tools modules.

## instructionModule

Defined in `lib/ai-common.nix`. Used by `ai.instructions`.

A submodule type for shared instructions with semantic fields that
get translated per ecosystem by frontmatter generators.

```nix
instructionModule = types.submodule {
  options = {
    text = mkOption {
      type = types.lines;
      description = "Instruction body (markdown).";
    };
    description = mkOption {
      type = types.str;
      default = "";
      description = "Short description (used by Claude and Kiro frontmatter).";
    };
    paths = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "File path globs this instruction applies to. null = always loaded.";
    };
  };
};
```

### Field Mapping

| Field          | Claude                       | Copilot                 | Kiro                                         |
| -------------- | ---------------------------- | ----------------------- | -------------------------------------------- |
| `text`         | Rule body                    | Instruction body        | Steering body                                |
| `description`  | `description:` frontmatter   | --                      | `description:` frontmatter                   |
| `paths` (set)  | `paths:` list in frontmatter | `applyTo:` comma-joined | `fileMatchPattern:` + `inclusion: fileMatch` |
| `paths` (null) | No frontmatter               | `applyTo: "**"`         | `inclusion: always`                          |

## lspServerModule

Defined in `lib/ai-common.nix`. Used by `ai.lspServers`.

A submodule type for typed LSP server definitions with explicit
packages. The submodule uses the attribute name as the default binary
name.

```nix
lspServerModule = types.submodule ({name, ...}: {
  options = {
    package = mkOption {
      type = types.package;
      description = "The LSP server package.";
    };
    binary = mkOption {
      type = types.str;
      default = name;  # defaults to the attr name
      description = "Binary name within the package.";
    };
    args = mkOption {
      type = types.listOf types.str;
      default = ["--stdio"];
      description = "Arguments to pass to the LSP binary.";
    };
    extensions = mkOption {
      type = types.listOf types.str;
      description = "File extensions this server handles (without dots).";
      example = ["nix"];
    };
    initializationOptions = mkOption {
      type = types.attrs;
      default = {};
      description = "LSP initialization options passed during handshake.";
    };
  };
});
```

### Ecosystem Output

| Field                   | Claude                   | Copilot                                | Kiro                                   |
| ----------------------- | ------------------------ | -------------------------------------- | -------------------------------------- |
| `package` + `binary`    | `ENABLE_LSP_TOOL=1` only | `command` (full store path)            | `command` (full store path)            |
| `args`                  | --                       | `args`                                 | `args`                                 |
| `extensions`            | --                       | `fileExtensions` map (`.ext` -> name)  | --                                     |
| `initializationOptions` | --                       | `initializationOptions` (if non-empty) | `initializationOptions` (if non-empty) |

## Credential attrTag

Defined in `lib/mcp.nix` via `mkCredentialsOption`. Used by MCP
server settings.

A discriminated union (`types.attrTag`) wrapped in `types.nullOr`.
Exactly one variant may be set per credential.

```nix
types.nullOr (types.attrTag {
  file = mkOption {
    type = types.str;
    description = "Path to a file containing the raw secret value.";
  };
  helper = mkOption {
    type = types.str;
    description = "Path to an executable that outputs the secret on stdout.";
  };
})
```

### Usage

```nix
# File-based
settings.credentials.file = "/run/secrets/token";

# Helper-based — `helper` must be a path to an executable, not a
# command string with arguments. Wrap multi-arg invocations in a
# writeShellApplication:
let
  token-helper = pkgs.writeShellApplication {
    name = "token-helper";
    runtimeInputs = [pkgs.pass];
    text = ''
      #!/usr/bin/env bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      exec ${pkgs.pass}/bin/pass show token
    '';
  };
in
  settings.credentials.helper = "${token-helper}/bin/token-helper";

# Disabled (default)
settings.credentials = null;
```

The type system prevents setting both `file` and `helper` on the same
credential -- `attrTag` allows exactly one variant.

## Fragment

Not a NixOS module type -- a plain attrset convention used by
`lib/fragments.nix`.

```nix
{
  text :: string        # instruction content
  description :: nullOr string  # human label
  paths :: nullOr (listOf string)  # file glob scoping
  priority :: int       # sort order (higher = earlier)
}
```

Created by `mkFragment`, consumed by `compose` and
`render`.

## McpEntry

Not a NixOS module type -- the JSON-compatible attrset produced by
MCP entry builders.

```nix
# Stdio entry
{
  type = "stdio";
  command = "/nix/store/.../binary";
  args = ["--stdio"];
  env = { KEY = "value"; };
}

# HTTP entry
{
  type = "http";
  url = "http://127.0.0.1:19751";
}
```

Produced by `mkStdioEntry`, `mkPackageEntry`, and `mkHttpEntry`.
