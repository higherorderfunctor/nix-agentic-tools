# External workflows

> **Last verified:** 2026-10-22 (commit d5f613ea) — the identity hunk is rebased
> onto pi 1.3.0; pnpm's bounded hunk-position search and packed-archive reverse
> checks use the released patch context; the Linux clipboard binding links
> libxcb.

`pkgs.ai.kimchiExtensions.kimchi-workflows` is built from the commit and release
in `workflows-sources.json`, independently of Kimchi's workflows dependency pin.
Its owner-local update target and `updateScript` resolve the release tag to a
commit, refresh the source hash and fix the pnpm dependency hash. Build,
dependency fetcher and runtime use `pkgs.ai.generic.pnpm_10`. `postPatch`
rejects a different upstream `kimchiWorkflows.packageManager` (falling back to
`packageManager`) major with a named build error; selecting pnpm requires no
evaluation-time read of fetched sources. The build stamps both package-manager
fields to the supplied pnpm's exact version before generating source and
compiled distribution metadata.

Every managed project dependency uses a `file:/nix/store/...tgz` spec. The
framework archive comes from this extension's installed output; TypeScript
7.0.2, Vitest 4.1.10 and `@types/node` 22.20.1 point at its copied runtime
graph. PI and pi-tui 1.3.0 and typebox 1.3.7 come from the `toolchain` passthru.
That derivation materializes Kimchi's frozen offline pnpm graph without building
Kimchi's binary. It copies the packages pnpm materializes from Kimchi's patched
source, including PI's upstream patches and NAT's package identity fix. The
pristine `extractionSources` tarballs are declaration-extraction inputs, not
workflow toolchain replacements. There is no separately maintained PI or typebox
version pin.

`install-runtime.mjs` copies each physical package once, retains its dependency
links for direct store use, and rewrites the copied manifests' runtime
dependency edges to store `file:` tarball specs. After Nix fixup has patched
native binaries and shebangs, its pack mode creates one archive per physical
package, excluding `node_modules`. The framework itself is packed too. Pnpm
unpacks archives into its temporary writable store, so its unconditional bin
chmod never operates on a read-only Nix store inode. Directory specs can retain
those inodes on Darwin even with `package-import-method=copy`; that ineffective
pin is removed. The generated `toolchain.json` supplies all seven managed
archive specs from the same graph. The framework declares PI, pi-tui and typebox
as `"*"` peers supplied by Kimchi; project verification supplies them through
the generated project's development dependencies. Copied dependency packages
omit development dependencies and peer metadata after the resolved graph is
closed; optional dependencies absent on the host platform are omitted. Native
execution still uses Kimchi's virtual modules through jiti; the physical PI
graph supplies project verification. The toolchain build reverse-checks every
applicable `patchedDependencies` hunk against freshly unpacked archive content
with zero fuzz; equal versions cannot conceal lost patches. Build-time checks
compare supplied versions with Kimchi's manifest and the framework's
peer/tooling ranges, and stamp distribution versions from those same supplied
directories. The framework compiles and runs its focused checks against that PI
toolchain. Upstream's wildcard PI peers accept the newer host; its old
development pins are fixture selections, not compatibility ranges.

The installed package includes `package.json` with `pi.extensions`, `src/`,
`dist/`, `bin/`, docs and examples. The installer checks extension entries exist
and copied dependency links remain in the output. The final package adds store
links to its PI toolchain. Metadata formatting uses `BIOME_BINARY` to select
Nixpkgs' Biome. Packed upstream patches are verified in reverse with Git using
the same whitespace matching as CodeQL staging; every hunk must apply. The host
PI toolchain also links Linux clipboard's X11 native binding against `libxcb`.
Linux fixup uses `autoPatchelfHook` and the compiler runtime for Vitest's
Rolldown and Lightning CSS bindings; Darwin selects native Mach-O dependencies.
TypeScript's native compiler needs no Linux ELF fixup.

`pi-agent-settled.patch` supplies pi 1.3's required `aborted: false` on the
upstream successful-settlement test fixture. The package always applies
`step-thinking.patch`; there is one installed variant.
`createAgentStep({ thinking: "high", ... })` accepts PI's native thinking levels
(`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`). Each background or
statically isolated worker gets an explicit `--thinking` argument, including
repair and resume calls. Foreground steps set thinking after model selection and
restore that model's initial thinking level on disposal. Omission leaves native
session/default behavior unchanged. PI still clamps levels to model
capabilities; this controls the client's requested reasoning level, not gateway
enforcement.

The supported host baseline is PI >=0.85.1, whose public setter does not persist
defaults. Earlier setters write global preferences and are unsupported. The
packaged host and verification toolchain use PI 1.3.0. The build runs generated
API document checks, TypeScript checks and focused thinking regressions without
inference calls. The opt-in docs skill links the installed package, patched
source and generated authoring reference.

`native-preflight.patch` binds the central workflow package's managed
dependencies to the installed store closure. Native run/resume preparation,
preflight and local verification therefore use the same patched framework API.
`pnpm-runtime.patch` selects an absolute store pnpm launcher and Node probe. The
launcher sets PATH to NAT Node and the shell utilities used by pnpm's executable
shims, covering API calls and printed retry/verification commands. The exported
overlay keeps this toolchain on NAT's nixpkgs unless a consumer sets `follows`
or uses an unsupported-platform fallback. Upstream recovery messages remain
untouched.

