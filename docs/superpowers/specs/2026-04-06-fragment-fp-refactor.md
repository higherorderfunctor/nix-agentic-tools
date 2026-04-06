# Fragment System FP Refactor

> Design spec for refactoring the fragment system into a target-agnostic
> core with topic-based transform packages.

## Problem

Two parallel transform systems generate ecosystem-specific frontmatter:

1. `lib/fragments.nix` `mkEcosystemContent` — hardcoded ecosystem dispatch
   map, used by the generate app and devenv file generation
2. `lib/ai-common.nix` `mkClaudeRule`/`mkKiroSteering`/`mkCopilotInstruction`
   — standalone functions, used by HM and devenv `ai.*` modules

Both do the same thing (add ecosystem frontmatter to markdown) but with
different input types and slightly different output formats. Adding new
targets (doc site generation, new ecosystems) requires modifying core
library files.

## Design Decisions

| Decision                | Choice                                                                          | Rationale                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Unify transform systems | Yes                                                                             | DRY — two codepaths for the same operation is a bug                                       |
| Transform input type    | Minimal interface `{ text, description?, paths? }`                              | Fragments and instruction submodules both satisfy it naturally                            |
| Context passing         | Curried — `transforms.claude { package = "foo"; }` returns `fragment -> string` | Keeps `render` dead simple; context baked into closure                                    |
| AGENTS.md handling      | Identity transform + caller assembly                                            | Multi-fragment page layout is a caller concern, not a transform concern                   |
| Transform location      | Core in lib, topics in packages                                                 | Core is functions-only (lib); topics bundle content + transforms (packages with passthru) |

## Architecture

### Core: `lib/fragments.nix`

Target-agnostic markdown composition. No ecosystem knowledge.

**Exports:**

```nix
{
  compose    # { fragments, description?, paths?, priority? } -> fragment
  mkFragment # { text, description?, paths?, priority? } -> fragment
  mkFrontmatter # attrs -> string (YAML frontmatter block)
  render     # { composed, transform } -> string
}
```

`render` is: `{ composed, transform }: transform composed`

That's the entire implementation. The value is in the contract: `transform`
is always `fragment -> string`, `composed` is always a fragment.

`mkFrontmatter` stays in core because it's a generic YAML utility used by
multiple topic packages. It's not ecosystem-specific.

**Removed from core:**

- `ecosystems` map (moves to `fragments-ai`)
- `mkEcosystemContent` (replaced by `render` + transforms)

### Topic Package: `packages/fragments-ai/`

AI ecosystem transforms + instruction templates.

**Overlay:** Exposed as `pkgs.fragments-ai` via the default overlay.

**Derivation:** Builds reference instruction templates showing each
ecosystem's frontmatter format.

**passthru.transforms:**

```nix
{
  claude = { package }: fragment: ...;
  # Produces: ---\ndescription: ...\npaths: ...\n---\n\n<text>
  # package: used in description field
  # fragment.paths: optional, controls paths: frontmatter
  # fragment.description: optional, overrides default description

  copilot = {}: fragment: ...;
  # Produces: ---\napplyTo: "<paths or **>"\n---\n\n<text>
  # fragment.paths: optional, controls applyTo field

  kiro = { name }: fragment: ...;
  # Produces: ---\nname: ...\ninclusion: ...\n---\n\n<text>
  # name: required, used in name: frontmatter
  # fragment.paths: optional, controls inclusion/fileMatchPattern

  agentsmd = {}: fragment: ...;
  # Produces: <text> (identity, no frontmatter)
}
```

**Internal dependency:** Imports `lib/fragments.nix` for `mkFrontmatter`,
same pattern as `coding-standards`:
`fragmentsLib = import ../../lib/fragments.nix { inherit (final) lib; };`

### Topic Package: `packages/fragments-docs/` (Phase 2+)

Not built in Phase 1. Documented here to ensure core design accommodates it.

**passthru.transforms:** `{ page, section, table, withOptions }`

**passthru.generators:** `{ optionsPage, packageTable, serverList }`

