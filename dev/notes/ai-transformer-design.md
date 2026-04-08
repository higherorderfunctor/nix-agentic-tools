# AI ecosystem records — extensibility, composition, evaluation efficiency

> Captured during 2026-04-07 ideation session, revised mid-session
> after a key correction (see "Scope correction" below). Not a plan —
> a design note for a future refactor that should land **after** the
> sentinel→main merge stabilizes. Records the design space, the
> recommended shape, the rejected alternatives, and the open
> questions, so future-you (or a contributor) doesn't have to
> re-derive any of this.

## Scope correction (2026-04-07, second iteration)

The first version of this note framed everything around a "markdown
transformer record" — fragment AST → ecosystem-specific bytes. The
user correctly pointed out that this is **only one of several
per-ecosystem transformation axes** in the AI fanout system, and
treating it as the central abstraction is too narrow.

The actual transformation surface includes at least:

| Axis | Today's example | Shape |
|---|---|---|
| Shared settings → ecosystem keys | `ai.settings.model` → `programs.kiro-cli.settings.chat.defaultModel` | data → data |
| Shared LSP servers → ecosystem schema | `ai.lspServers.*` → `mkCopilotLspConfig` vs `mkLspConfig` | data → data (different shapes) |
| Shared env vars → ecosystem options or skip | `ai.environmentVariables` → `programs.copilot-cli.environmentVariables` (Claude skips) | data → data (or noop) |
| Shared instructions → markdown bytes | `ai.instructions` → `<frontmatter>` + body with link rewriting | data → bytes |
| Markdown bytes → on-disk file | rendered string → `~/.claude/rules/foo.md` | bytes → file (per backend) |
| Shared skills → on-disk dir layout | `ai.skills.foo = ./path` → `~/.claude/skills/foo/` (HM) vs `<project>/.claude/skills/foo/` (devenv) | path → file (per backend) |

Markdown rendering is one row. The other rows are equally important
and equally per-ecosystem. The right unifying abstraction is **an
ecosystem record that bundles all per-axis translators + the markdown
transformer + a layout policy**. NixOS modules become thin **backend
adapters** (one for HM, one for devenv) that read the record and
dispatch to the appropriate backend writer.

This collapses the earlier confusion about whether HM and devenv
sit in a containment hierarchy. They don't. They're peers — two
parallel adapters that consume the same shared `ai.*` options and
produce file placements through different backend primitives
(`home.file` vs devenv `files.*`).

The rest of this note has been revised to reflect this corrected
framing. The original "transformer record" abstraction survives but
is now demoted to a single field on the larger ecosystem record.

## Why this exists

The current codebase has several patterns that almost — but not
quite — give downstream consumers a clean way to extend the AI
fanout system without forking. Specifically:

- `pkgs.fragments-ai.passthru.transforms` is a registry of named
  transform functions (`claude`, `copilot`, `kiro`, `agentsmd`),
  but the registry is **producer-side only**. The consumer side
  (`modules/ai/default.nix`) hardcodes `mkIf cfg.claude.enable`,
  `mkIf cfg.copilot.enable`, `mkIf cfg.kiro.enable` branches and
  never iterates over the registry.
- Fragments are flat strings. Each transform appends frontmatter
  but cannot do per-target *body* transformations (link rewriting,
  per-target include semantics, snippet resolution). This forces
  duplicate body content if two targets need to render the same
  source differently.
- `dev/generate.nix` calls `mkDevComposed pkg` from three
  independent `concatMapAttrs` lambdas (one per ecosystem). Each
  call site creates its own thunk, so composition runs **3x per
  package**. With ~16 packages this is ~48 compose calls instead
  of 16. Multiplies further if README + AGENTS.md + mdBook are
  added as additional consumers.
- HM and devenv `ai` modules are ~80% structurally identical but
  duplicate the per-ecosystem fanout block.

The user's instinct ("there must be a higher-order abstraction
hiding here") is correct. The wrong framing was a 5-package
`nix-transformer` framework with custom schemas and overrides.
The right framing is three small primitives that compose with
the existing Nix module system + a single evaluation discipline.

## Goals

1. **Downstream extensibility**: a third-party flake can register
   a new ecosystem under `ai.*` (e.g., `ai.openhands.enable`)
   without forking `modules/ai/default.nix` or
   `packages/fragments-ai/default.nix`.
2. **Per-target body transformation**: same fragment renders to
   different bytes for Claude (`@import` paths), Kiro
   (`#[[file:...]]`), Copilot (markdown links), README (GitHub
   URLs), and mdBook (`{{#include}}`).
3. **Frontmatter inheritance / override**: ecosystems start from
   a base frontmatter rule and override specific fields (e.g.,
   Kiro customizes `fileMatchPattern` emission, Claude omits
   description when paths absent, README has no frontmatter).
4. **Evaluation efficiency**: same source fragments fan out to
   N targets with one composition pass, not N. Lazy eval should
   share the parsed/composed AST automatically.
5. **No new framework**: stay inside the Nix module system. No
   parallel type system. No custom override semantics. No
   monads. Anyone who knows nixpkgs should be able to read it.

## Non-goals

- Not building a generalized "transformer pipeline" library that
  could handle arbitrary domains. Two consumers (AI fanout +
  doc generation) is not enough to justify a generic framework.
- Not introducing a separate schema layer (Effect/Zod-style).
  NixOS module options are the schema layer.
- Not implementing monadic sequencing. Reader-shape (passing
  context through closure) is sufficient for everything in this
  domain. Nix has no `do` notation; trying to retrofit monads
  would be hostile to readers.
- Not introducing an `overrideAttrs`-style mechanism for
  transformer config. `recursiveUpdate` and attrset spread
  cover all needed override cases at zero infrastructure cost.
- Not materializing composition to the Nix store via writeText
  + IFD. Eval-time sharing via let-bindings is sufficient at
  the current scale (~50 fragments). Materialization is a
  flake-check killer (IFD) and not worth the complexity unless
  profiling shows compose is the bottleneck. It won't be.

## Architecture overview

The design has three layered abstractions plus one cross-cutting
discipline plus one new option-merging pattern:

| Layer | Concept | Lives in |
|---|---|---|
| 1 | Structured fragment nodes (markdown content as AST) | `lib/fragments.nix` |
| 2 | Ecosystem records (full per-ecosystem policy bundle, includes the markdown transformer as ONE field) | `lib/ai-ecosystems/<name>.nix`, downstream flakes |
| 3 | Backend adapters (HM module generator, devenv module generator) | `lib/mk-ai-ecosystem-hm-module.nix`, `lib/mk-ai-ecosystem-devenv-module.nix` |
| Cross-cutting | Single-binding shared composition (eval efficiency) | binding discipline + `passthru.composedByPackage` |
| Option pattern | Layered option pools — shared `ai.<category>` + per-eco `ai.<eco>.<category>` with merge | declared by the backend adapters from a single source-of-truth in `lib/ai-options.nix` |