The workflow package directory belongs to Kimchi. The launcher rejects `.npmrc`,
`.pnpmfile.cjs` and `pnpm-workspace.yaml` in its target directory before
starting pnpm, naming the file. These are pnpm 10's automatic project inputs:
[npm configuration](https://pnpm.io/10.x/npmrc),
[installation hooks](https://pnpm.io/10.x/pnpmfile) and
[workspace configuration](https://pnpm.io/10.x/cli/config). Custom hook paths
and configuration dependencies require one of those refused config files or the
already-refused manifest `pnpm` settings. The generated `package.json` remains
the validated dependency/script input; `pnpm-lock.yaml` is generated
installation state.

The guard has one implementation, shared by installation, the printed
verification command and direct launcher calls. For the framework's calls, it
resolves `--dir` relative to the caller's cwd, otherwise checks cwd. It respects
the `run` script, `exec` and `--` child-argument boundaries. The version probe
uses a neutral directory without a workspace file. Every launcher invocation
prefixes `--ignore-workspace` before the caller's arguments; pnpm parses that
global option for `install`, `run` and `exec`. Ancestor workspace YAML and its
rc therefore cannot select a root manifest or provision Node.

The Node launcher filters inherited environment names matching `npm_config_`,
`pnpm_config_` and `PNPM_` without case sensitivity, including names Bash cannot
represent as variables. It retains arbitrary other caller variables because
workflow verification tests may read them (for example `CODE_REVIEW_BIN`). The
shell clears Node's loader/path overrides before starting that launcher. Fresh
temporary cache, config, data, state and pnpm-store directories prevent reads
from user caches; the shell removes them on exit. The remaining settings each
address an input that still exists:

- `cache-dir` and `store-dir` select the temporary directories instead of user
  caches. `globalconfig` and `userconfig` are `/dev/null`, refusing user/global
  npm rc files; `XDG_CONFIG_HOME` isolates pnpm's separate global rc.
- `enable-pre-post-scripts=false` and `ignore-scripts=true` refuse implicit
  hooks and lifecycle scripts in the retained project manifest; explicit
  verification scripts still run.
- `manage-package-manager-versions=false` refuses another pnpm selected by a
  manifest's `packageManager` when the launcher runs, including before a
  manifest has been refreshed by preparation.
- `offline=true` refuses registry resolution; `update-notifier=false` prevents
  pnpm's independent update request, which offline mode does not suppress.
- `script-shell` selects store Bash for manifest scripts instead of pnpm's host
  shell default.
- `use-node-version` pins the supplied Node version as defense in depth against
  any configuration source that still selects Node; pnpm skips provisioning when
  its current version matches.

The former `ignore-pnpmfile`, `registry` and `verify-deps-before-run` pins
remain redundant once project configuration, ancestor workspaces, user/global rc
and inherited configuration variables are excluded.

The project dependency graph is closed. Preparation rejects additional packages
in dependency sections, `pnpm` graph/runtime configuration and Yarn
`resolutions`, naming the offending package or setting. Managed development
entries are refreshed from the supplied toolchain. This validation also refuses
local paths and cached packages that offline mode alone would accept, and
`pnpm.executionEnv`, which could provision another Node even in offline mode.

The workflow install passes `--config.confirmModulesPurge=false` so pnpm
recreates incompatible generated `node_modules` without a TTY after another
major created them. The install-check regression calls production
`prepareWorkflowPackage` in a fresh directory with hostile PATH binaries,
offline explicitly disabled in its environment and user/global rc files that
request a foreign Node and package-manager management. It refuses project config
files at the launcher boundary, including `.npmrc` redirecting `lockfile-dir` to
another manifest's local override, and workspace YAML selecting another Node. An
ancestor workspace with that Node selection and a hostile rc file stays ignored
during installation, the exact printed verification command and `exec`. It
checks the effective production configuration, ignores a mixed-case
`Npm_Config_use_node_version`, and records zero requests to a local
registry/Node mirror. A `.npmrc` added after preparation is refused by the exact
printed verification command. The test compares every imported regular file's
device/inode against the reachable store graph and rejects project links into
the store, covering Darwin's chmod precondition on Linux. Darwin execution
remains a CI responsibility. It checks all seven managed specs, then runs the
installed `kimchi-workflows verify` to typecheck and test imports of the
framework, typebox and Kimchi's patched PI declarations (`showError`, `setModel`
options and forced compaction). It repeats preparation and real verification
after introducing a foreign pnpm layout, retaining authored files. Added
dependencies, local paths, overrides, resolutions and runtime provisioning are
rejected without network. The native preflight check separately exercises the
installed thinking API through the host loader.

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
Pnpm searches at most 20 lines around each hunk's recorded position. When a pi
bump moves the identity method farther, regenerate the NAT hunk coordinates
against the upstream-patched package. A GNU patch dry-run can succeed outside
that window, so the real pnpm materialization remains the verification.

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
