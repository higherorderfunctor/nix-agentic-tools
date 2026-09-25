# Semble integrations

> **Last verified:** 2026-09-25 — `extracted.json` snapshots Semble's language
> knowledge and regenerates on `llm-agents` bumps; model examples use
> `pkgs.ai.fetchHuggingFaceModel`, which sets no `passthru.files`; `cli.models`
> routes the CLI across per-key embedding models through a Semble patch;
> `instructions.cli` became `cli.instructions` with no alias; `finalPackage`
> exposes the portable package; `mkSemble` passes any set `content`.
>
> Full lineage: `git show 3dc3057b:packages/semble/docs/semble.md`.

Semble provides local semantic and lexical code search through a CLI and an MCP
server. This repository re-exports Numtide's pinned derivation unchanged and
adds matching Home Manager and devenv convenience modules for Claude, Codex, and
Kiro.

## Umbrella configuration

```nix
{
  imports = [inputs.nix-agentic-tools.homeManagerModules.default];
  nixpkgs.overlays = [inputs.nix-agentic-tools.overlays.default];

  ai.programs.semble.enable = true;

  # Runtime selection configures integrations but does not enable a CLI.
  ai.claude.enable = true;
  ai.codex.enable = true;
  ai.kiro.enable = true;
}
```

The same `ai.programs.semble` option tree is available through
`devenvModules.nix-agentic-tools`.

## Per-feature and per-runtime configuration

```nix
ai = {
  programs.semble = {
    enable = true;
    grammars = with pkgs.tree-sitter-grammars; [
      tree-sitter-awk
      tree-sitter-jq
    ];
    package = pkgs.ai.semble;

    cli.instructions.enable = true;
    mcp = {
      enable = true;
      content = ["code" "docs"];
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
    };
    subagent = {
      enable = true;
      interface = "mcp";
    };
  };

  # Program-level on/off replaces runtime lists.
  claude.programs.semble.enable = false;
  codex.programs.semble.subagent.enable = true;
  kiro.programs.semble.mcp.enable = false;
};
```

Every runtime override leaf is nullable: null inherits the corresponding
`ai.programs.semble` value, while a non-null runtime value wins. After that B4
resolution, MCP selection applies specificity in this order: an explicit runtime
feature value, an explicit runtime program value, the portable feature value,
then the portable program value. CLI instructions and the subagent are portable
boolean opt-ins instead: a runtime program `false` retracts them, a runtime
feature value can differ, and runtime program `true` does not turn them on
implicitly. This makes `ai.<runtime>.programs.semble.enable = false` the
replacement for removing a runtime from the former selector even when a portable
feature is explicitly enabled; an explicit runtime feature value can still make
just that feature differ. There is no `runtimes` selector. Program options exist
only for Semble's declared capability set: Claude, Codex, and Kiro.

The MCP content values are `code`, `docs`, `config`, and `all`. A scalar is
accepted as a one-element list; several categories may be combined and are
sorted into canonical argv. Empty lists, duplicates, and `all` mixed with a
specific category fail evaluation. `["code"]` uses Semble's default and emits no
command-line argument. Semble 0.5.5's MCP tools also accept one scalar `content`
value per call, replacing the server default for that call.

`ai.programs.semble.mcp.rootExposure = false` keeps the root MCP pool free of
Semble while retaining the server inside a Kiro `semble-search` agent. It
requires that runtime's subagent to be enabled with `interface = "mcp"`. Kiro's
agent receives `tools = ["@semble"]`, `includeMcpJson = false`, and its own
`mcpServers.semble` entry whether root exposure is on or off. Claude and Codex
cannot isolate an agent-scoped server and therefore fail evaluation when root
exposure is disabled; the integration does not emulate this by weakening the
root boundary.

`ai.programs.semble.grammars` extends Semble with nixpkgs Tree-sitter grammar
packages. Each package must expose its canonical `language` attribute and the
compiled library at `${grammar}/parser`, which is the shape produced by
`pkgs.tree-sitter.buildGrammar` and exported through
`pkgs.tree-sitter-grammars`. The module patches the selected Semble Python
package to try these store-backed parsers after its bundled grammar lookup. This
keeps the upstream bundle intact and avoids its mutable extraction cache.

`ai.programs.semble.mcp.pathMappings` assigns files with non-standard names to
an existing or extra grammar and to one of Semble's `code`, `config`, or `docs`
indexes. A pattern without `/` matches a basename at any depth; a pattern
containing `/` matches the path relative to the indexed repository root. Entries
are ordered and the first match wins. Path matching uses `fnmatch` semantics,
where `*` can span `/`; use an exact relative path when directory depth matters.
A match overrides both suffix-based language detection and content
categorization. Mappings participate in file discovery, parser selection, and
cache validation, so mapped files are indexed and changes to them invalidate the
relevant index normally.

