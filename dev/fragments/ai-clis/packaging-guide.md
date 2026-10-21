## AI CLI Packages

> **Last verified:** 2026-10-21 — updates are dispatched as the CI `Update`
> workflow. Codex adopts nixpkgs' output-root layout, source-built voice and
> store-linked runtime; Kiro parses embedded rollout JSON, preserving state
> fields; copies must agree. The byte-preserving patcher remains strict. The
> devenv update lane realizes the patched Kiro through the repo shell, so it
> does not push. The same pushFilter also excludes the CodeQL engines, which the
> input lanes do not build.

### Overview

AI coding CLI recipes live at `packages/<owner>/packages/ai/<name>/package.nix`:

- **chatgpt-codex** — OpenAI Codex CLI, compiled from the GitHub source by
  overriding nixpkgs' `codex`, including its source-built voice host
- **claude-code** — Claude Code CLI, pre-built binary
- **copilot-cli** — GitHub Copilot CLI, pre-built SEA binary fetched from GitHub
  releases
- **kimchi** — Kimchi coding-agent CLI (Cast AI), built from release source with
  Bun and a Go proxy helper
- **kiro-cli** — Kiro CLI, pre-built binary fetched from AWS release channel
- **kiro-gateway** — Python proxy API for Kiro IDE and CLI, built from source
  with a Python runtime environment

Packages live under `pkgs.ai.*` and are flattened to top-level flake outputs
(`chatgpt-codex`, `claude-code`, `copilot-cli`, `kimchi`, `kiro-cli`,
`kiro-gateway`).

claude-code, copilot-cli, kimchi-docs and kiro-cli are unfree, so they are not
in `packages.<system>`: `nix flake check` forces every drvPath there, and this
flake never enables unfree for a consumer. Consumers get them from
`legacyPackages.<system>` (or the overlay, or the modules) with their own unfree
opt-in. Repository code reads them from `ciPackages.<system>`.

### Build Patterns

**overrideAttrs binary** (kiro-cli): overrides nixpkgs' `kiro-cli-unwrapped`
derivation to pin the version and `src` from a per-platform `sources.json`, then
re-composes the public package through upstream's wrapper.

**Source override** (chatgpt-codex): `pkgs.codex.override` swaps in the locked
`mkRustPlatform`, and `overrideAttrs` pins `buildCommit`, `version`, `src` and
`cargoHash` from `sources.json`. nixpkgs' vendor derivation reads those final
attributes and disables bundled Opus so voice links against its `libopus`. The
recipe retains nixpkgs' `nix-package-layout.patch` and
`nix-voice-runtime.patch`: daemon validation and the voice loader accept the
declared store-linked rg, bwrap and GStreamer files. It filters only
`no-daemon_auto_start.patch`, since modules declare that setting explicitly
while the binary retains upstream's default.

- nixpkgs installs the complete package at `$out`: `codex-package.json`,
  `bin/codex`, `bin/codex-code-mode-host`, `codex-path/rg`, Linux
  `codex-resources/bwrap`, and `codex-resources/voice`. The CLI and voice host
  build from the same source with `CODEX_BUILD_COMMIT` and `STABLE_GIT_COMMIT`
  set to `buildCommit`. Voice is enabled on Darwin and GNU Linux, covering
  `aarch64-darwin` and `x86_64-linux`; its private runtime links nixpkgs'
  GStreamer libraries and plugins. Public executables follow the upstream
  package's CLI and code-mode host; Cargo's auxiliary `logs_client` SQLite
  viewer is excluded.
- `lib/packageLayout.nix` names `.` as the package root. The daemon selector
  pins `<package>/.` and releases only that literal shape. The layout check
  starts and stops the real daemon through nixpkgs' patched package validation;
  `chatgpt-codex-voice-runtime` reuses nixpkgs' framed handshake and GStreamer
  initialization test. See `packages/chatgpt-codex/docs/codex-daemon.md` for
  daemon policy.

**Standalone binary** (copilot-cli): there is no nixpkgs base to inherit, so it
is a fresh `stdenv.mkDerivation` over a per-platform release tarball selected
from `sources.json`, installing a single SEA binary (`copilot`). On Linux it
runs `autoPatchelfHook` to repoint the interpreter/rpath at the nix glibc.

**Bun source build** (kimchi): `fetchPnpmDeps` supplies the locked dependencies
to the same pnpm 10 used by the build. Upstream compiles the CLI with Bun and
stages `bin/kimchi` plus `share/kimchi/`; a separate `buildGoModule` compiles
`proxy-helper` from the same source. Preserve this layout and disable generic
ELF rewriting and stripping of the compiled Bun graph.

