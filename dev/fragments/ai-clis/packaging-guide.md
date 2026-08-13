## AI CLI Packages

### Overview

AI coding CLI tools are packaged as overlays under `overlays/`:

- **chatgpt-codex** — OpenAI Codex CLI, pre-built static-musl binary fetched
  from GitHub releases
- **claude-code** — Claude Code CLI, pre-built binary
- **copilot-cli** — GitHub Copilot CLI, pre-built SEA binary fetched from GitHub
  releases
- **kimchi** — Kimchi coding-agent CLI (Cast AI), bun-compiled binary fetched
  from GitHub releases
- **kiro-cli** — Kiro CLI, pre-built binary fetched from AWS release channel
- **kiro-gateway** — Python proxy API for Kiro IDE and CLI, built from source
  with a Python runtime environment

Packages live under `pkgs.ai.*` and are flattened to top-level flake outputs
(`pkgs.chatgpt-codex`, `pkgs.claude-code`, `pkgs.copilot-cli`, `pkgs.kimchi`,
`pkgs.kiro-cli`, `pkgs.kiro-gateway`).

### Build Patterns

**overrideAttrs binary** (kiro-cli): overrides the existing nixpkgs derivation
to pin the version and `src` from a per-platform `sources.json`, inheriting
upstream install/wrapper logic.

**Standalone binary** (chatgpt-codex, copilot-cli, kimchi): there is no nixpkgs
base to inherit, so these are fresh `stdenv.mkDerivation`s over a per-platform
release tarball selected from `sources.json`. On Linux the dynamically-linked
ones run `autoPatchelfHook` to repoint the interpreter/rpath at the nix glibc.

- chatgpt-codex unpacks to ONE flat `codex-<target-triple>` file (no wrapper
  directory, hence `sourceRoot = "."`) installed as `$out/bin/codex`. Its Linux
  build is `static-pie` musl, so it is the one standalone binary here that needs
  neither autoPatchelfHook nor an interpreter patch. Apache-2.0 (free), so the
  unfree guard passes it through unwrapped.
- copilot-cli installs a single SEA binary (`copilot`).
- kimchi ships an FHS tree (`bin/kimchi` + `share/kimchi/`, including a second
  ELF `share/kimchi/bin/proxy-helper`); the install copies the whole tree and
  autoPatchelf patches both ELFs. The binary resolves `share/` relative to
  itself, so the tree is preserved, not relocated. Apache-2.0 (free), so it
  passes the unfree guard unwrapped.

**Python application** (kiro-gateway): Built with `mkDerivation` using a
`python.withPackages` environment. The source is fetched via inline `rev` +
`hash` with `fetchFromGitHub`.

### Version Tracking

These packages pin versions inline (binary CLIs via a per-platform
`sources.json` sidecar). Each uses an update strategy managed by
`config.update.targets` (see `config/update-targets.nix`):

- `chatgpt-codex` — per-platform `sources.json` + `mkUpdateScript`; version via
  `ghLatestVersionCmd` with `tagPrefix = "rust-v"` (openai/codex cuts several
  tag series, so the prefix is load-bearing)
- `copilot-cli` — per-platform `sources.json` + `mkUpdateScript` fetches latest
  GitHub release and prefetches per-platform binaries
- `kimchi` — per-platform `sources.json` + `mkUpdateScript` fetches the latest
  GitHub release tag and prefetches per-platform tarballs
- `kiro-cli` — per-platform `sources.json` + `mkUpdateScript` fetches latest
  version from AWS manifest endpoint
- `kiro-gateway` — inline `rev` + `hash` with `mkGitRevUpdateScript` for
  main-branch tracking; version via `mkVersion`

The `overlays/lib.nix` file provides `ghLatestVersionCmd`,
`mkGitRevUpdateScript`, `mkUpdateScript`, and `mkVersion` helpers consumed by
each overlay file. `ghLatestVersionCmd` reads the `releases/latest` redirect
rather than the GitHub API, so it needs no token and cannot be rate-limited;
prefer it over a hand-rolled `curl … api.github.com | jq -r .tag_name` version
check.