In Semble 0.6.0, index creation collects files before wrapping iteration in a
progress bar. The customization patch passes content selection to that
collection and the repository root to language detection inside the loop. The
`module-semble-extra-grammars-load` check builds the customized package and
exercises grammar loading, mapped discovery, and cache fingerprints.

The customized package writes a fingerprint of its grammar and mapping set into
index metadata and rejects caches created by a different customization. The HM
and devenv modules additionally clear their owned cache root when the effective
package changes.

Shebang-based inference is deliberately out of scope. Extensionless scripts must
be listed through `pathMappings`; the integration does not read file contents to
guess their language.

Active runtimes whose package, grammar, and mapping values resolve to the same
customized derivation share one installed wrapper and cache. When those values
produce several derivations, the module installs one collision-free aggregate:
its ordinary `semble` command targets a stable canonical variant, while
runtime-generated guidance uses `semble-<runtime>` and each MCP entry points
directly at its own variant. Distinct variants use package-keyed cache
subdirectories, so incompatible customization fingerprints never alternate in
one index. Named MCP entries plus Claude and Codex normalized subagents use a
whole-entry `mkDefault`, so an ordinary consumer value replaces the generated
record atomically and `null` suppresses it for that runtime. The CLI rule
instead defaults each content field: a consumer's higher-priority `text`
overrides the packaged `source`, which remains visible on the resolved rule. Set
`ai.<runtime>.rules.semble.enable = false` to retract it at the normalized pool,
or disable `ai.<runtime>.programs.semble.cli.instructions` at its package gate.
Kiro's runtime-native subagent is not a normalized nullable pool: consumers can
replace the generated entry atomically, but cannot suppress it with `null`.
Claude and Codex compose the guidance into their single always-loaded
`CLAUDE.md` and `AGENTS.md` files. Kiro receives the same named rule and writes
it to `.kiro/steering/semble.md`.

Home Manager fixes the global cache at `${config.xdg.cacheHome}/semble`, even on
Darwin where Semble's platform default would otherwise be `~/Library/Caches`.
The devenv integration uses `${config.devenv.state}/semble-cache`. Both bake
`SEMBLE_CACHE_LOCATION` into every entry point of a launcher wrapper, so
`semble`, `semble-mcp`, and their invalidation guards cannot disagree, and the
value never enters the surrounding user or project shell. Consumer override of
the variable through `env` is deliberately gone: devenv/Nix is the only config
path.

Both backends record each effective Semble package store path in its assigned
cache directory. A single active package keeps the established cache root;
multiple distinct packages use stable package-keyed directories below
`variants/`. Home Manager activation checks the user-global cache family; devenv
shell entry checks only that project's relocated cache family. A missing or
changed stamp clears the indexes in that variant directory before recording the
new identity. Extra grammars and path mappings both change the effective package
path, so changing either uses the same invalidation path as a Semble version
update. Savings data and the separate upstream bundled-grammar extraction cache
are left alone.

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

## Embedding models

`cli.models` lets the CLI route searches across several embedding models. Each
key names a model directory (a package, never a Hugging Face id), the content
categories it searches by default, and a purpose shown to agents:

```nix
let
  hf = pkgs.ai.fetchHuggingFaceModel;
in {
  ai.programs.semble.cli.models = {
    default = {
      model = hf {
        repoId = "minishlab/potion-code-16M-v2";
        rev = "e9d2a44ca6a05ac6685f3b23709ea57eb7352d5b";
        files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
        hash = "sha256-EPzwepPyhcrNmU6lrmx2F5iCSbeSoKg5qZbErEEYHvw=";
        license = pkgs.lib.licenses.mit;
      };
      description = "Source code: implementations, tests, build files.";
    };
    prose = {
      model = hf {
        repoId = "minishlab/potion-base-32M";
        rev = "1e5a03f8eeb2c98b928fbbd846f22f816360919f";
        files = ["config.json" "model.safetensors" "modules.json" "tokenizer.json"];
        hash = "sha256-d9bGAm1XdYCwF63uODq5eD5Ow7utLaoxaxCYtVrqMTU=";
        license = pkgs.lib.licenses.mit;
      };
      content = "docs";
      description = "Prose: READMEs, design notes, architecture docs.";
    };
  };
}
```

The CLI then behaves like this:

- `semble search …` uses the `default` entry's model and content.
- `semble --model prose search …` and `semble search … --model prose` use the
  `prose` entry. `--model` is accepted before the subcommand and on `search` and
  `find-related`, not on `clear`, which removes every index anyway.
