## AI CLI Packages

> **Last verified:** 2026-10-04 — the unfree packages are absent from `packages`
> and read from `ciPackages` or `legacyPackages`, repository commands included;
> main-tracking rev bumps are done by `update-pkg.sh`; chatgpt-codex compiles
> nixpkgs' `codex` from source, assembles upstream's complete package layout
> itself, adds the voice and zsh resources from the release archive and stamps
> the voice build commit into the CLI.

### Overview

AI coding CLI recipes live at `packages/<owner>/packages/ai/<name>/package.nix`:

- **chatgpt-codex** — OpenAI Codex CLI, compiled from the GitHub source by
  overriding nixpkgs' `codex`, plus the prebuilt voice and zsh resources from
  the GitHub release
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

claude-code, copilot-cli, kimchi-docs, kiro-cli and kiro-cli-workflows are
unfree, so they are not in `packages.<system>`: `nix flake check` forces every
drvPath there, and this flake never enables unfree for a consumer. Consumers get
them from `legacyPackages.<system>` (or the overlay, or the modules) with their
own unfree opt-in. Repository code reads them from `ciPackages.<system>`.

### Build Patterns

**overrideAttrs binary** (kiro-cli): overrides nixpkgs' `kiro-cli-unwrapped`
derivation to pin the version and `src` from a per-platform `sources.json`, then
re-composes the public package through upstream's wrapper.

**Source override** (chatgpt-codex): `pkgs.codex.override` swaps in the locked
`mkRustPlatform`, and `overrideAttrs` moves `version`, `src` and `cargoDeps` to
the `sources.json` pins (nixpkgs' version is not an argument, and
`buildRustPackage` reads its argument `cargoHash`, so `cargoDeps` is restated).
nixpkgs' `no-daemon_auto_start.patch` is dropped: our modules write that setting
and `extracted.json` records the binary's own defaults.

- postInstall assembles upstream's complete package as `$out/libexec/codex`
  (`codex-package.json`, `bin/codex`, `bin/codex-code-mode-host`,
  `codex-path/rg`, Linux `codex-resources/bwrap`; rg and bwrap copied from
  nixpkgs), with `$out/bin/*` as relative symlinks into it, and nixpkgs' PATH
  wrapper is dropped. Since 0.157.0 the app-server daemon only starts when the
  canonical executable sits at `<root>/bin/codex` beside a `codex-package.json`
  whose `target` is the running platform's (`x86_64-unknown-linux-gnu` for this
  glibc build), and it copies `<root>` into `CODEX_HOME` rejecting any symlink
  that leaves it. bwrap is looked up on PATH first and the bundled copy is the
  fallback; rg is looked up in `codex-path` first. Neither needs a PATH wrapper.
- The optional `codex-resources/{voice,zsh}` are not built: they are extracted
  as real files from the same release's `codex-package-<target>.tar.gz` (both
  platforms' archives carry both). That happens in postFixup, so strip never
  touches them (it would break the macOS signatures), and on Linux a scoped
  `autoPatchelf` repoints them at the nix glibc and ncurses while the
  source-built binaries are left alone. The voice host refuses any CLI whose
  compiled-in `STABLE_GIT_COMMIT` differs from its own (unset means `"dev"`), so
  preBuild exports the voice manifest's `buildCommit` from the same archive. The
  fully prebuilt recipe is
  `git show f38b946f:packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix`.
  `checks/chatgpt-codex-package-layout.nix` starts and stops the real daemon to
  hold this. Its daemon policy is in
  `packages/chatgpt-codex/docs/codex-daemon.md`.

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

- `chatgpt-codex` — `sources.json` {version, srcHash, cargoHash, per-platform
  release archive `{url, hash}`} + `mkUpdateScript`; version via
  `ghLatestVersionCmd` with `tagPrefix = "rust-v"` (openai/codex cuts several
  tag series, so the prefix is load-bearing). The script prefetches each
  platform's archive, then `passthru.fixVendorHash` restores the source and
  cargo vendor hashes the rewrite dropped. Not automated: the V8 library comes
  from nixpkgs' `librusty_v8` pin, so a codex bump that moves the `v8` crate
  fails to build until nixpkgs catches up or we pin `librusty_v8` ourselves
- `copilot-cli` — per-platform `sources.json` + `mkUpdateScript` fetches latest
  GitHub release and prefetches per-platform binaries
- `kimchi` — `sources.json` + `mkUpdateScript` records the latest GitHub release
  tag; the same update pins the matching release source (shared by the source
  build and the extractor), exact pi npm package, and pi declaration
  dependencies, then regenerates `extracted.json` with nixpkgs' TypeScript
  compiler API, derives the Go floor before the proxy-helper vendor hash, and
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

### Patched Kiro variants stay local — TWO credentialed paths, not one

