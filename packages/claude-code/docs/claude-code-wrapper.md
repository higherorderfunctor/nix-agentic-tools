## claude-code Package and Plugin Delivery

> **Last verified:** 2026-10-30 — settings env defaults auto-update off on both
> backends when Nix installs the binary; a selected proxy wraps the binary and
> suppresses the inherited API-key descriptor before Claude caches it; plugins
> are staged entries delivered through the ai-module files layers; the personal
> plugin carries MCP servers only; unknown native settings and stale warning
> suppressions use the generic open-keys inspector on both backends; settings
> are generated from the committed facts in packages/claude-code/extracted/,
> measured once on Linux; Darwin validates its own extraction against that raw.
> The schema check gates stale and shadowed rows, missing paths and wildcard
> grammar. Catalog, retirement and launch-pin facts are content-located AST
> reads of the unpacked graph; unsupported catalog properties, retirement rows
> and launch-pin shapes fail with PROBE.
>
> Full lineage:
> `git show 6d2fbeef:packages/claude-code/docs/claude-code-wrapper.md`.

Claude Code ships as a **pre-built compiled binary** (a Bun single-exec). The
base package (`packages/claude-code/packages/ai/claude-code/package.nix`)
installs it directly as `$out/bin/claude`.

Both backends default `ai.claude.native.settings.env.DISABLE_AUTOUPDATER = "1"`
with `lib.mkDefault` when `ai.claude.package != null`: Home Manager writes user
settings, devenv writes project `.claude/settings.json`. Claude Code 2.1.312
applies user settings `env` through `assignFromAboveTheRepository` into
`process.env`; project settings also apply this key before trust because it is
in the pre-trust safe set. Its updater reads `process.env.DISABLE_AUTOUPDATER`
(static inspection of the pinned binary). A Nix-installed binary therefore
always gets a settings document; with `ai.claude.package = null` the default is
omitted and, with nothing else declared, no document is written. Set
`ai.claude.native.settings.env.DISABLE_AUTOUPDATER = "0"` to re-enable updates.
With a proxy selected, also set
`ai.claude.native.settings.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = ""`,
since that variable independently disables updates.

### Proxy credential suppression at launch

The base package's `$out/bin/claude` is the pre-built binary itself. Without a
proxy selection it is installed bare. A selection (`ai.settings.inference` or
`ai.claude.settings.inference`) that resolves to a `cliproxyapi` backend
installs the `claude-code-inference` launcher on both backends to unset
`CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` before exec; the flag comes from that
backend's lowering, so another backend's selection leaves the package unchanged
unless its lowering asks for launcher flags. Claude Code 2.1.302 caches that
descriptor before settings env applies, so clearing it in settings alone still
sends the inherited key to the proxy. The endpoint and reference-reading
`apiKeyHelper` stay in settings; no key is baked into the launcher.

Claude Code 2.1.157 and later discovers a plugin as a personal plugin at
`<configDir>/skills/<name>` (yes, `skills/`, not `plugins/`), so nothing needs a
`--plugin-dir` argument. Home Manager's own Claude module wraps the binary for
older versions; `ai.*` does not use that module or port its plugin wrapper, so a
package override older than 2.1.157 loses personal plugins.

The two cannot run side by side. With `ai.claude.enable` on, Home Manager's
`programs.claude-code.enable` or devenv's `claude.code.enable` fails evaluation
with an assertion: both modules write Claude's files, and they cannot share
them. The lookup goes through `lib.attrByPath` with a `false` default, so a
configuration that never imported the upstream module still evaluates.

Two kinds of plugin land there, both Home Manager only (personal plugins are
user-scope):

- **The MCP personal plugin** at `~/.claude/skills/home-manager/`: a real
  directory of per-file links to `.claude-plugin/plugin.json` and `.mcp.json`,
  emitted only when MCP servers exist. The manifest name is `hm`, which is the
  MCP tool namespace (`mcp__plugin_hm_<server>__<tool>`), so the directory name
  can change without renaming any tool.
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
input is the host's pinned release binary, that would make every PR and every
local `nix flake check` realize the ~390 MB binary to produce a ~90 KB JSON.
Swapping it changes the drv hash once; do not swap it back.

The extractor confirms the settings builder through independent schema-emitter
and `$schema`-description anchors. The description may sit in the builder
itself, or in a descriptor factory called by exactly one wrapper that constructs
the schema and returns `.whole()`. More than one matching wrapper is ambiguous
and stops extraction.

Catalog aliases come from one array of literal `id`/`family` objects, never
`provider_ids.first_party`. Announced retirement-table membership removes an
alias without consulting a clock. Launch-pin keys require a negated dot-property
guard and a single-argument push of a literal Claude model id, either as the
whole body or first in the shipped three-statement block: that literal push, one
single-declaration variable statement, then an else-less `if` whose body is one
single-argument push to the same receiver. The reader checks that shape, not the
tail's values: the binding and the pushed expression are not inspected, so a
literal in the tail push is accepted and never counted as a pin. Any other
guard/body shape naming an `unpin…LaunchEffort` token is refused with PROBE
naming that token, even beside a supported pin. Each site must occupy exactly
one content-located chunk; missing or ambiguous sites fail as LOCATION errors.
Computed properties and spreads in located catalog entries fail with PROBE;
every located retirement row must have a literal `modelName` and object
`retirementDates`, or PROBE names its row key. The AST reader refuses malformed
catalogs and requires surviving haiku, opus and sonnet ids, so a non-empty stray
match cannot collapse the option enum silently. The locator fixture gate tests
structural decoys as well as the pinned-binary drift check.

### The `native.settings` option surface is GENERATED

`ai.claude.native.settings` used to be a handful of hand-written options plus a
freeform JSON tail. It is now one typed option per path in the packaged binary's
OWN settings schema — ~150 top level, extracted into
`packages/claude-code/extracted/` (the `settings.paths` fact) by
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
  tables, fails `nix flake check` instead of quietly doing nothing. It also
  checks missing schema paths and the wildcard grammar that could lose typing.
- **A key the binary does not declare passes through with a warning.** The
  shared `lib/open-keys` inspector suggests nearby declared names on both
  backends. `ai.claude.allowUnrecognizedSettings` suppresses selected dotted
  paths, including wildcard map entries; redundant entries warn as stale.
  Inspection runs after null filtering, so unset typed defaults never warn.
  Opaque schema leaves remain open, while maps and lists inspect the declared
  shape below their arbitrary entry names or elements. Unknown-key warnings do
  not weaken separate credential or ownership refusals.