- `--content` replaces the entry's content for that call, whole.
- An unknown or disabled key is an argparse error that lists the valid keys.
  With `default.enable = false`, a call without `--model` fails the same way.

`default` always exists: the option's `apply` adds Semble's built-in entry when
no definition names it. It is not defined in config, because an `attrsOf` option
keeps only its highest-priority definitions: a normal-priority entry would drop
a consumer's `cli.models = lib.mkDefault {…}` wholesale, and a lower-priority
one would be dropped by any consumer key. Disable it rather than removing it.
`default.model = null` (the default) means Semble's built-in model, and its
description then falls back to a built-in text. Once `default.model` is set,
`default.description` is required whenever the routing block lists the default,
that is, while another entry is enabled. At least one entry must stay enabled.
Other keys have no description default, so an enabled entry without one fails
with nixpkgs' own path-qualified error. Keys match `[a-z0-9][a-z0-9_-]*`. When a
model package lists `passthru.files`, evaluation checks them against model2vec's
three folder layouts. `pkgs.ai.fetchHuggingFaceModel` outputs do not set it.

The models live under `cli` because only the CLI routes between them today. If
the MCP server gains per-call model selection, `models` should move to the
program root. `default.model` already drives the module's MCP server; the
`default.enable` flag is CLI-only.

### Mechanism

Routing is a patch to Semble's entry points (`patches/models.patch`), not a bash
wrapper, which leaves room for per-call model selection over MCP later:

- `cli.py` reads a generated key table (`src/semble/semble_models.py`, written
  in `postPatch` the way the grammar loader is). It resolves the entry, fills
  `--content` from it when absent, and sets `SEMBLE_MODEL_NAME` in-process only
  when the entry names a model. `main()` skips a leading `--model` before
  choosing between the CLI and the MCP server.
- `semble-mcp` (the same entry point) takes `--model KEY` too. Without it, the
  server uses the default entry's model and upstream's content default, so the
  module's `mcp.content` still decides. With it, the server uses that entry's
  model and content unless `--content` is given. It never reads
  `default.enable`.
- `cache.py`'s `find_index_from_cache_folder` appends `@` and 16 hex characters
  of `sha256(model name)` to the index directory when the model is not Semble's
  default: `<cache>/<repo-hash>/index-<scope>@<modelhash>`. Upstream 0.6.0 keys
  the index by repo and content only, so two models on one repo would overwrite
  each other. The default model keeps upstream's exact path, the path never
  depends on the key, and `semble clear index` (which removes each repo folder)
  still reaches every model's index, so the cache guard needs no change.

The models patch applies on its own or on top of the grammar patch, and only
when `cli.models` differs from the built-in default. With the built-in default
and no grammars or path mappings, the installed package stays upstream's
derivation byte for byte, which is what keeps it substitutable. Any model edit
changes the package, a key rename included, so the cache guard clears the
indexes on the next activation or shell entry.

A runtime override resolves `cli.models` per key (the program factory's `pools`
field): `ai.kiro.programs.semble.cli.models.prose = null` drops one key for
Kiro, and a runtime entry replaces only the entry with its key. The resolved set
must still hold `default`; disable it with `default.enable = false` instead.

### Routing guidance

When a key other than `default` is enabled, or `default` is disabled, the CLI
rule and both CLI subagent prompts open with a routing block: one line per
enabled key (invocation, content, description), then precedence lines. Each
enabled key whose content includes a category the default lacks gets "prefer
`--model K` over `--content C`", because the kept upstream template tells agents
to pass `--content` for non-code searches, which would reach the code model. A
final line says to pass the same `--model` (and `--content`) to `find-related`,
which otherwise queries the wrong index. The packaged template follows once. A
vanilla setup emits no block and keeps the packaged rule source.

### Extra MCP servers

`ai.programs.semble.finalPackage` is the read-only package built from the
portable config, with the module's cache location baked in. It is declared
outside the program factory, so it has no runtime override. Point a
hand-declared server at it to serve another model:

```nix
ai.claude.mcpServers.semble-docs = inputs.nix-agentic-tools.lib.ai.mcpServers.mkSemble {
  inherit lib pkgs;
} {
  command = "${config.ai.programs.semble.finalPackage}/bin/semble-mcp";
  args = ["--model" "prose"];
};
```

`mkSemble`'s `content` defaults to null, which passes no `--content`, so the
server searches the `prose` entry's content. Any set `content`, `"code"`
included, is passed and replaces it.

## CLI rule and subagent content