`pkgs.ai.kiro-cli-workflows` exposes the same derivation selected by
`ai.kiro.unlockedRolloutFeatures = ["workflows"]`. It must never reach the
public cache: it is a MODIFIED proprietary binary, and republishing one is a
different act from mirroring the vendor's own build.

**Excluding it from `ci.yml`'s native package shards is necessary and NOT
sufficient.** That was the whole mitigation from #665 (2026-08-01), and the
patched 2.17.0 binary was live in the public cache on 2026-08-12 anyway — eleven
days later, so `ci.yml` provably was not the source. Two workflow paths hold
`CACHIX_AUTH_TOKEN`, and only one of them was covered:

| job                     | builds patched?                  | pushes?                        |
| ----------------------- | -------------------------------- | ------------------------------ |
| `ci.yml` build-packages | no — `ci-packages.py` exclusions | yes (token)                    |
| `ci.yml` test           | no                               | no token                       |
| `kiro-patched`          | yes                              | no token                       |
| `update.yml` inputs     | **yes — `verify_all_packages`**  | yes (token) → **`pushFilter`** |

`ci-packages.py` removes its `EXCLUDED` names before partitioning the native
package set and emits a positive `--select` expression for each shard. Keep the
patched variant in that exclusion set; the dedicated native jobs validate it
without cache credentials.

`verify_all_packages` (`dev/scripts/update-common.sh`) builds
`.#ciPackages.<sys>` with **no `--select`**, on every input bump. That is
deliberate and stays: `postInstallCheck` runs `kiro-cli-chat --version`, so the
build is a genuine runtime smoke test of the patch, and `doInstallCheck` is
already true upstream so the phase really executes. The fix is therefore at the
PUSH, not the build — `pushFilter: "kiro-cli"` on that job's `cachix-action`.

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
  — `ci.yml` publishes the unpatched package on merge — and it covers the layers
  naming cannot reach (below).
- **It is not a guarantee on its own**: "paths may still be pushed if they are
  part of another path's closure". Nothing outside the kiro closure depends on
  the patched output today and every layer inside it matches the regex, so it
  holds — but that is a property of the current graph, and it fails silently.
  The tripwire below is the actual guarantee.
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
output is not published" step asserts the OUTCOME: it fails if any kiro path
answers 200 from the cache. It opens with a positive control against
`nix-cache-info`, because every assertion in it is "not 200" and a typo'd host
would satisfy all of them — a tripwire that can only pass is worse than none.

Getting that step right took three wrong versions, and each failure mode is
worth keeping because none is specific to Kiro:

- **Assert only on the patched-UNIQUE paths.** Walking the whole patched closure
  now reports three false leaks (six before the FHS consolidation). The shared
  dispatcher, `-init` script, and `-fhsenv-profile` tree do not depend on the
  binary's CONTENT, so they are byte-identical across both variants, share a
  store path, and are published legitimately with the unpatched package.
  Subtract the unpatched closure first. A patched-specific path cannot appear in
  the base derivation tree, so the subtraction cannot over-exclude.
- **`nix derivation show`'s `.outputs[].path` changes shape by nix version** —
  `/nix/store/xxx-name` on 2.34.4, bare `xxx-name` on 2.35.1. A full-path
  comparison matched NOTHING on the runner while passing locally. Compare
  BASENAMES (`s|.*/||`) so both shapes normalize. This is the general trap:
  local nix and runner nix are different versions, so any jq over nix JSON needs
  verifying under both.
- **An emptiness guard is not enough.** That schema change produced a large,
  well-formed, entirely useless list which `[ -z ]` accepted. The guard also
  requires the enumeration to contain a kiro path, so the next shape change is
  one loud line instead of six false leak reports.
- **`printf … | grep -q` under `pipefail` inverts a successful match.**
  `grep -q` exits on the first hit, `printf` takes SIGPIPE (141), and pipefail
  reports 141 for the pipeline. It is SIZE-dependent — invisible below the ~64
  KiB pipe buffer, reproducible at the real ~95 KB — so a small fixture
  "verifies" it wrongly. The test is pure-bash for that reason.

Sources are filtered too, and gain explicit versioned names
(`kiro-cli-source-<version>-<system>.<ext>`). They were unversioned
(`kirocli-x86_64-linux.tar.gz`, and darwin's `Kiro%20CLI.dmg` landing as
`Kiro-20CLI.dmg` once nix strips the illegal `%`), so a 647 MiB blob could not
be attributed to a release. Caching them bought nothing regardless: the version
comes from the committed sidecar, not IFD, so **eval never needs the source and
nix fetches `src` only when it must BUILD** — anyone with a cache hit never
touches it, and anyone without is building from source anyway.

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
nix run .#update                # Update all source versions via config.update.targets
```