### Patched Kiro variants stay local — TWO credentialed paths, not one

`pkgs.ai.kiro-cli-workflows` exposes the same derivation selected by
`ai.kiro.unlockedRolloutFeatures = ["workflows"]`. It must never reach the
public cache: it is a MODIFIED proprietary binary, and republishing one is a
different act from mirroring the vendor's own build.

**Excluding it from `ci.yml`'s build job is necessary and NOT sufficient.** That
was the whole mitigation from #665 (2026-08-01), and the patched 2.17.0 binary
was live in the public cache on 2026-08-12 anyway — eleven days later, so
`ci.yml` provably was not the source. Two jobs hold `CACHIX_AUTH_TOKEN`, and
only one of them was covered:

| job                    | builds patched?                 | pushes?                        |
| ---------------------- | ------------------------------- | ------------------------------ |
| `ci.yml` build         | no — `--select removeAttrs`     | yes (token)                    |
| `update.yml` sweep     | **yes — `verify_all_packages`** | yes (token) → **`pushFilter`** |
| `kiro-workflows-local` | yes                             | no token                       |
| `ci.yml` test          | no                              | no token                       |

`verify_all_packages` (`dev/scripts/update-common.sh`) builds `.#packages.<sys>`
with **no `--select`**, on every input bump. That is deliberate and stays:
`postInstallCheck` runs `kiro-cli-chat --version`, so the build is a genuine
runtime smoke test of the patch, and `doInstallCheck` is already true upstream
so the phase really executes. The fix is therefore at the PUSH, not the build —
`pushFilter: "kiro-cli"` on that job's `cachix-action`.

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
- **The rename cannot reach the linux FHS intermediates.** Upstream hardcodes
  `pname = executableName` per `buildFHSEnv` and `name = "kiro-cli-${version}"`
  for the join, consulting `kiro-cli-unwrapped.pname` nowhere, so `-bwrap` /
  `-fhsenv-rootfs` are identical strings for both variants. They carry no
  proprietary bytes and are inert without the unwrapped path — but it is why the
  filter is blunt rather than surgical.

Both knobs are configuration, so `ci.yml`'s "Assert the patched output is not
published" step asserts the OUTCOME: it walks the patched closure and fails if
any kiro path answers 200 from the cache. It opens with a positive control
against `nix-cache-info`, because every assertion in it is "not 200" and a
typo'd host would satisfy all of them — a tripwire that can only pass is worse
than none.

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
ourPkgs.<package>.overrideAttrs (_: {
  inherit (sources) version;
  src = fetchurl { inherit (platformSrc) url hash; };
})
```

Upstream nixpkgs changes to that derivation (new dependencies, build fixes) are
picked up on nixpkgs bumps.

**But only while `pkgs.<name>` remains the derivation carrying `src`.** This
pattern degrades to a SILENT no-op — not an error — the moment upstream
restructures the attribute out from under it. nixpkgs f13ff45a split `kiro-cli`
into `kiro-cli-unwrapped` plus a `symlinkJoin` of `buildFHSEnv` sandboxes; the
join has no `src` and no `version`, and a `buildCommand` derivation never
reaches `fixupPhase`, so the pin AND the `postFixup` both evaporated while the
build stayed green. `overlays/kiro-cli.nix` therefore feature-detects
`ourPkgs ? kiro-cli-unwrapped`, overrides the unwrapped derivation, and hands
the result back to upstream's wrapper via `.override`.

Read the "When the attribute stops being the derivation" section of the
overlay-pattern fragment before adding another `overrideAttrs` package — it
carries the two commands that detect this class.

### Building and Updating

```bash
nix build .#chatgpt-codex       # Build OpenAI Codex CLI
nix build .#copilot-cli         # Build Copilot CLI
nix build .#kimchi              # Build Kimchi CLI
nix build .#kiro-cli            # Build Kiro CLI
nix build .#kiro-gateway        # Build Kiro Gateway
nix run .#update                # Update all source versions via config.update.targets
```
