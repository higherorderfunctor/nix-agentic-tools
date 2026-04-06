# Credentials & Secrets

MCP servers that access external services need API tokens or access
keys. nix-agentic-tools provides a typed credential system that keeps
secrets out of the Nix store and supports multiple secret management
backends.

## Credential Types

Each server's credential option is a discriminated union -- you set
exactly one of `file` or `helper`:

### File-Based

Point to a file containing the raw secret value. The file is read at
runtime by the wrapper script. Works with any tool that decrypts
secrets to files (sops-nix, agenix, etc.).

```nix
services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = "/run/secrets/github-token";
};
```

### Helper-Based

Point to an executable that outputs the secret on stdout. The helper is
executed at service start.

```nix
services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.helper = "${pkgs.pass}/bin/pass show github/mcp-token";
};
```

## How mkSecretsWrapper Works

When credentials are configured, `mkStdioEntry` detects them and wraps
the server binary with a shell script. The wrapper:

1. Sets strict mode (`set -euETo pipefail`)
2. Reads each credential (via `cat` for files, execution for helpers)
3. Exports the value as the expected environment variable
4. `exec`s the original binary with all original arguments

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
GITHUB_PERSONAL_ACCESS_TOKEN="$(cat "/run/secrets/github-token")"
export GITHUB_PERSONAL_ACCESS_TOKEN
exec "/nix/store/.../github-mcp-server" "$@"
```

The wrapper is a Nix store derivation, but the secret itself is never
in the store -- it's read at runtime from the file or helper output.

## Servers Requiring Credentials

| Server           | Environment Variable           | Required                   |
| ---------------- | ------------------------------ | -------------------------- |
| `github-mcp`     | `GITHUB_PERSONAL_ACCESS_TOKEN` | Yes                        |
| `kagi-mcp`       | `KAGI_API_KEY`                 | Yes                        |
| `context7-mcp`   | `CONTEXT7_API_KEY`             | No (optional)              |
| `openmemory-mcp` | `OM_API_KEY`                   | No (optional)              |
| `openmemory-mcp` | `OPENAI_API_KEY`               | No (for OpenAI embeddings) |

All other servers (effect-mcp, fetch-mcp, git-mcp, git-intel-mcp,
nixos-mcp, sequential-thinking-mcp, serena-mcp, sympy-mcp) need no
credentials.

## sops-nix Integration

[sops-nix](https://github.com/Mic92/sops-nix) decrypts secrets to
files at activation time. Point the `file` credential to the decrypted
path:

```nix
sops.secrets.github-mcp-token = {
  sopsFile = ./secrets.yaml;
  path = "/run/secrets/github-mcp-token";
};

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = config.sops.secrets.github-mcp-token.path;
};
```

## agenix Integration

[agenix](https://github.com/ryantm/agenix) follows the same pattern --
secrets decrypt to `/run/agenix/`:

```nix
age.secrets.github-mcp-token.file = ./secrets/github-mcp-token.age;

services.mcp-servers.servers.github-mcp = {
  enable = true;
  settings.credentials.file = config.age.secrets.github-mcp-token.path;
};
```

## pass Integration

Use the `helper` credential type with
[pass](https://www.passwordstore.org/):

```nix
services.mcp-servers.servers.kagi-mcp = {
  enable = true;
  settings.credentials.helper = "${pkgs.pass}/bin/pass show api/kagi";
};
```

## DevEnv Credentials

In devenv, MCP servers are configured inline per-CLI. Use
`mkStdioEntry` from lib to get credential wrapping:

```nix
claude.code.mcpServers.github-mcp =
  inputs.nix-agentic-tools.lib.mcp.mkStdioEntry pkgs {
    package = pkgs.nix-mcp-servers.github-mcp;
    settings.credentials.file = "/run/secrets/github-token";
  };
```

## Type System Enforcement

The credential option uses `types.attrTag` -- a discriminated union
that enforces mutual exclusion at the type level. You cannot set both
`file` and `helper` on the same credential. The Nix module system
catches this at evaluation time, not runtime.

```nix
# This is a type error -- attrTag allows exactly one variant:
settings.credentials = {
  file = "/run/secrets/token";
  helper = "pass show token";  # error: conflicting tag
};
```