Layer 2 is the unifying abstraction. The "markdown transformer
record" from the first iteration of this note is **one field** of
the ecosystem record, alongside per-axis translators (settings,
LSP, env), layout policy, and optional upstream-module delegation.

### Layer 1: Structured fragment nodes

Fragments today are flat strings. The proposal: fragments carry
a **list of nodes** instead. Each node is pure data with a
discriminator field. Renderers walk the list and dispatch on
node kind via a handler table.

```nix
# lib/fragments.nix additions (~30 lines)
mkRaw     = text: { __nodeKind = "raw"; inherit text; };
mkLink    = { target, label ? null }:
            { __nodeKind = "link"; inherit target label; };
mkInclude = path: { __nodeKind = "include"; inherit path; };
mkBlock   = nodes: { __nodeKind = "block"; inherit nodes; };
# Extensible — downstream can add new node kinds as long as the
# active transformer's handler table has an entry for them.
```

A fragment becomes:

```nix
mkFragment {
  text = [
    (mkRaw "Use the ")
    (mkLink { target = ./skills/stack-fix; label = "stack-fix"; })
    (mkRaw " skill for amending earlier commits.")
  ];
  description = "Stacked workflow guidance";
  paths = [ "src/**" ];
  priority = 10;
}
```

**Critical property: nodes carry no rendering policy.** A `mkLink`
node is the same data whether it's rendered for Claude, Kiro,
README, or mdBook. The rendering policy lives in the active
transformer's handler table. This is what makes the AST safe to
share across N targets (see Primitive 2 + the eval-efficiency
section).

**Backward compatibility**: treat a bare string `text` as
`[mkRaw text]` transparently. Existing flat-string fragments
keep working without migration. New code can opt into nodes
when it needs per-target body transformations.

### Layer 2: Ecosystem records — the unifying abstraction

An ecosystem record is a **backend-agnostic policy bundle** that
captures everything per-ecosystem: identity, package, where files
land, how shared options translate to ecosystem-specific shapes,
and how markdown bodies render. It is pure data — a record of
functions and constants. NixOS modules consume it; the record
itself never references `config.*`.

```nix
# lib/ai-ecosystems/claude.nix — sketch of the full record
{ lib, fragmentNodes }:
let
  baseTransformer = import ../transformers/base.nix { inherit lib fragmentNodes; };
in {
  # ── Identity ─────────────────────────────────────────────────
  name = "claude";
  package = null;  # default supplied by adapter (pkgs.claude-code)
  configDir = ".claude";

  # ── Markdown rendering (data → bytes) ────────────────────────
  # This is the "transformer record" from the first iteration —
  # demoted to a sub-field of the larger ecosystem record.
  markdownTransformer = lib.recursiveUpdate baseTransformer {
    name = "claude";
    frontmatter = { description, paths, package }: ...;
    handlers.link = ctx: node: "@${ctx.basePath}/${node.target}";
  };

  # ── Per-axis translators (data → data) ───────────────────────
  # Each takes a slice of the shared cfg and returns the
  # ecosystem-specific shape. Pure functions, no config reads.
  translators = {
    # ai.settings.{model, telemetry} → ecosystem-shaped settings
    settings = sharedSettings:
      lib.optionalAttrs (sharedSettings.model != null) {
        model = sharedSettings.model;
      };

    # ai.lspServers.<name> → ecosystem-specific LSP entry
    lspServer = name: server: {
      name = server.name;
      command = "${server.package}/bin/${server.binary}";
      filetypes = server.extensions;
    };

    # ai.environmentVariables.<name> → ecosystem-shaped env entry
    # null = ecosystem doesn't support env vars (Claude case)
    envVar = null;

    # ai.mcpServers.<name> → ecosystem-shaped MCP entry
    mcpServer = name: server: {
      type = if server ? url then "http" else "stdio";
      command = server.command or null;
      args = server.args or [];
      env = server.env or {};
    };
  };

  # ── Layout policy: where things land on disk ─────────────────
  # Returns relative paths under the user's HOME or project root.
  # Backend adapter prefixes with the right base depending on
  # whether it's writing home.file or devenv files.
  layout = {
    instructionPath = name: "${configDir}/rules/${name}.md";
    skillPath       = name: "${configDir}/skills/${name}";
    settingsPath    = "${configDir}/settings.json";
    lspConfigPath   = "${configDir}/lsp.json";
    mcpConfigPath   = "${configDir}/mcp.json";
  };

  # ── Upstream module delegation (optional) ────────────────────
  # If non-null, the backend adapter sets these option paths
  # instead of writing files directly. Lets us delegate to
  # rich existing HM/devenv modules (programs.claude-code.skills,
  # claude.code.skills) instead of bypassing them.
  #
  # Setting these to null means "no upstream module — write files
  # directly via home.file or devenv files." Used by orphan
  # ecosystems like a hypothetical openclaw with no nixpkgs
  # support.
  upstream = {
    hm = {
      enableOption = "programs.claude-code.enable";
      skillsOption = "programs.claude-code.skills";
      mcpServersOption = "programs.claude-code.mcpServers";
      # null fields fall through to direct file writes
      lspServersOption = null;
      settingsOption = "programs.claude-code.settings";
    };
    devenv = {
      enableOption = "claude.code.enable";
      skillsOption = "claude.code.skills";
      mcpServersOption = "claude.code.mcpServers";
      lspServersOption = null;
      settingsOption = null;
    };
  };

  # ── Extra options surfaced at ai.<name>.* ────────────────────
  # Ecosystem-specific options that don't fit the shared schema.
  # The backend adapter merges these into the per-ecosystem
  # submodule type so consumers can write `ai.claude.buddy = ...`.
  extraOptions = { lib, ... }: {
    buddy = lib.mkOption {
      type = lib.types.nullOr buddySubmodule;
      default = null;
    };
  };
}
```

