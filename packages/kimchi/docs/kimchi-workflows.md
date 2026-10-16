# External workflows

> **Last verified:** 2026-10-16 — upstream selects the NAT pnpm major; build and
> runtime use that derivation, with stamped metadata and noninteractive
> generated dependency migration. Extension links stage in `_generatedFiles` and
> reach both backends through the files layers, retaining package store context;
> configured packages use project precedence and live outside auto-discovery.

`pkgs.ai.kimchiExtensions.kimchi-workflows` is built from the commit and release
in `workflows-sources.json`, independently of Kimchi's lock. Its owner-local
update target and `updateScript` resolve the release tag to a commit, refresh
the source hash and fix the pnpm dependency hash. The build reads upstream's
`kimchiWorkflows.packageManager` (falling back to `packageManager`) from that
pinned source and selects `pkgs.ai.generic.pnpm_<major>`. An unavailable major
fails evaluation with the requested pin and missing attribute. The selected NAT
derivation supplies `fetchPnpmDeps`, the build, and the runtime
installer/verifier. Before generating distribution metadata, the build stamps
both manifest package-manager fields to that derivation's exact version,
together with the release version. TypeScript compilation then carries the same
pin in source and compiled metadata. Metadata formatting uses `BIOME_BINARY` to
select Nixpkgs' Biome instead of npm's unpatched Linux executable. Linux fixup
uses `autoPatchelfHook` and the compiler runtime for Vitest's Rolldown and
Lightning CSS native bindings in the installed runtime graph. TypeScript 7's
Linux compiler is static and needs no ELF fixup. Darwin selects native Mach-O
dependencies and does not use the Linux hook.

