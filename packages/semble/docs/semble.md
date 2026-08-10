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

Home Manager leaves the cache where Semble puts it by default,
`${config.xdg.cacheHome}/semble`, so nothing needs telling and the package ships
unwrapped. A devenv integration relocates it to
`${config.devenv.state}/semble-cache` and tells Semble by baking
`SEMBLE_CACHE_LOCATION` into every entry point of a launcher wrapper — so
`semble` and `semble-mcp` cannot disagree, and the value never enters the
project shell. Consumer override of the variable through `env` is deliberately
gone: devenv/Nix is the only config path.

Two things changed on 2026-08-10. The relocation is now unconditional on devenv;
it used to live inside the Codex cache hook, so the cache silently moved
depending on whether Codex was enabled. The writable-root grant is still
conditional — on a selected feature targeting Codex with `sandbox_mode` set to
`workspace-write`. The module does not choose a sandbox mode.

## Instruction content

Upstream's instructions integration primarily explains the MCP tool names and
marks its managed block for installer removal. This module instead installs the
reviewed CLI search guidance shared with the `semble-search` subagent, without
the non-Nix `uvx` fallback. The distinction is deliberate: `semble-mcp` supplies
its MCP-tool guidance in the server's own session instructions, while the
always-loaded `CLAUDE.md`, `AGENTS.md`, or Kiro steering file documents the CLI
path that remains useful to shell-capable agents.

## Upstream template review gate

`packages/semble/upstream-templates.json` snapshots the four pinned agent
templates and the installer's instruction block through a separate derivation;
Semble itself remains unchanged. An `llm-agents` input update regenerates that
factual snapshot but deliberately leaves the reviewed hashes in
`lib/templateCoverage.nix` untouched. CI therefore stops on any upstream content
change until a person checks the local derivatives and updates the matching
dispositions and hashes. Module evaluation reads only committed files and does
not introduce IFD.

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