**Python application** (kiro-gateway): Built with `mkDerivation` using a
`python.withPackages` environment. The source is fetched via inline `rev` +
`hash` with `fetchFromGitHub`.

### Version Tracking

These packages pin versions in their recipe or release `sources.json` sidecar.
Each uses an update strategy managed by `config.update.targets` (see owner
`registry.nix`):

- `chatgpt-codex` — `sources.json` {buildCommit, cargoHash, srcHash, version} +
  `mkUpdateScript`; version via `ghLatestVersionCmd` with `tagPrefix = "rust-v"`
  (openai/codex cuts several tag series, so the prefix is load-bearing). The
  script resolves `buildCommit` from the `rust-v<version>` tag (dereferencing
  annotated tags), then `passthru.fixVendorHash` restores the source and cargo
  vendor hashes the rewrite dropped. Not automated: the V8 library comes from
  nixpkgs' `librusty_v8` pin, so a codex bump that moves the `v8` crate fails to
  build until nixpkgs catches up or we pin `librusty_v8` ourselves
- `copilot-cli` — per-platform `sources.json` + `mkUpdateScript` fetches latest
  GitHub release and prefetches per-platform binaries
- `kimchi` — `sources.json` + `mkUpdateScript` records the latest GitHub release
  tag; the same update pins the matching release source (shared by the source
  build and the extractor), exact pi npm package, and pi declaration
  dependencies, then runs `lib.extracted.regenCommand` through the owner check's
  `passthru.regenerate`; its extractor uses nixpkgs' TypeScript compiler API.
  The update derives the Go floor before the proxy-helper vendor hash, and
  refreshes pnpm dependencies
- `kiro-cli` — per-platform `sources.json` + `mkUpdateScript` fetches latest
  version from AWS manifest endpoint
- `kiro-gateway` — inline `rev` + `hash`; `update-pkg.sh` tracks the main branch
  from the `git` URL in its `registry.nix` target; version via `mkVersion`

The `lib/packaging.nix` file provides `ghLatestVersionCmd`, `mkUpdateScript`,
and `mkVersion` helpers consumed by each owner recipe. `ghLatestVersionCmd`
reads the `releases/latest` redirect rather than the GitHub API, so it needs no
token and cannot be rate-limited; prefer it over a hand-rolled
`curl … api.github.com | jq -r .tag_name` version check.

### Kiro never reaches the public cache — TWO credentialed paths, not one

No Kiro binary is ever pushed to the public cache: `kiro-cli` is always a local
vendor download, and a patch is always a local patch of it.
`ciPackages.<system>.kiro-cli-rollout-canary` is an internal validation target,
built with `kiro-cli.withRolloutFeatures` for every feature whose extracted
vendor state needs a patch and whose measured patchability is true, matching
consumer package selection. `extract/rollout-coverage.nix` owns the shared
restriction predicate. Its recipe lives outside the discovered public package
tree and is exposed only in `ciPackages`. The parity check verifies it stays
absent from the overlay and public outputs. Consumer
`cli.features.<name>.enable` patches only features whose extracted vendor state
needs it; workflows are GA since 2.26.0 and select the stock package. Long
feature sets use a bounded derivation suffix with a feature count and digest;
short sets retain readable names. The extractor locates each manifest root and
parses its JSON, copying every entry field except the unused description.
Missing manifests and disagreeing copies fail extraction. State readers reject
unknown fields; internal treatment must also be 100% to preserve the stock
package. Separately, `rolloutPatchability` records whether every feature site
matches the shared patcher entry regex and counts unmatched sites. An
unpatchable feature is rejected at module evaluation with its name and the
extracted flag if it needs a patch. Counts remain per platform; modules read
only the aggregate flag. A patched canary contains modified proprietary bytes,
so it must never be republished.

**Excluding it from `ci.yml`'s native package shards is necessary and NOT
sufficient.** That was the whole mitigation from #665 (2026-08-01), and the
patched 2.17.0 binary was live in the public cache on 2026-08-12 anyway — eleven
days later, so `ci.yml` provably was not the source. Two workflow paths hold
`CACHIX_AUTH_TOKEN`, and only one of them was covered:

| job                     | builds patched?                  | pushes?                  |
| ----------------------- | -------------------------------- | ------------------------ |
| `ci.yml` build-packages | no — `ci-packages.py` exclusions | token → **`pushFilter`** |
| `ci.yml` publish-hestia | no — builds `ciHestia` only      | token → **`pushFilter`** |
| `ci.yml` test           | no                               | no token                 |
| `kiro-patched`          | yes                              | no token                 |
| `update.yml` inputs     | **yes — `verify_all_packages`**  | token → **`pushFilter`** |
| `update.yml` devenv     | **yes — the repo devenv shell**  | token → **`skipPush`**   |

`ci-packages.py` removes its `EXCLUDED` names before partitioning the native
package set and emits a positive `--select` expression for each shard. Keep the
patched variant in that exclusion set; the dedicated native jobs validate it
without cache credentials. The unpatched `kiro-cli` stays in the shards: they
build it as a check, and the `pushFilter` is what keeps it out of the cache.

`verify_all_packages` (`dev/scripts/update-common.sh`) builds
`.#ciPackages.<sys>`, Kiro's patched canary included, on every input bump; only
the CodeQL engines are left out of its `--select` (see the codeql fragment).
Building Kiro there is deliberate and stays: `postInstallCheck` runs
`kiro-cli-chat --version`, so the build is a genuine runtime smoke test of the
patch, and `doInstallCheck` is already true upstream so the phase really
executes. The fix is therefore at the PUSH, not the build —
`pushFilter: kiro-cli|codeql` on every `cachix-action` step that holds the token
(`ci.yml` publish-hestia and build-packages, and the `update.yml` update step
every lane shares). One spelling, copied identically: Actions cannot share an
action input across workflows, and `test-ci-packages.py` fails if any
credentialed step lacks it.

**The generalizable lesson: `cachix-action` with a token runs a watch-store
daemon that pushes every path realized in the job.** Reasoning about which
_command_ builds what tells you nothing about what gets published. Audit by job
credential, not by build invocation.

Supporting properties:

- **`pushFilter` EXCLUDES matching paths** — cachix-action's `action.yml` says
  "Regular expression to exclude derivations from being pushed". It reads like
  an allow-list and has already been misread as one in review; inverting it
  would publish ONLY kiro. It is also ignored outright if `pathsToPush` is set.
- **`pushFilter` drops ALL kiro, not just the patched variant.** Nothing is lost
  — the unpatched package is a vendor download anyone can fetch — and it covers
  the layers naming cannot reach (below). `ci.yml` used to publish the unpatched
  package on purpose; it no longer does.
- **It is not a guarantee on its own**: "paths may still be pushed if they are
  part of another path's closure". The repo devenv shell is such a path: it
  depends on the patched output, and on 2026-10-17 the devenv lane's shell-entry
  check published the patched closure through it (sweep `39032289943`), caught
  by the tripwire below. That lane therefore sets `skipPush`, which
  `test-ci-packages.py` pins. The package shards and the other update lanes
  build the patched output only as its own `kiro-cli-…` root, and every layer
  inside it matches the regex — a property of the current graph that fails
  silently. The tripwire below is the actual guarantee.
- **Patched derivations are RENAMED so a leak is self-identifying.** Both
  variants used to be `kiro-cli-unwrapped-<version>`, differing only by store
  hash, which is exactly why one sat unnoticed in a cache listing. The patched
  build is now `kiro-cli-unwrapped-rollout-<features>-<version>`, gated inside
  `optionalAttrs (rolloutFeatures != [])` so the default derivation is
  untouched. Darwin needs the rename re-applied in the OUTER `overrideAttrs`,
  because upstream's `kiro-cli-unwrapped.overrideAttrs {pname = "kiro-cli";}`
  clobbers it otherwise.
- **The rename cannot reach the linux FHS intermediates.** Upstream originally
  hardcoded one `pname = executableName` per environment and now hardcodes
  `pname = "kiro-cli"` for the consolidated environment. Neither form consults
  `kiro-cli-unwrapped.pname`, so `-bwrap` / `-fhsenv-rootfs` are identical
  strings for both variants. They carry no proprietary bytes and are inert
  without the unwrapped path — but it is why the filter is blunt rather than
  surgical.

Both knobs are configuration, so the `kiro-patched` job's "Assert the patched
output is not published" step asserts the OUTCOME. It enumerates the patched
closure, selects the paths whose basename names kiro, and hands them to
`dev/scripts/assert-not-published.sh`, which the CodeQL tripwire in the `test`
job shares. That script refuses an empty path list, checks `nix-cache-info`
first as a positive control, and counts only a 404 as absent: every assertion is
"not fetchable", so a typo'd host or an empty list would satisfy all of them,
and a tripwire that can only pass is worse than none.