Kiro and Copilot are similar records, with overrides via
`lib.recursiveUpdate` against a shared base or against another
ecosystem record (e.g., `kiro = recursiveUpdate claude { ... }`
to inherit Claude's defaults and override only the differences).

**Why a record, not a function**: a function is opaque — you
can only call it. A record of functions is **introspectable**,
**partially overridable**, and **structurally comparable**.
Downstream consumers can `recursiveUpdate` a single field
without understanding the rest. Tooling can iterate the layout
to list all files that would be placed. Tests can call individual
translators in isolation. This is the "transformer abstraction"
the user was asking for, generalized beyond markdown.

### Layer 2.5: Markdown transformer records (sub-field of Layer 2)

The `markdownTransformer` field of an ecosystem record is itself
a record-of-functions:

```nix
# lib/transformers/claude.nix
{ lib, fragmentNodes }: {
  name = "claude";

  # Frontmatter rule — pure function over fragment metadata
  frontmatter = { description, paths, package }:
    let
      hasPaths = paths != null;
      desc =
        if description != null && description != ""
        then description
        else if hasPaths
        then "Instructions for the ${package} package"
        else null;
    in
      if desc == null && !hasPaths
      then ""
      else
        "---\n"
        + (lib.optionalString (desc != null) "description: ${desc}\n")
        + (lib.optionalString hasPaths
            ("paths:\n"
             + lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") paths
             + "\n"))
        + "---\n\n";

  # Node handlers — extends defaults via attrset merge.
  # Each handler receives ctx (so it can recurse via ctx.render
  # for nodes that contain nested content like mkBlock or
  # mkInclude).
  handlers = fragmentNodes.defaultHandlers // {
    raw     = ctx: node: node.text;
    link    = ctx: node: "@${ctx.basePath}/${node.target}";
    include = ctx: node: ctx.render {
                            text = builtins.readFile node.path;
                          };
    # block inherits from defaults (recursive walk)
  };

  # Final assembly — usually frontmatter + body, can be customized
  assemble = { frontmatter, body }: frontmatter + body;
}
```

A renderer is a generic walker:

```nix
# lib/fragments.nix additions (~50 lines)
mkRenderer = transformer: ctxExtras:
  let
    self = ctxExtras // {
      handlers = transformer.handlers;
      render = fragment:
        let
          nodes =
            if builtins.isString fragment.text
            then [ (mkRaw fragment.text) ]
            else fragment.text;
          body = lib.concatMapStrings
            (node:
              let h = self.handlers.${node.__nodeKind}
                      or (throw "no handler for ${node.__nodeKind}");
              in h self node)
            nodes;
          frontmatter = transformer.frontmatter (
            { inherit (fragment) description paths; }
            // ctxExtras
          );
        in
          transformer.assemble { inherit frontmatter body; };
    };
  in self.render;
```

**Override via attrset merge.** Kiro extends Claude:

```nix
# lib/transformers/kiro.nix
{ lib, fragmentNodes, claudeTransformer }:
lib.recursiveUpdate claudeTransformer {
  name = "kiro";

  frontmatter = { description, paths, name }:
    let
      inclusion = if paths != null then "fileMatch" else "always";
      pattern =
        if paths == null then null
        else if builtins.length paths == 1
        then "\"${builtins.head paths}\""
        else "[" + lib.concatMapStringsSep ", "
                     (p: "\"${p}\"") paths
             + "]";
    in
      "---\n"
      + "name: ${name}\n"
      + "inclusion: ${inclusion}\n"
      + (lib.optionalString (pattern != null)
          "fileMatchPattern: ${pattern}\n")
      + "---\n\n";

  # Override only the link handler; everything else (raw,
  # include, block) inherits from claudeTransformer.
  handlers.link = ctx: node: "#[[file:${node.target}]]";
}
```

README extends with no frontmatter and GitHub URL link rewriting:

```nix
# packages/fragments-docs/transformers/readme.nix
{ lib, fragmentNodes, claudeTransformer }:
lib.recursiveUpdate claudeTransformer {
  name = "readme";
  frontmatter = _: "";  # noop
  handlers.link = ctx: node:
    "[${node.label or node.target}]"
    + "(${ctx.repoUrl}/blob/main/${node.target})";
  # include handler could inline content as a collapsible details block
}
```

mdBook similarly:

```nix
# packages/fragments-docs/transformers/mdbook.nix
{ lib, fragmentNodes, claudeTransformer }:
lib.recursiveUpdate claudeTransformer {
  name = "mdbook";
  frontmatter = _: "";  # mdbook doesn't use yaml frontmatter
  handlers.include = ctx: node: "{{#include ${node.path}}}";
  handlers.link = ctx: node:
    "[${node.label or node.target}](${node.target})";
}
```

**The "outer transformer alters inner thunk semantics" pattern**
is now mechanical: the node `mkLink {...}` is pure data, the
handler dispatch table comes from the active transformer's
record, and `ctx.render` inside a handler closes over the same
table — so a recursive include/snippet renders nested content
through the **same** transformer policy automatically. No
monads, no special infrastructure. Just records of functions
and a fixed-point on `self`.

**Why no monads**: Reader-shape (handlers from ctx) is enough
for everything described. Nix has no do-notation; bind chains
in raw Nix are unreadable; type inference can't help; debugging
monadic stacks in pure-Nix is brutal. Plain attrsets +
closures + fix-point cover the domain. Document this as an
intentional non-decision so future-you doesn't try to retrofit
a free monad.

### Layer 3: Backend adapters

A backend adapter is a function from an ecosystem record to a
NixOS module. Two adapters total — one for HM, one for devenv.
They're thin: their job is to declare per-ecosystem options,
read shared `ai.*` options, compute effective sets via merge,
filter disabled entries, and dispatch to the ecosystem record's
translators / transformer / layout.

```nix
# lib/mk-ai-ecosystem-hm-module.nix
{ lib, sharedOptions }: ecoRecord: { config, pkgs, ... }:
let
  cfg = config.ai;
  ecoCfg = cfg.${ecoRecord.name};

  # ── Effective option pools (shared + per-eco merge) ──────────
  effective = {
    skills        = lib.recursiveUpdate cfg.skills        ecoCfg.skills;
    instructions  = lib.recursiveUpdate cfg.instructions  ecoCfg.instructions;
    settings      = lib.recursiveUpdate cfg.settings      ecoCfg.settings;
    lspServers    = lib.recursiveUpdate cfg.lspServers    ecoCfg.lspServers;
    environmentVariables = lib.recursiveUpdate
                             cfg.environmentVariables
                             ecoCfg.environmentVariables;
    mcpServers    = lib.filterAttrs (_: v: v.enable or true)
                      (lib.recursiveUpdate cfg.mcpServers ecoCfg.mcpServers);
  };

  # ── Render markdown content for each instruction ─────────────
  T = ecoRecord.markdownTransformer;
  renderInstruction = name: instr:
    (mkRenderer T {
      package = name;
      basePath = ecoRecord.configDir;
    }) instr;

  # ── Assemble the config block ────────────────────────────────
  # Where each effective set lands depends on whether the
  # ecosystem record has an upstream HM module to delegate to,
  # or whether we write home.file directly (orphan ecosystem).
  fanoutBlock = lib.mkMerge [
    # Enable upstream module if specified
    (lib.optionalAttrs (ecoRecord.upstream.hm.enableOption != null)
      (lib.setAttrByPath
        (lib.splitString "." ecoRecord.upstream.hm.enableOption)
        (lib.mkDefault true)))

    # Skills: delegate if upstream supports it, else write home.file
    (if ecoRecord.upstream.hm.skillsOption != null
     then lib.setAttrByPath
            (lib.splitString "." ecoRecord.upstream.hm.skillsOption)
            (lib.mapAttrs (_: lib.mkDefault) effective.skills)
     else { home.file = mkSkillFiles ecoRecord effective.skills; })

    # Instructions: always rendered + placed
    {
      home.file = lib.concatMapAttrs (name: instr: {
        ${ecoRecord.layout.instructionPath name}.text =
          lib.mkDefault (renderInstruction name instr);
      }) effective.instructions;
    }

    # MCP servers: delegate if upstream supports it
    (lib.optionalAttrs (ecoRecord.upstream.hm.mcpServersOption != null)
      (lib.setAttrByPath
        (lib.splitString "." ecoRecord.upstream.hm.mcpServersOption)
        (lib.mapAttrs (n: s: ecoRecord.translators.mcpServer n s)
          effective.mcpServers)))

    # Settings: translate via ecosystem translator, then place
    (lib.optionalAttrs (ecoRecord.upstream.hm.settingsOption != null)
      (lib.setAttrByPath
        (lib.splitString "." ecoRecord.upstream.hm.settingsOption)
        (ecoRecord.translators.settings effective.settings)))

    # LSP servers, env vars: similar dispatch
    # ...
  ];
in {
  options.ai.${ecoRecord.name} = {
    enable = lib.mkEnableOption "${ecoRecord.name} fanout";
    package = lib.mkOption {
      type = lib.types.package;
      default = ecoRecord.package or (pkgs.${ecoRecord.name});
    };

    # Per-ecosystem extension points for every shared option category.
    # Source-of-truth types come from sharedOptions so the schema
    # stays in sync. Default {} so adding entries is purely additive.
    skills        = sharedOptions.skillsOption        // { default = {}; };
    instructions  = sharedOptions.instructionsOption  // { default = {}; };
    environmentVariables = sharedOptions.envVarsOption // { default = {}; };
    lspServers    = sharedOptions.lspServersOption    // { default = {}; };
    mcpServers    = sharedOptions.mcpServersOption    // { default = {}; };
    settings      = sharedOptions.settingsOption      // { default = {}; };
  } // (ecoRecord.extraOptions { inherit lib; });

  config = lib.mkIf ecoCfg.enable fanoutBlock;
}
```

The devenv adapter is structurally identical, with three
differences: `home.file` becomes `files`, `ecoRecord.upstream.hm`
becomes `ecoRecord.upstream.devenv`, and the package default
falls through to `ecoRecord.package` only (devenv tends not to
have rich upstream modules).

**Properties of the adapter approach**:

- The merge logic (effective = shared `recursiveUpdate` per-eco)
  lives in **one place**, not per ecosystem.
- The "upstream delegation vs direct file write" decision is
  data on the ecosystem record (`upstream.hm.skillsOption`),
  not control flow in each module.
- A new option category is added by: declaring it once in
  `sharedOptions`, adding one line to the `effective` set, and
  adding one dispatch block to `fanoutBlock`. Touches both
  adapters once each, no per-ecosystem changes.
- Orphan ecosystems with no upstream module work uniformly —
  set `upstream.hm.* = null`, the adapter falls through to
  direct `home.file` writes via the layout policy.

### Layered option pools (the new pattern)

This is the gap the user identified late in the design session
that wasn't part of the first iteration. It's not a new
primitive — it's a usage pattern enabled by Layer 3.

**Concept**: every shared option category at `ai.<category>` has
a parallel per-ecosystem extension point at `ai.<eco>.<category>`.
Both have the same type. The backend adapter computes the
effective set per ecosystem as `recursiveUpdate shared per-eco`,
so per-ecosystem entries can:

1. **Add** new entries that don't exist in the shared pool
2. **Override** shared entries with the same name (right-biased
   merge wins)
3. **Disable** shared entries via `enable = mkForce false` on
   the override (the adapter filters disabled entries before
   dispatch)

**Concrete example**: MCP servers shared globally, with one
ecosystem-specific addition.

```nix
ai = {
  # Shared pool — loaded by every enabled ecosystem
  mcpServers = {
    git-mcp    = { command = "git-mcp-server"; };
    github-mcp = { command = "github-mcp-server";
                   env.GITHUB_TOKEN = "..."; };
  };

  claude.enable = true;  # gets git-mcp + github-mcp

  kiro = {
    enable = true;
    mcpServers = {
      # kiro-specific addition — not loaded in claude
      aws-mcp = { command = "aws-mcp-server"; };
    };
  };

  # If you wanted to disable git-mcp in claude only:
  # claude.mcpServers.git-mcp.enable = lib.mkForce false;
};
```

**Effective sets per ecosystem**:

- `claude`: `{ git-mcp, github-mcp }` (shared only)
- `kiro`:   `{ git-mcp, github-mcp, aws-mcp }` (shared + kiro-specific)

The backend adapter computes these sets and dispatches each
through `ecoRecord.translators.mcpServer` to produce the
ecosystem-shaped MCP entries, then writes them to either
`programs.claude-code.mcpServers` (upstream delegation) or
`home.file."${configDir}/mcp.json"` (direct write, JSON
generated from the translated entries).

**This pattern applies uniformly to every shared category**:
`skills`, `instructions`, `environmentVariables`, `lspServers`,
`mcpServers`, `settings`. Adding a new shared category means
declaring it once in `sharedOptions` and the layered behavior
comes for free via the adapter.

**Why this is important**: it's how downstream users do
fine-grained customization without forking anything. The user's
real example (AWS MCP only loaded in Kiro because work) is the
canonical use case — there are always going to be ecosystem-
specific tools, secrets, instructions that shouldn't be
broadcast to every CLI. The layered pool gives them a place
to live without breaking the "shared" semantics for everything
else.

### Downstream extension story

There are now **three extension points** for downstream users,
in increasing order of effort:

**1. Per-ecosystem option overrides** (lowest effort):

Just write `ai.<eco>.<category>` entries in your existing
config. Layered pools handle the rest. No new modules, no
new flake inputs, no fork.

```nix
# In a consumer's existing home-manager config
ai.kiro.mcpServers.aws-mcp = { ... };
ai.claude.environmentVariables.CLAUDE_DEBUG = "1";
```

**2. Tweak an existing ecosystem's transformer** (medium effort):

Override the markdown transformer or per-axis translators on
an ecosystem record from your own flake. Use `recursiveUpdate`.
Re-import the upstream module with your modified record via
the adapter helper.

```nix
# In a downstream flake
let
  myClaudeRecord = lib.recursiveUpdate
    nix-agentic-tools.lib.aiEcosystems.claude {
      markdownTransformer.handlers.link = ctx: node:
        "@my-custom-prefix/${node.target}";
    };
in {
  homeManagerModules.ai-claude-custom =
    nix-agentic-tools.lib.mkAiEcosystemHmModule myClaudeRecord;
}
```

**3. Register a fully new ecosystem** (highest effort):

Build a new ecosystem record from scratch, or extend a base
record. Pass it to the backend adapter helpers to get HM and
devenv modules. Import in your consumer flake.

```nix
# In a downstream flake
let
  openClawRecord = {
    name = "openclaw";
    configDir = ".openclaw";
    package = openclaw-cli;

    markdownTransformer = lib.recursiveUpdate baseTransformer {
      handlers.link = ctx: node: "openclaw://${node.target}";
    };

    translators = {
      settings = s: { ... };
      mcpServer = name: s: { ... };
      lspServer = name: s: { ... };
      envVar = name: v: { ${name} = v; };
    };

    layout = {
      instructionPath = name: ".openclaw/rules/${name}.md";
      skillPath       = name: ".openclaw/skills/${name}";
      settingsPath    = ".openclaw/config.json";
      lspConfigPath   = ".openclaw/lsp.json";
      mcpConfigPath   = ".openclaw/mcp.json";
    };

    # No upstream HM/devenv module for openclaw — adapter
    # writes home.file / files directly.
    upstream = {
      hm = { enableOption = null; skillsOption = null;
             mcpServersOption = null; lspServersOption = null;
             settingsOption = null; };
      devenv = { enableOption = null; skillsOption = null;
                 mcpServersOption = null; lspServersOption = null;
                 settingsOption = null; };
    };

    extraOptions = { lib, ... }: {};
  };
in {
  homeManagerModules.ai-openclaw =
    nix-agentic-tools.lib.mkAiEcosystemHmModule openClawRecord;
  devenvModules.ai-openclaw =
    nix-agentic-tools.lib.mkAiEcosystemDevenvModule openClawRecord;
}
```

**4. Bonus: `mkRawEcosystem` shortcut** (minimal-effort orphan
ecosystem):

For ecosystems where you just want layered pools + raw file
placement with no transformations, a helper builds a record
where every translator is identity and the markdown
transformer treats text as bytes (no link rewriting):

```nix
# In a downstream flake
nix-agentic-tools.lib.mkRawEcosystem {
  name = "my-custom-cli";
  configDir = ".my-custom-cli";
  package = my-cli-pkg;
}
# Returns a complete ecosystem record with all-identity
# translators, no-op markdown handlers, and direct-write
# upstream config (all upstream.* fields null).
```

Useful for personal/quick ecosystems where building a full
record is overkill. ~30 lines of helper code.

**Consumer-side example combining all of the above**:

```nix
{
  inputs = {
    nix-agentic-tools.url = "github:higherorderfunctor/nix-agentic-tools";
    my-openclaw-ecosystem.url = "github:me/my-openclaw-ecosystem";
  };

  outputs = { self, nix-agentic-tools, my-openclaw-ecosystem, ... }: {
    homeConfigurations.me = home-manager.lib.homeManagerConfiguration {
      modules = [
        # In-repo ecosystems
        nix-agentic-tools.homeManagerModules.ai-claude
        nix-agentic-tools.homeManagerModules.ai-kiro
        nix-agentic-tools.homeManagerModules.ai-copilot
        # Downstream ecosystem
        my-openclaw-ecosystem.homeManagerModules.ai-openclaw

        {
          ai = {
            claude.enable = true;
            kiro.enable = true;
            openclaw.enable = true;

            # Shared across all enabled ecosystems
            skills.stack-fix = ./skills/stack-fix;
            instructions.standards = {
              text = "Use strict mode everywhere";
              paths = [ "src/**" ];
            };
            mcpServers.git-mcp = { command = "git-mcp-server"; };

            # Kiro-only addition (work AWS account)
            kiro.mcpServers.aws-mcp = {
              command = "aws-mcp-server";
              env.AWS_PROFILE = "work";
            };

            # Claude-only env var
            claude.environmentVariables.CLAUDE_DEBUG = "1";
          };
        }
      ];
    };
  };
}
```

That's the full extension story: a single shared `ai.*`
namespace, layered pools per ecosystem, three downstream
extension points covering 99% of customization use cases
without forking anything in this repo.

## Cross-cutting: single-binding shared composition

The node-based design unlocks something the current string-based
design fundamentally cannot: **the same composed AST fans out
to N targets with a single composition pass.**

Why it's safe to share: nodes carry no rendering policy.
A `mkLink` node is the same data whether it's rendered for
Claude, Kiro, README, or mdBook. The active transformer's
handler table decides what bytes come out. So building the
AST once and walking it N times with N different handler
tables is correct.

Why Nix gives this for free: lazy evaluation memoizes thunks.
Bind the composition once in `let`, and every consumer that
references the binding shares the same evaluated value.

```nix
# Recommended pattern
let
  composedByPackage = lib.mapAttrs (pkg: _:
    fragments.compose { fragments = collectFragmentsForPkg pkg; }
  ) packages;
in {
  # All five consumers below reference the SAME thunk.
  # Composition runs once per package regardless of consumer count.
  claudeFiles  = renderAll T.claude composedByPackage;
  kiroFiles    = renderAll T.kiro composedByPackage;
  copilotFiles = renderAll T.copilot composedByPackage;
  readmeBlocks = renderAll T.readme composedByPackage;
  mdbookPages  = renderAll T.mdbook composedByPackage;
}
```

This binding ideally lives in
`pkgs.fragments-ai.passthru.composedByPackage` so HM modules,
devenv modules, and `dev/generate.nix` all reference the same
attribute and share the same evaluation.

**Anti-pattern (do not do this)**: calling `compose` inside an
`mkIf` block creates a fresh thunk per ecosystem and kills the
sharing.

```nix
# BAD — three independent compositions, no sharing
config = mkMerge [
  (mkIf cfg.claude.enable {
    home.file.foo.text = render claudeT (compose { fragments = list; });
  })
  (mkIf cfg.kiro.enable {
    home.file.foo.text = render kiroT (compose { fragments = list; });
  })
];

# GOOD — one composition, shared via let
let composed = compose { fragments = list; };
in {
  config = mkMerge [
    (mkIf cfg.claude.enable { ... composed ... })
    (mkIf cfg.kiro.enable   { ... composed ... })
  ];
}
```

Document this anti-pattern in the per-ecosystem module convention
fragment so contributors don't accidentally reintroduce it.

**Cross-eval sharing** (HM eval ↔ devenv eval ↔ separate `nix
build` invocations) is unsolvable with let bindings alone — each
eval is its own process. The fix would be to materialize the AST
to the store via `writeText "ast.json" (builtins.toJSON ast)` and
have downstream consumers read it back. This introduces IFD risk
and is overkill at the current scale (~50 fragments,
sub-millisecond compose). **Do not do this** unless profiling
shows eval-time composition is a measurable bottleneck.

## Standalone fix (worth doing independently)

`dev/generate.nix` currently has the anti-pattern above, baked
in. Three separate `concatMapAttrs` lambdas (one for `claudeFiles`,
one for `copilotFiles`, one for `kiroFiles`) each contain
`let composed = mkDevComposed pkg;`. Three independent thunks per
package → 3x compose work.

The fix is mechanical and does not require any of the larger
refactor:

```nix
# Bind once at module top level
composedByPkg = lib.mapAttrs (pkg: _: mkDevComposed pkg) nonRootPackages;

# Then each consumer references the shared binding
claudeFiles = lib.mapAttrs' (pkg: composed:
  lib.nameValuePair "${pkg}.md"
    ((mkEcosystemFile pkg).claude composed)
) composedByPkg;

copilotFiles = { "copilot-instructions.md" = monorepoEco.copilot rootComposed; }
  // lib.mapAttrs' (pkg: composed:
       lib.nameValuePair "${pkg}.instructions.md"
         ((mkEcosystemFile pkg).copilot composed)
     ) composedByPkg;

# kiroFiles similar
```

~15 lines of refactor, 3x → 1x compose work. Worth doing as a
standalone commit independent of the larger redesign. Strong
candidate for a tax-day cleanup or a follow-up to the
architecture-foundation work.

## Rejected alternatives

### Alternative A: 5-package `nix-transformer` framework

Original proposal: `packages/nix-transformer{-markdown,-ai,-fs,-hm,-devenv}`
with custom schemas, override mechanism, registration system,
"thunks" as a first-class concept.

**Why rejected**: every primitive in this proposal already exists
in the Nix module system or in the existing `lib/` + `passthru`
patterns:

- Schemas → `lib.types` + `mkOption`
- Override → `mkMerge` / `mkDefault` / `mkForce` / module re-imports
- Registration → `imports = [...]` + `passthru` registry pattern
- Composition → function application + `recursiveUpdate`
- Rich errors → NixOS module eval errors are file:line precise

Re-implementing these in a parallel framework gives zero new
capability and adds a learning tax for every contributor. The
framework would also need its own HM and devenv "registration
helpers," which is the same number of files as the current
modules with more indirection.

The instinct ("there are repeated shapes here") is correct;
the framework framing is the wrong shape for the actual
repetition.

### Alternative B: `attrsOf submodule` ecosystem registry

Pattern A from the design discussion: `ai.ecosystems` is
declared as `lib.types.attrsOf (lib.types.submodule { ... })`,
and the fanout module iterates the attrset to dispatch.

**Why rejected**: looks clean on the surface but has a real
eval-order trap. Each ecosystem's transform must accept the
full union of shared inputs (skills, instructions, lspServers,
settings, env). If a transform reads `config.ai.skills` to
compute its own option default, you can hit infinite-recursion
eval errors that are brutal to debug. Adding a new shared
input upstream silently breaks downstream transforms because
the union grows.

Per-ecosystem modules (Pattern B / Primitive 3) avoid this
because each module reads only the inputs it needs, and new
shared inputs added upstream don't affect existing ecosystem
modules.

### Alternative C: Algebras as NixOS submodules

Put transformer records into NixOS modules with `mkOption` per
node handler. Then `mkMerge` gives override semantics for free
with priority handling (`mkDefault`, `mkForce`).

**Why rejected**: overkill for what's basically a
record-of-functions. Plain attrsets + `recursiveUpdate` cover
the override cases without any module-system overhead. The only
reason to go module-based would be if multiple modules
contribute partial handlers to the same algebra — which is not
a use case anyone has asked for.

### Alternative D: Free monad / interpreter

Build an AST of "render commands," then have an interpreter
walk it.

**Why rejected**: massively overkill for Nix. Nix is pure and
lazy; closures + records give you everything monads would in
this domain, without the bind-chain readability tax. The
moment someone writes a `do`-equivalent in raw Nix, the code
becomes unmaintainable.

### Alternative E: Materialize AST to Nix store

Build the composed AST into a JSON file in the Nix store, have
per-target derivations read from it for cross-process sharing.

**Why rejected**: introduces IFD if the AST is read back into
eval (flake-check killer). Eval-level sharing via let bindings
is sufficient at the current scale (~50 fragments,
sub-millisecond compose). Only revisit if profiling shows
compose is a measurable bottleneck.

### Alternative F: Per-ecosystem option pools as ad-hoc per-module additions

Instead of declaring per-ecosystem extension points uniformly
via the backend adapter, let each ecosystem module declare its
own per-eco options ad-hoc. Some ecosystems would have
`ai.claude.mcpServers`, others wouldn't, depending on what the
ecosystem author thought useful.

**Why rejected**: this is what would happen if we didn't apply
the layered-options pattern uniformly. The result is an
inconsistent API surface — `ai.claude.mcpServers` exists but
`ai.copilot.mcpServers` doesn't, because nobody got around to
adding it yet. Consumers have to remember which ecosystems
support which extension points. Uniform declaration via the
backend adapter (option types come from `lib/ai-options.nix`,
adapter declares them at `ai.<eco>.<category>` for every
ecosystem) makes the API symmetric and predictable.

Cost is ~1 line per category in the adapter; benefit is every
ecosystem gets every extension point automatically.

### Alternative G: Use NixOS module merge directly for per-ecosystem extension

Instead of `recursiveUpdate sharedSet ecoSet` in the adapter,
declare per-ecosystem options that write back into the shared
slot via `mkMerge`, and let the module system handle the merge.

**Why rejected**: breaks isolation. If `ai.claude.mcpServers.aws`
gets written back into `ai.mcpServers.aws`, then enabling Kiro
would ALSO see the AWS entry — defeating the entire purpose of
"this entry is only for Claude." The merge has to happen
**inside** the per-ecosystem effective set, not back into the
shared pool. That requires explicit `recursiveUpdate` in the
adapter, not `mkMerge`-driven aggregation.

## Backward compatibility

The refactor preserves existing consumer-facing API:

- `ai.{skills, instructions, lspServers, settings, environmentVariables}`
  options stay the same shape and meaning.
- `ai.claude.enable`, `ai.copilot.enable`, `ai.kiro.enable`
  stay the same.
- Fragment text accepts both flat strings and node lists. Bare
  strings are wrapped as `[mkRaw text]` transparently in the
  renderer. Existing fragments continue to work without
  modification.
- `homeManagerModules.ai` stays the umbrella module that imports
  all three ecosystem modules. Existing single-import consumers
  see no change. Consumers who want only one ecosystem can
  import `homeManagerModules.ai-claude` directly, but this is
  optional.
- `pkgs.fragments-ai.passthru.transforms` stays as a thin
  compatibility shim that forwards to the new transformer
  records. Can be deprecated in a follow-up if/when no consumers
  read it.

## Estimated scope

Net new code: **~450-600 lines** across the following files
(updated for the corrected ecosystem-record framing + layered
option pools):

| File | Estimated lines | Purpose |
|---|---|---|
| `lib/fragments.nix` | +120 (existing 78 → ~200) | node constructors, `mkRenderer`, default handlers |
| `lib/ai-options.nix` | +120 (new) | source-of-truth option types: `skillsOption`, `instructionsOption`, `mcpServersOption`, `lspServersOption`, `envVarsOption`, `settingsOption` — referenced by both shared and per-eco option declarations |
| `lib/mk-ai-ecosystem-hm-module.nix` | +120 (new) | HM backend adapter — declares per-eco options, computes effective sets, dispatches to ecosystem record |
| `lib/mk-ai-ecosystem-devenv-module.nix` | +110 (new) | devenv backend adapter — same shape, different writer |
| `lib/mk-raw-ecosystem.nix` | +30 (new) | helper for orphan ecosystems (identity translators, no-op markdown handlers, all upstream null) |
| `lib/transformers/base.nix` | +30 (new) | base markdown transformer with default handlers |
| `lib/ai-ecosystems/claude.nix` | +80 (new) | claude ecosystem record (markdownTransformer, translators, layout, upstream delegation) |
| `lib/ai-ecosystems/copilot.nix` | +70 (new) | copilot ecosystem record |
| `lib/ai-ecosystems/kiro.nix` | +80 (new) | kiro ecosystem record |
| `lib/ai-ecosystems/agentsmd.nix` | +30 (new) | agentsmd ecosystem record (write-only, no fanout) |
| `packages/fragments-docs/ecosystems/readme.nix` | +40 (new) | readme ecosystem record with GH URL link rewriting |
| `packages/fragments-docs/ecosystems/mdbook.nix` | +30 (new) | mdbook ecosystem record with native include |
| `modules/ai/default.nix` | -250 (replaced by adapter calls) | thin importer that wires ecosystem records through `mkAiEcosystemHmModule` |
| `modules/devenv/ai.nix` | -200 (replaced by adapter calls) | thin importer that wires ecosystem records through `mkAiEcosystemDevenvModule` |
| `dev/generate.nix` | -30 (3x → 1x compose, uses ecosystem records) | use shared composedByPackage and ecosystem records' markdownTransformer |
| `packages/fragments-ai/default.nix` | -50 (records moved to lib/ai-ecosystems/) | thin shim providing `passthru.composedByPackage` + backward-compat transforms |

Net: ~860 lines added (new files) - ~530 lines removed (modules
and packages shrink) = **~330 net lines added**, with significant
restructuring. The larger absolute count reflects:

1. The ecosystem record carries more than just the markdown
   transformer (translators, layout, upstream delegation fields).
2. Two separate backend adapters instead of one helper.
3. The `lib/ai-options.nix` source-of-truth file is new (the
   adapters reference it for type-safe per-eco option declaration).
4. The layered option pools pattern means more fanout code per
   adapter (six categories × dispatch logic each) but it's all
   data-driven from the ecosystem record.

The large absolute file movement makes this best executed as a
multi-commit stack with tested checkpoints. Total file count:
~12 new files, ~6 modified files.

## Sequencing (when this is ready to execute)

This is **not the next thing to do**. The sentinel→main merge
is the priority. Then nixos-config integration. Only after both
are stable should this refactor start. Suggested sequence when
the time comes:

1. **Standalone fix**: collapse `dev/generate.nix` 3x → 1x
   compose bug. ~15 lines, no architecture change. Can land
   today, independent of everything else.
2. **Spec**: write `docs/superpowers/specs/<date>-ai-ecosystem-records-design.md`
   from this note (turn it into a proper spec via the
   brainstorming skill).
3. **Plan**: write `docs/superpowers/plans/<date>-ai-ecosystem-records-impl.md`
   that breaks the refactor into a stack of commits, each
   independently testable. Likely shape:
   - **Commit 1**: introduce `lib/fragments.nix` node
     constructors + `mkRenderer` (additive, no consumer
     changes). Backward-compat: bare strings still work as
     `[mkRaw text]`. Tests against fixture fragments.
   - **Commit 2**: introduce `lib/ai-options.nix` source-of-truth
     option types. Refactor existing `modules/ai/default.nix`
     to import its option types from this file (no behavior
     change, prep for adapter use).
   - **Commit 3**: introduce `lib/transformers/base.nix` +
     `lib/ai-ecosystems/{claude,copilot,kiro,agentsmd}.nix`
     ecosystem records. Add compatibility shim in
     `pkgs.fragments-ai.passthru.transforms` that calls into
     the new records. Existing consumers unchanged.
   - **Commit 4**: add `pkgs.fragments-ai.passthru.composedByPackage`
     binding and refactor `dev/generate.nix` to use it. This
     is the 3x→1x fix generalized to a shared binding accessible
     from HM and devenv modules.
   - **Commit 5**: introduce `lib/mk-ai-ecosystem-hm-module.nix`
     adapter. Test in isolation by generating a Claude module
     from the ecosystem record and comparing against current
     `modules/ai/default.nix` Claude branch output (golden
     test).
   - **Commit 6**: replace the Claude branch in
     `modules/ai/default.nix` with `mkAiEcosystemHmModule
     claudeRecord`. Verify byte-identical output via the
     existing module-eval check.
   - **Commit 7**: same for Copilot branch.
   - **Commit 8**: same for Kiro branch.
   - **Commit 9**: introduce per-ecosystem option pools
     (`ai.<eco>.<category>` extension points). All categories
     declared via the adapter from `lib/ai-options.nix`. Tests:
     verify that `ai.kiro.mcpServers.aws = ...` adds AWS only
     to Kiro, not Claude.
   - **Commit 10**: introduce `lib/mk-ai-ecosystem-devenv-module.nix`
     and refactor `modules/devenv/ai.nix` analogously.
   - **Commit 11**: introduce `lib/mk-raw-ecosystem.nix`
     helper.
   - **Commit 12**: add a worked downstream example
     (`examples/external-ecosystem/`) that demonstrates a
     downstream flake registering a new orphan ecosystem
     using `mkAiEcosystemHmModule` + `mkAiEcosystemDevenvModule`
     directly, plus a second example using `mkRawEcosystem`
     for the minimal-effort case.
   - **Commit 13**: introduce README and mdBook ecosystem
     records (`packages/fragments-docs/ecosystems/`) and wire
     them into `dev/generate.nix` to replace the existing
     hand-rolled README/CONTRIBUTING generation. Validates
     the design works for non-AI targets.
   - **Commit 14**: update architecture fragments to document
     the new pattern (`dev/fragments/pipeline/`,
     `dev/fragments/ai-skills/`, plus a new
     `dev/fragments/ai-ecosystems/` if the topic is large
     enough).
4. **Execute** via `subagent-driven-development` or
   `executing-plans` skill, one commit at a time, checkpoint
   review between each. The byte-identical output checks at
   commits 6/7/8 are critical — they're the safety net that
   says "this refactor preserves behavior."

## Open questions

Things that need a decision before this becomes a spec, captured
here so they don't get lost:

1. **Backward compat for `pkgs.fragments-ai.passthru.transforms`**:
   keep the old function-based registry as a forwarding shim
   indefinitely, or deprecate after one release? Decision affects
   how aggressively we can simplify the new transforms layer.
   Lean: keep indefinitely as a thin shim that calls into the
   ecosystem records' `markdownTransformer` field. Cost is
   ~10 lines, benefit is no consumer breakage.

2. **Markdown transformer extension helper**: is plain
   `recursiveUpdate base { ... }` sufficient, or do we want a
   named `extendTransformer base { ... }` helper that gives
   extending handlers access to the base handler (`super`-call
   pattern)? The `super`-call is occasionally useful (e.g.,
   "do what claude does, but post-process the output") but
   adds API surface. Lean toward not adding it until a concrete
   use case appears.

3. **Where do README/mdBook ecosystem records live**: in
   `packages/fragments-docs/ecosystems/` (current proposal) or
   split into separate `packages/fragments-readme/` and
   `packages/fragments-mdbook/` packages? The latter is more
   granular but adds package boilerplate; the former keeps
   doc-related ecosystems together. Lean toward the former
   (single `fragments-docs` package) until there's a reason
   to split.

4. **Snippet registry**: the proposed `mkSnippet { ref }` node
   needs a registry to look up named snippets. Where does the
   registry live? Options:
   - As an attr on the markdown transformer record
     (`markdownTransformer.snippets`)
   - As a separate ctx field (`ctx.snippets`)
   - As a top-level binding in `pkgs.fragments-ai.passthru`
   The second option is most flexible (different consumers can
   provide different snippet sets without forking the
   transformer) but pushes more responsibility onto callers.
   Defer until there's a concrete snippet use case.

5. **Test surface**: should ecosystem records come with
   golden-output tests (fixture fragments + expected rendered
   output per ecosystem)? Would catch regressions when records
   are edited. Lean yes — add as part of commit 3 in the
   sequencing above. The fixture set is small (one fragment
   per ecosystem covering all node kinds) and the value of
   regression catch is high. Also use byte-identical output
   checks at commits 6/7/8 to verify the refactor preserves
   behavior — these are essentially golden tests against the
   current `modules/ai/default.nix` output.

6. **Should the adapter helpers enforce a contract on
   ecosystem records**: e.g., require all fields to be present,
   require `name` non-empty, require `configDir` to be a relative
   path not starting with `/`? Add asserts? Error messages?
   Lean toward minimal validation initially — Nix module errors
   are already pretty good when you try to read a missing field
   — and expand as we see real failure modes from downstream
   users.

7. **Layered option merge semantics for nested submodules**:
   `recursiveUpdate` does deep merge for plain attrsets but
   may not respect submodule semantics (e.g., `mkDefault` /
   `mkForce` priority). For most categories (`mcpServers`,
   `skills`, `instructions`) this is fine because entries are
   independent. For `settings` which is a submodule with nested
   fields, may need to use the module system's own merge
   instead. **TODO: prototype both approaches and pick the one
   that produces correct override behavior for
   `ai.kiro.settings.model = ...; ai.settings.model = ...`
   collision.**

8. **MCP server pattern relationship to existing
   `services.mcp-servers`**: this repo already has a separate
   `modules/mcp-servers/` module that exposes
   `services.mcp-servers.servers.*` for system-wide MCP server
   declaration with credentials and settings. The proposed
   `ai.mcpServers` is a simpler per-AI-tool fanout. Should they:
   - Coexist (current proposal): `ai.mcpServers` is a parallel
     interface for users who want simple shared MCP fanout
     without the credentials machinery.
   - Replace: `ai.mcpServers` becomes the only path, deprecating
     `services.mcp-servers`.
   - Bridge: `ai.mcpServers` accepts pointers like
     `{ from = config.services.mcp-servers.servers.github-mcp; }`
     that read from the system-wide registry.
   Lean toward coexist initially. Users with rich credential
   needs use `services.mcp-servers`; users with simple shared
   MCP fanout use `ai.mcpServers`. Bridge pattern can be added
   later if both ergonomics matter.

9. **Should ecosystem records be NixOS modules themselves**:
   the records as proposed are plain attrsets. They could
   instead be NixOS submodules with typed fields, giving
   `mkMerge` semantics for partial overrides and rich error
   reporting on malformed records. Tradeoff: more boilerplate,
   slower eval, but better error messages and type safety.
   Lean toward plain attrsets initially because (a) the records
   are mostly defined in this repo where authors know the
   shape, (b) downstream extensions tend to override single
   fields where `recursiveUpdate` is sufficient, (c) the
   fixed-point closure pattern in `mkRenderer` is awkward to
   express in module-land. Revisit if we see downstream
   confusion about record shape.

10. **Where do per-ecosystem `enable` flags for entries live**:
    for the layered-pool exclusion case
    (`ai.claude.mcpServers.git-mcp.enable = lib.mkForce false`),
    the entry needs an `enable` field. Some categories already
    have it (mcpServers via `mcpServerSubmodule`). Skills
    don't (they're plain paths). Two options:
    - Extend every category's submodule to include `enable`
      (verbose, breaks current shape)
    - Have a parallel `disabledX` set per ecosystem
      (e.g., `ai.claude.disabledSkills = [ "stack-fix" ];`)
    Lean: extend submodules where natural (mcpServers, lspServers
    already do); use parallel disable sets for plain types
    (skills, env vars).

