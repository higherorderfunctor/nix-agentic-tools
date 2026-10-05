# External workflows

> **Last verified:** 2026-10-04 — independent source package, virtual peers,
> shared top-level package links, native dependency fixups, and credential-free
> CI smoke of evaluated backend delivery.

`pkgs.ai.kimchiExtensions.kimchi-workflows` is built from the commit and release
in `workflows-sources.json`, independently of Kimchi's lock. Its owner-local
update target and `updateScript` resolve the release tag to a commit, refresh
the source hash and fix the pnpm dependency hash. The build uses
`pkgs.ai.generic.pnpm_10`, stamps upstream's placeholder version, generates
distribution metadata, and compiles TypeScript. No prebuilt npm distribution is
substituted. Metadata formatting uses `BIOME_BINARY` to select Nixpkgs' Biome
instead of npm's unpatched Linux executable. The locked Biome 2.5.6 and Nixpkgs
2.5.14 produce identical distribution metadata at this pin; the build generates
that file before TypeScript and does not run `dist:check`. Linux fixup uses
`autoPatchelfHook` and the compiler runtime for Vitest's Rolldown and Lightning
CSS native bindings in the installed runtime graph. TypeScript 7's Linux
compiler is static and needs no ELF fixup. Darwin selects native Mach-O
dependencies and does not use the Linux hook.

The installed package has `package.json` with `pi.extensions`, `src/`, `dist/`,
`bin/`, docs and examples. Its `node_modules` holds the locked runtime
dependency closure, including TypeScript and Vitest because the workflow
verification path uses them. The installation helper copies dependencies and
their dependency/peer links once per physical package, without development
dependencies or a network install. Pi and typebox peers are omitted from that
graph: Kimchi's compiled pi loader supplies those specifiers as virtual modules,
including typebox subpaths. The extension's root manifest retains its peer
declarations and source entry. See the
[pinned workflows manifest](https://github.com/getkimchi/kimchi-workflows/blob/7a6765ccc4aa417f38cecce1216dd8dcd3b9fab7/package.json).

Declare the package with:

```nix
ai.kimchi.extensions.workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
```

`extensions` is a free-form map of derivations, empty by default. Each key names
a directory link under the harness: Home Manager delivers
`<configDir>/harness/extensions/<key>` and devenv delivers
`<project>/.config/kimchi/harness/extensions/<key>`. The existing
`ai.kimchi.files` writer retains each package's store context. The shared
`lib.ai.linkDirectory pkgs name source` builder supplies a tiny directory of
absolute top-level links into the package, so generated-tree delivery copies
only links and leaves the dependency payload in its original store path. Harness
settings load those links through `packages = [ "extensions/<key>" ];`, sorted
by key, alongside raw `native.harnessSettings.packages` entries. Pi reads the
package manifest's `pi.extensions`; Nix carries no extension entry metadata.
Removing a key withdraws its link and settings entry. Delivery requires
`ai.kimchi.enable`. Devenv's project settings engage the existing exact-cwd
launcher guard and require project approval.

Pi 0.85.1 resolves local package sources from its agent directory for user scope
and `<cwd>/<CONFIG_DIR_NAME>` for project scope
(`dist/core/package-manager.js:981-993,1048-1062,1785-1799`). Its path resolver
normalizes paths without resolving symlinks (`dist/utils/paths.js:82-86`).
Kimchi 1.5.1 discovers a Plugins row from each configured package
(`src/resources/package-resources.ts:19-31,85-94`). Its disable filter matches
both package paths and the original metadata source string before extension
loading (`src/extensions/pi-package-lookup/native-compat.ts:151-159,277-284`),
so the directory link preserves the package toggle. Resource overrides remain
user scope even for project packages (`src/resources/store.ts:9-12,37-44`): Home
Manager can declare the row's id under `native.harnessSettings.resources`;
devenv cannot disable a user resource.

`externalized-extensions.nix` is the one list the package's exact-match patch
consumes. For workflows it removes
[the static import and managed factory](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/cli.ts)
and
[the resource definition](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/resources/definitions.ts).
The
[resource filter](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/resources/filter.ts)
only filters factories passed to it; the definition describes the menu/toggle.
After removal it cannot control anything, so leaving it would expose a dead
switch. Pi's package loader reads the manifest and Kimchi discovers the package
resource row independently. Other Kimchi extensions and dependencies keep their
upstream behavior; the original lockfile is left intact.

CI builds both packages on Linux and Darwin through package discovery. Checks:

- `kimchi-workflows-source` runs the same exact substitutions on the two source
  files and rejects leftover registrations, without compiling Kimchi.
- `kimchi-workflows-payload` checks the installed entries, pin identity,
  manifest and runtime roots, including absent virtual peers.
- `module-kimchi-external-workflows` checks both backends: empty delivery, one
  and two package links with store context, raw package composition, and
  rejection of strings as extension packages.
- `kimchi-workflows-smoke` launches patched Kimchi with global and approved
  project scopes using the generated extension directories from the same
  evaluated modules as the structural check. It verifies every top-level entry
  links into the original package and installs Home Manager's serialized
  shared-settings declaration or devenv's rendered harness settings. It checks
  the Plugins package row, `/workflow list` dispatch with zero model turns, and
  absence of `/workflow` when that row's resource id is disabled in user
  settings. An absent-package control also consumes unknown input before model
  dispatch. Fresh HOME/XDG paths isolate resource and credential state; each
  process has a 60-second deadline.

The smoke is feasible offline because slash commands dispatch before credential
validation and these cases need no model. It still must pass in CI's Nix
sandbox: the operator's external-entry and settings probes proved loading and
model-backed workflow completion in the real environment, not this patched
build's sandbox behavior. No local compile or Kimchi execution is part of this
change's validation.