Getting that step right took wrong versions, and each failure mode is worth
keeping because none is specific to Kiro:

- **Assert on the WHOLE patched closure, shared FHS pieces included.** The
  dispatcher, `-init` script, and `-fhsenv-profile` tree are byte-identical
  across both variants and share a store path. The step used to subtract the
  unpatched closure so those paths, published before the filter reached
  `ci.yml`, did not read as leaks. The operator purged them (2026-10-10, every
  kiro path in the pinned closure answers 404), so the subtraction is gone and
  any kiro path that answers 200 fails the step.
- **An emptiness guard is not enough.** A large, well-formed, entirely useless
  list passes `[ -z ]` and makes the loop ask nothing. The step requires the
  patched closure listing to contain a kiro path, so a shape change is one loud
  line instead of a silent pass. Entries are compared by BASENAME
  (`${path##*/}`), since nix versions differ on whether a store path prints with
  its `/nix/store/` prefix.

Sources are filtered too, and gain explicit versioned names
(`kiro-cli-source-<version>-<system>.<ext>`). They were unversioned
(`kirocli-x86_64-linux.tar.gz`, and darwin's `Kiro%20CLI.dmg` landing as
`Kiro-20CLI.dmg` once nix strips the illegal `%`), so a 647 MiB blob could not
be attributed to a release. Caching them bought nothing regardless: the version
comes from the committed sidecar, not IFD, so **eval never needs the source and
nix fetches `src` only when it must BUILD** — anyone with a cache hit never
touches it, and anyone without is building from source anyway.

KAS outputs are named `kiro-cli-kas[-patched]-<version>`, so the same upload
filter excludes them. They are unfree release data (agent metadata declares
`AWS-IPL`), not an independently sourced open-source package. The CLI's runtime
closure contains its one selected KAS, so the full-closure cache exclusion check
also covers that payload. Native package and KAS share the fetched source; KAS
extracts directly from it, avoiding a dependency cycle. See the Kiro launcher
fragment for archive validation, patch selection and runtime checks.

### The overrideAttrs Pattern

kiro-cli overrides an existing nixpkgs package rather than defining a new
derivation from scratch. This inherits upstream build logic (install phases,
meta, dependencies) while pinning to inline versions and per-platform sources:

```nix
pkgs.<package>.overrideAttrs (_: {
  inherit (sources) version;
  src = fetchurl { inherit (platformSrc) url hash; };
})
```

Upstream nixpkgs changes to that derivation (new dependencies, build fixes) are
picked up on nixpkgs bumps.

**But only while `pkgs.<name>` remains the derivation carrying `src`.** This
pattern degrades to a SILENT no-op — not an error — the moment upstream
restructures the attribute out from under it. nixpkgs f13ff45a split `kiro-cli`
into `kiro-cli-unwrapped` plus a public FHS wrapper (initially a `symlinkJoin`
of three environments, now one shared environment); the public derivation has no
`src`, and its `buildCommand` never reaches the unwrapped package's
`fixupPhase`, so the pin AND the `postFixup` both evaporated while the build
stayed green. `packages/kiro-cli/packages/ai/kiro-cli/package.nix` therefore
feature-detects `pkgs ? kiro-cli-unwrapped` on the injected `pkgs`, overrides
the unwrapped derivation, and hands the result back to upstream's wrapper via
`.override`. Its public passthru also exposes `withFhsPayload` so module
configuration that must be visible inside the FHS root can use that same
upstream expression. The public package-selection contract is topology-stable:
`unwrapped` always names the direct payload, and `kiroFhsSandbox` says whether
selecting it actually removes an FHS layer (`false` on darwin and pre-split
nixpkgs). `useFhsSandbox = false` selects that payload explicitly instead of
changing the public package's default meaning.

Read the "When the attribute stops being the derivation" section of the
overlay-pattern fragment before adding another `overrideAttrs` package — it
carries the two commands that detect this class.

### Building and Updating

```bash
nix build .#chatgpt-codex       # Build OpenAI Codex CLI
nix build .#kimchi              # Build Kimchi CLI
nix build .#kiro-gateway        # Build Kiro Gateway
# Unfree packages are not in `packages`; build them from the internal set
nix build .#ciPackages.<system>.copilot-cli   # Build Copilot CLI
nix build .#ciPackages.<system>.kiro-cli      # Build Kiro CLI
gh workflow run update.yml      # Dispatch the CI update sweep over config.update.targets
```