11. **Layout policy granularity**: the ecosystem record's
    `layout` field has `instructionPath`, `skillPath`,
    `settingsPath`, `lspConfigPath`, `mcpConfigPath`. Should
    these be functions (current proposal — `name: ".claude/rules/${name}.md"`)
    or just prefix strings? Functions are more flexible
    (can encode subdirectory rules per name) but most ecosystems
    will use the trivial `name: "${prefix}/${name}.md"` form.
    Lean: keep as functions for forward compat, provide a
    `mkSimplePath prefix suffix` helper for the common case.

12. **Should `mkRawEcosystem` be a real shipped helper or
    just a documentation pattern**: ~30 lines of helper code
    is small but the use case is "I want a quick orphan
    ecosystem with no transformations." Some users will copy-
    paste an example instead. Lean: ship it. Users who want
    "register a new CLI to fan out my shared `ai.*` config"
    will appreciate the one-liner.

## What this note does NOT cover

Out of scope, documented so we don't forget what was deliberately
left out:

- **`services.mcp-servers.servers.*` deprecation**: this proposal
  introduces `ai.mcpServers` as a shared+layered fanout, but
  does NOT touch the existing `services.mcp-servers` module
  with its credential machinery and per-server typed settings.
  The two coexist (see open question 8). Migration or
  unification is a separate, larger discussion.
- **Memory / instruction file consolidation**: `ai.claude` has
  `memory.text` exposure that's separate from `ai.instructions`.
  Cleanup is an open backlog item but separate from this
  refactor. Once memory becomes a shared option category, it
  drops into the same layered-pool pattern automatically.
- **Plugin system**: nothing in this proposal touches the
  Claude Code plugin/skill installation paths. Those are
  delegated through `programs.claude-code.skills` and stay
  unchanged. If plugins eventually become an `ai.plugins`
  category, they get the layered-pool treatment for free.
- **NuschtOS / option introspection**: the design improves
  introspection (ecosystem records are plain attrsets you can
  walk), but actually wiring this into the doc site's option
  search is a separate concern.
- **Generic non-AI consumers of the fragment + ecosystem
  pattern**: the design generalizes naturally — you could
  imagine a `pkgs.fragments-something-else` with its own
  ecosystem records — but this is speculative until a second
  domain (beyond AI fanout + doc generation) shows up. The
  README/mdBook ecosystems demonstrate the pattern works for
  doc generation; that's the second consumer.
