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
  grammars = with pkgs.tree-sitter-grammars; [
    tree-sitter-awk
    tree-sitter-jq
  ];
  pathMappings = [
    {
      content = "code";
      language = "bash";
      patterns = [".envrc" "checks/hooks/pre-edit"];
    }
    {
      content = "config";
      language = "json";
      patterns = ["flake.lock" "devenv.lock"];
    }
    {
      content = "docs";
      language = "markdown";
      patterns = ["*.md.fixture"];
    }
  ];
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

`semble.grammars` extends Semble with nixpkgs Tree-sitter grammar packages. Each
package must expose its canonical `language` attribute and the compiled library
at `${grammar}/parser`, which is the shape produced by
`pkgs.tree-sitter.buildGrammar` and exported through
`pkgs.tree-sitter-grammars`. The module patches the selected Semble Python
package to try these store-backed parsers after its bundled grammar lookup. This
keeps the upstream bundle intact and avoids its mutable extraction cache.

`semble.pathMappings` assigns files with non-standard names to an existing or
extra grammar and to one of Semble's `code`, `config`, or `docs` indexes. A
pattern without `/` matches a basename at any depth; a pattern containing `/`
matches the path relative to the indexed repository root. Entries are ordered
and the first match wins. Path matching uses `fnmatch` semantics, where `*` can
span `/`; use an exact relative path when directory depth matters. A match
overrides both suffix-based language detection and content categorization.
Mappings participate in file discovery, parser selection, and cache validation,
so mapped files are indexed and changes to them invalidate the relevant index
normally.

The customized package writes a fingerprint of its grammar and mapping set into
index metadata and rejects caches created by a different customization. The HM
and devenv modules additionally clear their owned cache root when the effective
package changes.

Shebang-based inference is deliberately out of scope. Extensionless scripts must
be listed through `pathMappings`; the integration does not read file contents to
guess their language.

Any active integration installs `semble.package`. Named MCP, subagent, and rule
entries use `mkDefault`, so consumers can refine their generated values. Claude
and Codex compose the guidance into their single always-loaded `CLAUDE.md` and
`AGENTS.md` files. Kiro receives the same named rule and writes it to
`.kiro/steering/semble.md`.

Home Manager fixes the global cache at `${config.xdg.cacheHome}/semble`, even on
Darwin where Semble's platform default would otherwise be `~/Library/Caches`.
The devenv integration uses `${config.devenv.state}/semble-cache`. Both bake
`SEMBLE_CACHE_LOCATION` into every entry point of a launcher wrapper, so
`semble`, `semble-mcp`, and their invalidation guards cannot disagree, and the
value never enters the surrounding user or project shell. Consumer override of
the variable through `env` is deliberately gone: devenv/Nix is the only config
path.

Both backends record the effective Semble package store path in their cache
root. Home Manager activation checks the user-global cache; devenv shell entry
checks only that project's relocated cache. A missing or changed stamp clears
all indexes in that root before recording the new identity. Extra grammars and
path mappings both change the effective package path, so changing either uses
the same invalidation path as a Semble version update. Savings data and the
separate upstream bundled-grammar extraction cache are left alone.

The devenv relocation is unconditional: a project-local index is the point, and
nothing about it is Codex-specific. Until 2026-08-10 it read otherwise, because
the environment write lived inside the Codex cache hook and so was gated on
Codex being selected — Semble for Claude alone got the XDG default, while the
same project with Codex on got the project-local one. Codex had simply inherited
the write path by sitting next to it.

The writable-root grant IS still conditional, on a selected feature targeting
Codex with `sandbox_mode` set to `workspace-write`. That gate is about Codex's
sandbox rather than about where Semble keeps its index. The module does not
choose a sandbox mode.

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
    rules.semble = nat.lib.ai.semble.rule;
  };

  ai.kiro = {
    agents.semble-search = nat.lib.ai.semble.kiroAgent;
    rules.semble = nat.lib.ai.semble.rule;
  };
}
```

For package-only composition,
`lib.ai.semble.customizePackage { inherit lib pkgs; } package grammars pathMappings`
applies both customization lists. `lib.ai.semble.withGrammars` remains the
grammar-only shorthand.

The package roles are `pkgs.ai.semble` and `pkgs.ai.mcpServers.semble-mcp`. They
share one derivation; the latter changes only the evaluation-time
`meta.mainProgram` used by `lib.getExe`.

Semble may download its embedding model into the user cache on first use. The
Nix package does not vendor that runtime model.
