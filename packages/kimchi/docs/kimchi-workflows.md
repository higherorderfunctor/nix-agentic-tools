# External workflows

> **Last verified:** 2026-10-04 — independent source package, virtual peers,
> shared Home Manager/devenv extension settings, native dependency fixups, and
> credential-free CI smoke.

`pkgs.ai.kimchi-workflows` is built from the commit and release in
`workflows-sources.json`, independently of Kimchi's lock. Its owner-local update
target and `updateScript` resolve the release tag to a commit, refresh the
source hash and fix the pnpm dependency hash. The build uses
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

`ai.kimchi.extensions.workflows.enable = true` adds the store entry
`<kimchi-workflows>/src/host/extension.ts` to harness `extensions`. The existing
settings delivery writes the user harness file with Home Manager and the trusted
project harness file with devenv; the entry's string context retains the
package. Both backends default to disabled and merge other declared extensions.
Devenv's project settings also engage its existing exact-cwd launcher guard. The
option requires `ai.kimchi.enable` for delivery, just like the other Kimchi
options.

`externalized-extensions.nix` is the one list the package's exact-match patch
consumes. For workflows it removes
[the static import and managed factory](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/cli.ts)
and
[the resource definition](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/resources/definitions.ts).
The
[resource filter](https://github.com/getkimchi/kimchi/blob/v1.5.1/src/resources/filter.ts)
only filters factories passed to it; the definition describes the menu/toggle.
After removal it cannot control anything, so leaving it would expose a dead
switch. Pi's separate settings extension loader needs neither registration nor
resource metadata. Other Kimchi extensions and dependencies keep their upstream
behavior; the original lockfile is left intact.

CI builds both packages on Linux and Darwin through package discovery. Checks:

- `kimchi-workflows-source` runs the same exact substitutions on the two source
  files and rejects leftover registrations, without compiling Kimchi.
- `kimchi-workflows-payload` checks the installed entries, pin identity,
  manifest and runtime roots, including absent virtual peers.
- `module-kimchi-external-workflows` checks both backends: enabled entry with
  store context, consumer-entry composition, and disabled entry absent.
- `kimchi-workflows-smoke` launches patched Kimchi with global and project
  `extensions` settings and an absent-extension control. It observes exact
  command provenance and `/workflow list` dispatch, and asserts zero model
  turns. Fresh HOME/XDG paths and empty inherited resource/credential state keep
  it credential-free. A missing command is consumed by the observer before model
  dispatch. The 60-second deadline and diagnostics/counter checks catch failures
  that a session-header-only success would miss.

The smoke is feasible offline because slash commands dispatch before credential
validation and these cases need no model. It still must pass in CI's Nix
sandbox: the operator's external-entry and settings probes proved loading and
model-backed workflow completion in the real environment, not this patched
build's sandbox behavior. No local compile or Kimchi execution is part of this
change's validation.
