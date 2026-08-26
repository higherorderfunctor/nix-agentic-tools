## claude-code Wrapper Chain

> **Last verified:** 2026-08-25 (commit pending — adds the `nativeSettings`
> option surface, which is now GENERATED from the binary's own settings schema
> rather than hand-declared key by key, and records that `passthru.extracted`
> moved from `runCommandLocal` to `runCommand`. The packaged version is 2.1.245,
> not 2.1.220 as this fragment claimed.) Prior: 2026-07-27 (commit pending —
> `ai.claude.plugins` became attrset-only, and re-reading upstream at
> home-manager rev `cbb77679` showed this fragment had gone stale on the
> delivery mechanism: there is no wrapper at all at the version we package.
> Prior 2026-04-15, buddy removal — anthropics/claude-code#45517.) If you touch
> `overlays/claude-code.nix`, the HM plugin integration, or the `nativeSettings`
> option surface and this fragment isn't updated in the same commit, stop and
> fix it.

Claude Code ships as a **pre-built compiled binary** (a Bun single-exec). The
base package (`overlays/claude-code.nix`) installs it directly as
`$out/bin/claude`.

### There is no wrapper on the live path

The plugin integration comes from **home-manager's** `programs.claude-code`
module (not nixpkgs'), and it has two mutually exclusive delivery paths, chosen
from the packaged Claude Code version:

- **2.1.157 and later — personal plugins, no wrapper.** Upstream sets
  `finalPackage = cfg.package`, so `$out/bin/claude` is the pre-built binary
  itself. Each plugin is symlinked as a whole directory at
  `<configDir>/skills/<name>` (yes, `skills/`, not `plugins/`) and discovered
  from there. **This is the live path** — `overlays/claude-code-sources.json`
  tracks 2.1.245.
- **2.1.76 through 2.1.156, or a package with no detectable version — the legacy
  `--plugin-dir` wrapper.** Upstream wraps the binary in a `symlinkJoin` whose
  `$out/bin/claude` is a short bash script that execs `.claude-wrapped`, passing
  one `--plugin-dir` plus its store path per plugin. Upstream warns on this
  path; strict-parser subcommands such as `claude rc` may reject the arguments.
  Below 2.1.76 an upstream assertion fails outright.

Only whole-directory symlinks work for a plugin. Recursive linking materializes
a real directory of per-file symlinks, and Claude Code's `agents/` and
`commands/` scanners accept only regular files, so every agent and command would
be silently dropped.

### `<name>` is the attribute key

`ai.claude.plugins` is an attrset (`attrsOf (either package path)`), and the key
is what upstream uses verbatim as `<name>` above. It is deliberately not derived
from the source: upstream's deprecated list form derives names with
`baseNameOf`, which turns a bare flake-input store path into an unstable
`<hash>-source` that gets renamed by every unrelated input bump. Upstream
asserts these names are unique among themselves and disjoint from skill names.

### The base package

`overlays/claude-code.nix` builds a `stdenv.mkDerivation` that fetches the
platform-specific pre-built binary from Anthropic's manifest and installs it as
`$out/bin/claude`. Per-platform sources are tracked in
`overlays/claude-code-sources.json`, managed by the package's `updateScript`.

`passthru.extracted` is a `runCommand` — deliberately NOT `runCommandLocal`.
`runCommandLocal` sets `allowSubstitutes = false`, and since this derivation's
input is `finalAttrs.finalPackage`, that made every PR and every local
`nix flake check` realize the ~390 MB binary to produce a ~90 KB JSON. Swapping
it changes the drv hash once; do not swap it back.

### The `nativeSettings` option surface is GENERATED

`ai.claude.nativeSettings` used to be a handful of hand-written options plus a
freeform JSON tail. It is now one typed option per path in the packaged binary's
OWN settings schema — ~150 top level, extracted into
`overlays/claude-code-extracted.json` by `overlays/claude-code/census.mjs` and
turned into `lib.mkOption` declarations by
`packages/claude-code/lib/generateSettingsOptions.nix`. The wiring lives in
`packages/claude-code/lib/nativeSettingsOptions.nix`, which is the ONLY place
the generated set and the hand-authored exceptions are merged.

Three things follow, and each of them is a trap if you assume the old shape:

- **The hand-authored list is now an EXCEPTION table, not the surface.** Six
  rows remain (`attribution`, `effortLevel`, `enableWorkflows`, `model`, `tui`,
  `workflowKeywordTriggerEnabled`), each for a reason the schema cannot express
  — a bool coercion, a soft enum, or prose carrying operational knowledge. Its
  key set is handed to the generator as `externalPaths`, so the generator emits
  nothing for those paths rather than being overwritten by a merge. Adding a
  typed option for a key upstream already declares is usually the WRONG move;
  the generator has it.
- **`checks/claude-settings-schema.nix` polices the tables.** A row aimed at a
  key upstream renamed, or a row present in both tables, fails `nix flake check`
  instead of quietly doing nothing.
- **A key the binary does NOT declare is a hard failure**, not a freeform
  passthrough, unless `ai.claude.allowUnrecognizedSettings` names it — Claude
  ignores an unknown settings key silently, so a typo otherwise looks applied
  and does nothing. A redundant allowlist entry is also a hard failure; see
  `packages/claude-code/lib/unrecognizedSettings.nix`.
