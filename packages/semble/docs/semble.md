# Semble integrations

Semble provides local semantic and lexical code search through a CLI and an MCP
server. This repository re-exports Numtide's pinned derivation unchanged and
adds matching Home Manager and devenv convenience modules for Claude, Codex, and
Kiro.

## Umbrella configuration

```nix
{
  imports = [inputs.nix-agentic-tools.homeManagerModules.default];
  nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

  semble.enable = true;

  # Runtime selection configures integrations but does not enable a CLI.
  ai.claude.enable = true;
  ai.codex.enable = true;
  ai.kiro.enable = true;
}
```

The same `semble.*` option tree is available through
`devenvModules.nix-agentic-tools`.

## Per-feature and per-runtime configuration

```nix
semble = {
  enable = true;
  package = pkgs.ai.semble;
  runtimes = ["claude" "codex"];

  mcp = {
    enable = true;
    runtimes = ["claude" "kiro"];
    content = "all";
  };
  instructions.enable = false;
  subagent.runtimes = ["codex"];
};
```

A feature's nullable `enable` overrides `semble.enable`; null inherits it. A
feature's nullable `runtimes` overrides `semble.runtimes`; null inherits the
top-level list. The MCP content values are `code`, `docs`, `config`, and `all`.
`code` uses Semble's default and emits no command-line argument.

Any active integration installs `semble.package`. Named MCP and subagent entries
use `mkDefault`, so consumers can refine their generated values.

## Direct configuration

The convenience module is optional. The exported helpers can be composed with
native runtime configuration, including Copilot:

```nix
let
  nat = inputs.nix-agentic-tools;
in {
  ai.codex = {
    mcpServers.semble = nat.lib.ai.mcpServers.mkSemble {inherit lib pkgs;} {
      content = "docs";
    };
    agents.semble-search = nat.lib.ai.semble.semanticAgent;
    instructions = [nat.lib.ai.semble.instruction];
  };

  ai.kiro.agents.semble-search = nat.lib.ai.semble.kiroAgent;
}
```

The package roles are `pkgs.ai.semble` and `pkgs.ai.mcpServers.semble-mcp`. They
share one derivation; the latter changes only the evaluation-time
`meta.mainProgram` used by `lib.getExe`.

Semble may download its embedding model into the user cache on first use. The
Nix package does not vendor that runtime model.