`cli.instructions.enable` installs one named `semble` rule containing committed
CLI guidance, without the non-Nix `uvx` fallback. It defaults false even when
the program is enabled. The named subagent also defaults false and selects one
of two committed prompts: `interface = "cli"` uses shell/read tools and the CLI
prompt; `interface = "mcp"` uses the MCP prompt and restricts Claude/Kiro to
Semble's two tool names (Codex omits its unsupported tool allowlist natively).
Keeping separate files prevents a global CLI rule and an MCP-only agent from
carrying mixed access instructions.

Both derivatives adopt Semble 0.6.0's searches across repositories: several
positional paths for CLI calls, or a scalar/list `repo` for MCP calls. Labeled
result paths resolve through the returned `repos` map for reading, but remain
labeled for related searches with the same repositories and content selection. A
source URL identifies a repository, not a local checkout.

The local prompts and agent descriptions deliberately omit upstream's blanket
preference over read/search tools and its bans on repeated searches. Results are
candidates requiring source verification; similarity does not prove an
exhaustive caller list. MCP-only subagents return locations and verification
needs to the caller when they cannot read source themselves. The upstream
snapshot remains verbatim for provenance.

## Upstream template review gate

`packages/semble/upstream-templates.json` snapshots the four pinned agent
templates, the installer block, and a live JSON-RPC `tools/list` response
through a separate derivation; Semble itself remains unchanged. The four agent
templates retain human-reviewed hash pins. The installer prose is no longer a
reviewed hash dependency: a mechanical provenance assertion instead requires its
embedded `semble[mcp]==<version>` fallback to match the packaged version. The
exact MCP surface is reviewed separately, and every tool and argument named by
the committed MCP prompt must remain present. Module evaluation reads only
committed files and does not introduce IFD.

## Language knowledge snapshot

`packages/semble/extracted.json` records what the pinned Semble knows about
languages, and `lib/extracted.nix` exposes it to evaluation without IFD. Two
packages decide how a file is treated:

- **semble** maps a file suffix to a language (`extensions`). A suffix outside
  that map is not indexed. `contentTypes` holds the language sets behind
  `--content code|docs|config`; `code` is upstream's remainder after docs,
  config and `dataLanguages`.
- **semble-grammars** decides which languages get tree-sitter parsing
  (`grammars.bundled`, after its `grammars.aliases`, so `zsh` parses as `bash`).
  Every other indexed language falls back to line chunking. `parsedLanguages`
  joins the two.

semble-grammars ships one wheel per platform, each with its own manifest, and
`available_languages()` reads that manifest. The extractor
(`checks/extract-languages.py`) imports the real modules under Semble's own
interpreter and fails unless the platform manifest equals the
platform-independent `sources.json`. So the committed file is the same on every
system, and the drift check (`semble-languages-extracted`) running on each CI
platform catches a platform that drops a grammar. On 0.1.2 the linux-x86_64 and
macos-arm64 manifests both list the same 77 grammars as `sources.json`.

Semble has no update target of its own; it arrives with the `llm-agents` input.
`dev/scripts/update-input.sh` therefore rebuilds both Semble snapshots
(`extracted.json` and `upstream-templates.json`) from their checks'
`passthru.extracted` on every `llm-agents` bump, so the bot PR carries them.

## Direct configuration

The convenience module is optional. The exported helpers can be composed with
native runtime configuration, including Copilot:

```nix
let
  nat = inputs.nix-agentic-tools;
in {
  ai.codex = {
    mcpServers.semble = nat.lib.ai.mcpServers.mkSemble {inherit lib pkgs;} {
      content = ["code" "docs"];
    };
    agents.semble-search = nat.lib.ai.semble.mcp.semanticAgent;
    rules.semble = nat.lib.ai.semble.rule;
  };

  ai.kiro = {
    mcpServers.semble = nat.lib.ai.mcpServers.mkSemble {inherit lib pkgs;} {};
    agents.semble-search = nat.lib.ai.semble.mcp.kiroAgent;
    rules.semble = nat.lib.ai.semble.rule;
  };
}
```

For package-only composition,
`lib.ai.semble.customizePackage { inherit lib pkgs; } package grammars pathMappings models`
applies all three customizations; `models` takes the `cli.models` shape, and a
missing `default` means the built-in one. `lib.ai.semble.withGrammars` remains
the grammar-only shorthand. `lib.ai.semble.forCli { command; models; }` renders
the CLI records with the routing block.

The package roles are `pkgs.ai.semble` and `pkgs.ai.mcpServers.semble-mcp`. They
share one derivation; the latter changes only the evaluation-time
`meta.mainProgram` used by `lib.getExe`.

Unless `cli.models.default.model` is set, Semble downloads its built-in
embedding model into the user cache on first use; the Nix package does not
vendor it.
