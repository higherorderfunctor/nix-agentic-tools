## claude-code Package and Plugin Delivery

> **Last verified:** 2026-10-04 — the settings extractor follows Claude
> 2.1.286's one-hop whole-schema wrapper when the `$schema` description lives in
> its descriptor factory. `ai.*` delivers Claude's plugins itself: the MCP/LSP
> personal plugin as per-file links under `home-manager/`, consumer plugins as
> one directory link each. `$out/bin/claude` is the unwrapped binary. Enabling
> the backend's own Claude module beside `ai.claude` fails evaluation.
>
> Full lineage:
> `git show 6d2fbeef:packages/claude-code/docs/claude-code-wrapper.md`.

Claude Code ships as a **pre-built compiled binary** (a Bun single-exec). The
base package (`packages/claude-code/packages/ai/claude-code/package.nix`)
installs it directly as `$out/bin/claude`.

### There is no wrapper

`$out/bin/claude` is the pre-built binary itself, installed by the shared
backend transform on both backends. Claude Code 2.1.157 and later discovers a
plugin as a personal plugin at `<configDir>/skills/<name>` (yes, `skills/`, not
`plugins/`), so nothing needs a `--plugin-dir` argument. Home Manager's own
Claude module wraps the binary for older versions; `ai.*` does not use that
module and does not port the wrapper, so a package override older than 2.1.157
loses personal plugins.

The two cannot run side by side. With `ai.claude.enable` on, Home Manager's
`programs.claude-code.enable` or devenv's `claude.code.enable` fails evaluation
with an assertion: both modules write Claude's files, and they cannot share
them. The lookup goes through `lib.attrByPath` with a `false` default, so a
configuration that never imported the upstream module still evaluates.

Two kinds of plugin land there, both Home Manager only (personal plugins are
user-scope):

- **The MCP/LSP personal plugin** at `~/.claude/skills/home-manager/`: a real
  directory of per-file links to `.claude-plugin/plugin.json`, `.mcp.json` and
  `.lsp.json`, emitted only when MCP or LSP servers exist. A plugin is Claude's
  only user-scope LSP route. The manifest name is `hm`, which is the MCP tool
  namespace (`mcp__plugin_hm_<server>__<tool>`), so the directory name can
  change without renaming any tool.
- **Consumer plugins** (`ai.claude.plugins`) via `mkPluginEntry` in
  `packages/claude-code/lib/plugin.nix`, each ONE directory link. Only
  whole-directory links work for these: recursive linking materializes a real
  directory of per-file symlinks, and Claude Code's `agents/` and `commands/`
  scanners accept only regular files, so every agent and command would be
  silently dropped. `mkPluginEntry` uses the shared `lib/link-directory.nix`
  builder (exported as `lib.ai.linkDirectory pkgs name source`) for top-level
  links and synthesizes `.claude-plugin/plugin.json` when the source has none.

### `<name>` is the attribute key

`ai.claude.plugins` is an attrset (`attrsOf (either package path)`), and the key
is used verbatim as `<name>` above and as a synthesized manifest's `name`. It is
deliberately not derived from the source: `baseNameOf` turns a bare flake-input
store path into an unstable `<hash>-source` that gets renamed by every unrelated
input bump. An assertion keeps the keys disjoint from skill names and from
`home-manager`.

### The base package

`packages/claude-code/packages/ai/claude-code/package.nix` builds a
`stdenv.mkDerivation` that fetches the platform-specific pre-built binary from
Anthropic's manifest and installs it as `$out/bin/claude`. Per-platform sources
are tracked in `packages/claude-code/sources.json`, managed by the package's
`updateScript`.

`passthru.extracted` is a `runCommand` — deliberately NOT `runCommandLocal`.
`runCommandLocal` sets `allowSubstitutes = false`, and since this derivation's
input is `finalAttrs.finalPackage`, that made every PR and every local
`nix flake check` realize the ~390 MB binary to produce a ~90 KB JSON. Swapping
it changes the drv hash once; do not swap it back.

The extractor confirms the settings builder through independent schema-emitter
and `$schema`-description anchors. The description may sit in the builder
itself, or in a descriptor factory called by exactly one wrapper that constructs
the schema and returns `.whole()`. More than one matching wrapper is ambiguous
and stops extraction.

### The `native.settings` option surface is GENERATED

`ai.claude.native.settings` used to be a handful of hand-written options plus a
freeform JSON tail. It is now one typed option per path in the packaged binary's
OWN settings schema — ~150 top level, extracted into
`packages/claude-code/extracted.json` by
`packages/claude-code/extract/census.mjs` and turned into `lib.mkOption`
declarations by `packages/claude-code/lib/generateSettingsOptions.nix`. The
wiring lives in `packages/claude-code/lib/nativeOptions.nix`, which is the ONLY
place the generated set and the hand-authored exceptions are merged.

Three things follow, and each of them is a trap if you assume the old shape:

- **The hand-authored list is now an EXCEPTION table, not the surface.** Six
  rows remain (`attribution`, `effortLevel`, `enableWorkflows`, `model`, `tui`,
  `workflowKeywordTriggerEnabled`), each for a reason the schema cannot express
  — a bool coercion, a soft enum, or prose carrying operational knowledge. Its
  key set is handed to the generator as `externalPaths`, so the generator emits
  nothing for those paths rather than being overwritten by a merge. Adding a
  typed option for a key upstream already declares is usually the WRONG move;
  the generator has it.
- **`packages/claude-code/checks/claude-settings-schema.nix` polices the
  tables.** A row aimed at a key upstream renamed, or a row present in both
  tables, fails `nix flake check` instead of quietly doing nothing.
- **A key the binary does NOT declare is a hard failure**, not a freeform
  passthrough, unless `ai.claude.allowUnrecognizedSettings` names it — Claude
  ignores an unknown settings key silently, so a typo otherwise looks applied
  and does nothing. A redundant allowlist entry is also a hard failure; see
  `packages/claude-code/lib/unrecognizedSettings.nix`.
