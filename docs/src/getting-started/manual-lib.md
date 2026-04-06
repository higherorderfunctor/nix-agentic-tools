# Manual lib Usage

Use lib functions directly when you need fine-grained control, are
building custom tooling, or want to wire config without the module
system. All functions are pure -- no side effects, no file I/O.

## Getting Started

```nix
let
  at = inputs.nix-agentic-tools;
  inherit (at.lib) fragments mcp;
in {
  # ...
}
```

## MCP Entry Builders

### mkPackageEntry

Derive an MCP stdio config entry from a package's passthru metadata.
No server module required -- works with any package that has
`meta.mainProgram` or `passthru.mcpBinary`.

```nix
mcp.mkPackageEntry pkgs.nix-mcp-servers.github-mcp
# => {
#   type = "stdio";
#   command = "/nix/store/.../github-mcp-server";
#   args = [];
# }

# Packages with mcpBinary/mcpArgs in passthru:
mcp.mkPackageEntry pkgs.nix-mcp-servers.serena-mcp
# => {
#   type = "stdio";
#   command = "/nix/store/.../serena";
#   args = ["start-mcp-server"];
# }
```

### mkStdioEntry

Full-featured stdio entry with typed settings, credential wrapping,
and environment injection. Uses the server module for validation.

```nix
mcp.mkStdioEntry pkgs {
  package = pkgs.nix-mcp-servers.github-mcp;
  settings = {
    toolsets = ["repos" "pull_requests"];
    readOnly = true;
    credentials.file = "/run/secrets/github-token";
  };
}
# => {
#   type = "stdio";
#   command = "/nix/store/.../github-mcp-env";  # wrapped with credentials
#   args = ["stdio" "--toolsets" "repos,pull_requests" "--read-only"];
#   env = { PYTHONPATH = ""; PYTHONNOUSERSITE = "true"; };
# }
```

### mkStdioConfig

Convenience wrapper for multiple servers at once:

```nix
mcp.mkStdioConfig pkgs {
  github-mcp = {
    settings.credentials.file = "/run/secrets/github-token";
  };
  context7-mcp = {};
  nixos-mcp = {};
}
# => { mcpServers = { github-mcp = {...}; context7-mcp = {...}; nixos-mcp = {...}; }; }
```

## Fragment Builders

### mkFragment

Create a typed fragment with all fields defaulted:

```nix
fragments.mkFragment {
  text = "Always use strict mode in bash scripts.";
  description = "bash-strict-mode";
  priority = 20;        # higher = earlier in composed output
  paths = ["*.sh"];     # null = always loaded
}
# => { text = "..."; description = "bash-strict-mode"; priority = 20; paths = ["*.sh"]; }
```

### compose

Sort fragments by priority, deduplicate by content hash, concatenate:

```nix
fragments.compose {
  fragments = [
    (fragments.mkFragment { text = "Rule A"; priority = 10; })
    (fragments.mkFragment { text = "Rule B"; priority = 20; })
    (fragments.mkFragment { text = "Rule A"; priority = 5; })  # duplicate, dropped
  ];
  description = "combined rules";
}
# => mkFragment { text = "Rule B\nRule A"; description = "combined rules"; ... }
```

### mkEcosystemContent

Apply per-ecosystem frontmatter to a composed fragment:

```nix
fragments.mkEcosystemContent {
  ecosystem = "claude";
  package = "my-project";
  composed = myComposedFragment;
  paths = ["src/**"];
}
# => "---\ndescription: Instructions for the my-project package\npaths: src/**\n---\n\n<composed text>"
```

## Credential Helpers

### mkSecretsWrapper

Wraps a binary with a shell script that reads credentials at runtime:

```nix
mcp.mkSecretsWrapper {
  inherit pkgs;
  name = "github-mcp";
  package = pkgs.nix-mcp-servers.github-mcp;
  credentialVars = {
    credentials = { envVar = "GITHUB_PERSONAL_ACCESS_TOKEN"; required = true; };
  };
  settings = evaluatedSettings;
}
# => "/nix/store/.../github-mcp-env"  (shell script that reads secret, then exec's the binary)
```

## What to Use When

| Goal                                        | Function                         |
| ------------------------------------------- | -------------------------------- |
| Quick MCP entry from a package              | `mkPackageEntry`                 |
| MCP entry with typed settings + credentials | `mkStdioEntry`                   |
| Multiple servers at once                    | `mkStdioConfig`                  |
| Build instruction content from fragments    | `compose` + `mkEcosystemContent` |
| Runtime credential injection                | `mkSecretsWrapper`               |
