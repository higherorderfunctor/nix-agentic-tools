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
use `mkDefault`, so consumers can refine their generated values. Claude and
Codex compose the guidance into their single always-loaded `CLAUDE.md` and
`AGENTS.md` files. Kiro receives a named instruction and writes it to
`.kiro/steering/semble.md`.

When a selected Semble feature targets Codex and `sandbox_mode` is
`workspace-write`, the module automatically grants Semble a writable cache. Home
Manager appends `${config.xdg.cacheHome}/semble`. A Codex-targeted devenv
integration uses `${config.devenv.state}/semble-cache`, exports that path as
`SEMBLE_CACHE_LOCATION`, and follows a consumer override of the variable. The
module does not choose a sandbox mode; it only adds the matching writable root
when the consumer selects `workspace-write`.

## Instruction content

Upstream's instructions integration primarily explains the MCP tool names and
marks its managed block for installer removal. This module instead installs the
reviewed CLI search guidance shared with the `semble-search` subagent, without
the non-Nix `uvx` fallback. The distinction is deliberate: `semble-mcp` supplies
its MCP-tool guidance in the server's own session instructions, while the
always-loaded `CLAUDE.md`, `AGENTS.md`, or Kiro steering file documents the CLI
path that remains useful to shell-capable agents.

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

  ai.kiro = {
    agents.semble-search = nat.lib.ai.semble.kiroAgent;
    instructions = [nat.lib.ai.semble.kiroInstruction];
  };
}
```

The package roles are `pkgs.ai.semble` and `pkgs.ai.mcpServers.semble-mcp`. They
share one derivation; the latter changes only the evaluation-time
`meta.mainProgram` used by `lib.getExe`.

Semble may download its embedding model into the user cache on first use. The
Nix package does not vendor that runtime model.