The installed package has `package.json` with `pi.extensions`, `src/`, `dist/`,
`bin/`, docs and examples. Its `node_modules` holds the locked runtime
dependency closure, including TypeScript and Vitest because the workflow
verification path uses them. The installation helper copies dependencies and
their dependency/peer links once per physical package, without development
dependencies or a network install. Packages named by pi’s literal
`VIRTUAL_MODULES` keys are omitted from that graph: the extractor collapses
subpaths to npm package names in `packages/kimchi/extracted/` under the
`virtualPackages` key, read directly through `lib.extracted.get`. The installer
checks every manifest extension entry exists inside the output and every
`node_modules` symlink resolves inside it. The extension's root manifest retains
its peer declarations and source entry. See the
[pinned workflows manifest](https://github.com/getkimchi/kimchi-workflows/blob/7a6765ccc4aa417f38cecce1216dd8dcd3b9fab7/package.json).

The package always applies `step-thinking.patch`; there is one installed
variant. `createAgentStep({ thinking: "high", ... })` accepts PI's native
thinking levels (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`).
Each background or statically isolated worker gets an explicit `--thinking`
argument, including repair and resume calls. Foreground steps set thinking after
model selection and restore that model's initial thinking level on disposal.
Omission leaves native session/default behavior unchanged. PI still clamps
levels to model capabilities; this controls the client's requested reasoning
level, not gateway enforcement.

The supported host baseline is PI >=0.85.1, whose public setter does not persist
defaults. Earlier setters write global preferences and are unsupported. The
packaged host uses PI 0.85.1. The build runs generated API document checks,
TypeScript checks, and the focused offline thinking regressions. These use
scripted hosts and the upstream 0.84.1 development type declarations; they make
no inference calls. The unchanged wildcard peer range does not enforce the host
baseline: native virtual module aliases select the running harness's SDK. The
opt-in docs skill links this installed package, including its patched source and
generated authoring reference.

`native-preflight.patch` binds the central project workflow package's managed
framework dependency to `file:<this installed output>`. Native run/resume
preparation and local preflight therefore use the same patched API as the
injected extension, instead of replacing it with upstream npm 0.0.9. The package
substitutes its final output path during `postPatch`; no extra package variant,
environment selector, or user configuration is required. Ordinary project
preparation may still fetch its existing toolchain dependencies through pnpm.
`pnpm-runtime.patch` replaces upstream's Corepack/PATH/npm fallback with the
absolute store path of a Nix launcher for the selected pnpm. Node's version
probe also uses an absolute store executable. The launcher puts NAT Node and the
shell utilities used by pnpm's generated executable shims ahead of consumer
PATH, covering API calls and printed retry/verification commands. The existing
exported-overlay contract keeps this toolchain on NAT's nixpkgs unless the
consumer explicitly sets `follows` (or uses an unsupported-platform fallback).

The workflow install alone passes `--config.confirmModulesPurge=false`: pnpm can
recreate incompatible generated `node_modules` without a TTY after an earlier
pnpm major created them. This does not set global CI behavior or remove workflow
source files. The offline package-manager regression runs production preparation
with local fixture dependencies, hostile PATH tools, and an incompatible modules
manifest; it checks the exact metadata pin, actual pnpm installation, Node-based
verification, and preservation of a sibling user file.

The offline install check uses a scripted installer and the actual installed
framework after runtime dependency pruning, then typechecks and evaluates a
workflow declaring `thinking` without executing its agents.

Declare the package with:

```nix
ai.kimchi.extensions.workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
```

`extensions` is a free-form map of derivations, empty by default. Each key names
a directory link under the harness: Home Manager delivers
`<configDir>/harness/packages/<key>` and devenv delivers
`<project>/.config/kimchi/harness/packages/<key>`. Each link stages in
`ai.kimchi._generatedFiles` with `method = "symlink"` and reaches both backends
through `ai.kimchi.files` and `ai.files`, retaining each package's store
context. The shared `lib.ai.linkDirectory pkgs name source` builder supplies a
tiny directory of absolute top-level links into the package, so generated-tree
delivery copies only links and leaves the dependency payload in its original
store path. Harness settings load those links through
`packages = [ "packages/<key>" ];`, sorted by key, alongside raw
`native.harnessSettings.packages` entries. Under Home Manager, a non-empty
`extensions` map or any `native.harnessSettings.packages` declaration owns the
whole harness `packages` list, replacing packages added with `kimchi install` on
activation; declare those packages in `native.harnessSettings.packages`. Pi
reads the package manifest's `pi.extensions`; Nix carries no extension entry
metadata. Removing a key withdraws its link and settings entry. The `packages/`
directory is outside all PI auto-discovery roots: harness `extensions/`,
`skills/`, `prompts/` and `themes/`, plus user and ancestor `.agents/skills/`.
The configured package is therefore the only load path. Previous
`extensions/<key>` links retire through the existing backend state: Home
Manager's generation cleanup removes links absent from the new `home-files`
tree; devenv's `files.json` cleanup removes retired store symlinks before
creating the new entries. This covers both a rename and removing all extension
declarations; neither needs a new migration writer. Delivery requires
`ai.kimchi.enable`. Devenv's project settings engage the existing exact-cwd
launcher guard and load only in a trusted project: pi drops untrusted project
settings (`dist/core/settings-manager.js:189`), and Home Manager's
`defaultProjectTrust = "never"` never prompts. Trust the root with
`ai.kimchi.projectTrust."<abs dir>" = true` (or `--approve` per session). Kimchi
still lists an untrusted project package as an enabled Plugins row, because its
discovery builds settings with trust defaulted on
(`src/resources/package-resources.ts:36`).

Pi 0.85.1 resolves local package sources from its agent directory for user scope
and `<cwd>/<CONFIG_DIR_NAME>` for project scope
(`dist/core/package-manager.js:981-993,1048-1062,1785-1799`). Its path resolver
normalizes paths without resolving symlinks (`dist/utils/paths.js:82-86`). NAT's
`package-identity.patch` gives a local directory with a non-empty string
`package.json.name` the identity `npm:<name>`. Pi's existing deduplication then
keeps the project entry over the user entry, including a user npm installation
of that name. This removes duplicate configured-package loads that can consume
the workflow step's one-use output-tool handoff twice. Top-level extension
auto-discovery remains separate and deduplicates by real path, which is why
package links must stay outside its roots. Missing, unreadable, invalid or
unnamed manifests retain their absolute path identity; npm and git identities
are unchanged. Pi's explicit project `autoload = false` delta still keeps its
user base. Install/remove matching and Plugins row IDs remain based on source
strings/paths. Moving the delivery source changes each resource id from
`plugins.package.extensions-<key>` to `plugins.package.packages-<key>` (Kimchi
lowercases and replaces non-alphanumeric runs with `-`). Consumers must rename
any corresponding `native.harnessSettings.resources` keys or saved user toggles;
old toggle keys no longer match. For workflows the new id is
`plugins.package.packages-workflows`. Kimchi discovers a Plugins row from each
configured package (`src/resources/package-resources.ts:19-31,85-94`). Its
disable filter matches both package paths and the original metadata source
string before extension loading
(`src/extensions/pi-package-lookup/native-compat.ts:151-159,277-284`), so the
directory link preserves the package toggle. Resource overrides remain user
scope even for project packages (`src/resources/store.ts:9-12,37-44`): Home
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
upstream behavior. Before dependency fetching, `applyPatches` appends the
identity fix to upstream's existing PI patch and replaces that patch's SHA-256
throughout the lockfile, including peer references. Both pnpm consumers use that
same source. Pnpm applies the fix wherever it materializes PI; it does not
replace registry tarballs or re-resolve dependencies. A missing old hash fails
the source preparation, and an incompatible identity hunk fails installation.

CI builds both packages on Linux and Darwin through package discovery. Checks:

- `kimchi-package-identity` materializes the production source with the exact
  build pnpm and frozen offline configure hook, without compiling Kimchi. The
  pristine PI control must fail. With module-rendered Home Manager and devenv
  links/settings, both same-target and different-target payloads must resolve
  exactly one extension in the full set, from the project with its package
  source. Package exclusions must leave no enabled extension. The installed
  class must also select the project over npm, keep both unnamed packages, and
  preserve delta bases, trust checks, source persistence, listing and updates.
- `kimchi-workflows-source` runs the same exact substitutions on the two source
  files and rejects leftover registrations, without compiling Kimchi.
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
