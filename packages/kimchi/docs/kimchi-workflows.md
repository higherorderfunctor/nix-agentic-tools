# External workflows

> **Last verified:** 2026-10-08 — per-step native thinking is always patched
> into the installed extension and covered by offline build checks; the docs
> skill reads that same output.

`pkgs.ai.kimchiExtensions.kimchi-workflows` is built from the commit and release
in `workflows-sources.json`, independently of Kimchi's lock. Its owner-local
update target and `updateScript` resolve the release tag to a commit, refresh
the source hash and fix the pnpm dependency hash. The build uses
`pkgs.ai.generic.pnpm_10`, stamps upstream's placeholder version, generates
distribution metadata, and compiles TypeScript. Metadata formatting uses
`BIOME_BINARY` to select Nixpkgs' Biome instead of npm's unpatched Linux
executable. Linux fixup uses `autoPatchelfHook` and the compiler runtime for
Vitest's Rolldown and Lightning CSS native bindings in the installed runtime
graph. TypeScript 7's Linux compiler is static and needs no ELF fixup. Darwin
selects native Mach-O dependencies and does not use the Linux hook.

The installed package has `package.json` with `pi.extensions`, `src/`, `dist/`,
`bin/`, docs and examples. Its `node_modules` holds the locked runtime
dependency closure, including TypeScript and Vitest because the workflow
verification path uses them. The installation helper copies dependencies and
their dependency/peer links once per physical package, without development
dependencies or a network install. Packages named by pi’s literal
`VIRTUAL_MODULES` keys are omitted from that graph: the extractor collapses
subpaths to npm package names in `extracted.json.virtualPackages`, consumed
through `lib/extracted.nix`. The installer checks every manifest extension entry
exists inside the output and every `node_modules` symlink resolves inside it.
The extension's root manifest retains its peer declarations and source entry.
See the
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
The offline install check uses a scripted installer and the actual installed
framework after runtime dependency pruning, then typechecks and evaluates a
workflow declaring `thinking` without executing its agents.

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
by key, alongside raw `native.harnessSettings.packages` entries. Under Home
Manager, a non-empty `extensions` map or any `native.harnessSettings.packages`
declaration owns the whole harness `packages` list, replacing packages added
with `kimchi install` on activation; declare those packages in
`native.harnessSettings.packages`. Pi reads the package manifest's
`pi.extensions`; Nix carries no extension entry metadata. Removing a key
withdraws its link and settings entry. Delivery requires `ai.kimchi.enable`.
Devenv's project settings engage the existing exact-cwd launcher guard and load
only in a trusted project: pi drops untrusted project settings
(`dist/core/settings-manager.js:189`), and Home Manager's
`defaultProjectTrust = "never"` never prompts. Trust the root with
`ai.kimchi.projectTrust."<abs dir>" = true` (or `--approve` per session). Kimchi
still lists an untrusted project package as an enabled Plugins row, because its
discovery builds settings with trust defaulted on
(`src/resources/package-resources.ts:36`).

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