These close over nix-evaluated data (overlay attrsets, `nixosOptionsDoc`
output) and produce doc-site markdown.

### What stays in `lib/ai-common.nix`

Everything except the three frontmatter generators:

- `instructionModule` — typed NixOS submodule definition
- `lspServerModule`, `mkLspConfig`, `mkCopilotLspConfig` — LSP config
- `transformMcpServer` — MCP server JSON transform
- `filterNulls` — utility function

## Caller Migration

### `flake.nix`

**lib exports:** Replace `mkEcosystemContent`, `mkClaudeRule`,
`mkCopilotInstruction`, `mkKiroSteering` with `render`. Re-export
`fragments-ai` transforms for convenience if desired.

**generate app:** Replace `fragments.mkEcosystemContent { ecosystem; ... }`
with `fragments.render { transform = aiTransforms.<eco> {...}; composed; }`.

### `devenv.nix`

Same pattern as flake.nix generate app. `mkEcosystemFile` helper
becomes:

```nix
mkEcosystemFile = ecosystem: package: composed:
  fragments.render {
    inherit composed;
    transform = aiTransforms.${ecosystem} (
      if ecosystem == "kiro" then { name = package; }
      else if ecosystem == "agentsmd" then {}
      else if ecosystem == "copilot" then {}
      else { inherit package; }
    );
  };
```

In practice, the callers already know which ecosystem they're generating
for, so explicit calls per ecosystem are cleaner than a dispatch helper.

### `modules/ai/default.nix` and `modules/devenv/ai.nix`

Replace:

```nix
mkClaudeRule name instr
```

With:

```nix
pkgs.fragments-ai.passthru.transforms.claude { package = name; } instr
```

Same for copilot and kiro. The `instr` (instruction submodule value)
satisfies the minimal `{ text, description?, paths? }` interface.

### `modules/stacked-workflows/default.nix`

Replace:

```nix
aiCommon.mkClaudeRule "stacked-workflows" composed
aiCommon.mkCopilotInstruction "stacked-workflows" composed
aiCommon.mkKiroSteering "stacked-workflows" composed
```

With:

```nix
pkgs.fragments-ai.passthru.transforms.claude { package = "stacked-workflows"; } composed
pkgs.fragments-ai.passthru.transforms.copilot {} composed
pkgs.fragments-ai.passthru.transforms.kiro { name = "stacked-workflows"; } composed
```

## Verification

All generated instruction files must be byte-identical before and after
the refactor. Verification steps:

1. Before refactor: `nix run .#generate` and capture all output files
2. After refactor: `nix run .#generate` and diff against captured files
3. `nix flake check` — module eval checks pass
4. `devenv test` — devenv module eval passes
5. Manual: `devenv shell` and inspect generated dotfiles

## Risks

**Overlay dependency in modules.** HM and devenv modules will access
`pkgs.fragments-ai.passthru.transforms`. This requires the overlay to
be applied before module evaluation. This is already a requirement for
other overlay packages (`pkgs.nix-mcp-servers.*`,
`pkgs.coding-standards.*`), so no new constraint.

**Frontmatter format divergence.** The two current systems produce
slightly different frontmatter for the same ecosystem (e.g., `ai-common`
handles `description = ""` differently from `fragments.nix`). The
migration must reconcile these to a single output format. Byte-identical
verification will catch any divergence.

## Scope Boundary

**In scope (Phase 1):**

- `lib/fragments.nix` — add `render`, remove `ecosystems` + `mkEcosystemContent`
- `packages/fragments-ai/` — new package with transforms in passthru
- `lib/ai-common.nix` — remove 3 frontmatter generators
- 6 caller files migrated
- Byte-identical verification

**Out of scope:**

- `packages/fragments-docs/` — Phase 2+
- Doc site generation — Phase 3+
- `nixosOptionsDoc` / NuschtOS/search — Phase 4+
- Fragment content changes (coding-standards, stacked-workflows text)
- `instructionModule` type changes
- LSP/MCP transforms
