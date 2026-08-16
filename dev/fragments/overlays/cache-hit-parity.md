## Overlay Cache-Hit Parity

> **Last verified:** 2026-08-16 (commit pending — adding Kiro's `withFhsPayload`
> passthru and FHS opt-out leaves the default derivation byte-identical; only
> configurations requesting an inner chat wrapper or the explicit unwrapped
> selection fork from it). Prior: 2026-08-16 (commit pending — nixpkgs 9ddfd8a
> consolidated Kiro's three FHS derivations into one shared environment. The
> overlay still recomposes exclusively through `ourPkgs`, so the topology change
> preserves the same consumer/standalone cache identity contract). Prior:
> 2026-08-10 (commit pending — `overlays/kiro-cli.nix` is no longer a plain
> `overrideAttrs`, so the "pure binary-fetch" example below is re-pointed.
> nixpkgs f13ff45a split the package, and the overlay now overrides
> `kiro-cli-unwrapped` and re-composes upstream's wrapper with `.override`.
> Parity is UNAFFECTED and the reason is worth stating: both sides of the parity
> check import `inputs.nixpkgs`, so the `ourPkgs ? kiro-cli-unwrapped`
> feature-detection resolves the same way on both and cannot itself drift — see
> the overlay-pattern fragment for the seam). Prior: 2026-08-05 (commit pending
> — records that a consumer's `inputs.nixpkgs.follows` defeats `ourPkgs` BY
> CONSTRUCTION, since it rewrites the input rather than the overlay argument,
> and that its cost is not merely the documented cache miss: measured on a real
> consumer, a followed April 2026 nixpkgs FAILED the `glab` build outright on
> the Go floor. Do not "fix" `ourPkgs` for this — `checks/cache-hit-parity.nix`
> already asserts the drift). Prior: 2026-08-03 (commit pending — annotates
> Semble's unchanged upstream derivation and git-branchless's passthru with
> their flake-input update owners without moving either derivation). Prior:
> 2026-08-03 (commit pending — patches Oxlint's `@napi-rs/cli` dependency in its
> pnpm-fetched source rather than admitting Darwin's `/bin/ps` into the sandbox;
> both fetch and build use pnpm 11 from pinned `ourPkgs`, matching upstream's
> major). Prior: 2026-08-03 (commit pending — nests every binary-package group
> under `pkgs.ai`, moves `gh` and `glab` into `ai.devTools`, and updates the
> consumer-path registry without changing any derivation). Prior: 2026-08-03
> (commit pending — relocates the two repo-local auto-memory source trees beside
> their overlay derivations without changing package inputs or cache-hit
> semantics). Prior: 2026-08-03 (commit pending — adds a positive control that
> substitutes the overlay's own `inputs.nixpkgs` the way a consumer's `follows`
> directive does, proving that unsupported configuration drifts from the
> cache-published `fblog` path). Prior: 2026-08-02 (commit pending — adds the
> pinned external Semble exception: direct upstream selection preserves
> Numtide's derivation, while a plain meta overlay exposes the MCP role without
> forking the build). Prior: 2026-07-25 (commit pending — the worked example
> moved off `git-branchless`, which had not carried this shape for a long time,
> onto `git-absorb`, which does; also corrects the new-package signature, the
> namespacing in the manual verification snippet, and the pure-binary-fetch
> package list). If you touch any `overlays/<name>.nix` overlay file or the
> overlay composition machinery and this fragment isn't updated in the same
> commit, stop and fix it. Regressions are gated by the
> `checks.cache-hit-parity` flake check (see "Verification" below).

### The rule

**Every compiled overlay package in this repo must instantiate its own `pkgs`
from `inputs.nixpkgs` and use THAT for all build inputs and the base
derivation.** Do not use the `final` / `prev` arguments for anything other than
discovering `final.system`.

If you use `final` or `prev` for build inputs, the derivation binds to the
**consumer's** nixpkgs pin. CI builds against this repo's own nixpkgs pin.
Different pins → different store paths → `nix-agentic-tools.cachix.org` does not
serve the consumer because the hash they're asking for was never computed. Cache
miss on every consumer rebuild.

### The pattern

```nix
# overlays/git-tools/git-absorb.nix — CORRECT
{inputs, final, ...}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchFromGitHub;

  vu = import ../lib.nix;

  rust = ourPkgs.rust-bin.stable.latest.default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };

  rev = "debdcd28d9db2ac6b36205bda307b6693a6a91e7";
  src = fetchFromGitHub {
    owner = "tummychow";
    repo = "git-absorb";
    inherit rev;
    hash = "sha256-...";
  };
in
  ourPkgs.git-absorb.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          version = vu.mkVersion {upstream = "0.9.0"; inherit rev;};
          inherit src;
          cargoHash = "sha256-...";
        });
  })
```

- `final.stdenv.hostPlatform.system` is the only thing we read from the consumer
  — we need it to know which platform to instantiate `ourPkgs` for.
- `ourPkgs` is built from THIS repo's `inputs.nixpkgs` plus any sub-overlays the
  package needs (rust-overlay here).
- Every downstream reference (`ourPkgs.git-absorb`, `ourPkgs.rust-bin`,
  `ourPkgs.makeRustPlatform`, `ourPkgs.lib`) routes through `ourPkgs`, not
  `final`/`prev`.
- Version is computed at eval time via `mkVersion`, producing `"x.y.z+debdcd2"`
  (upstream version + short rev).
- The per-package file takes `{inputs, final, ...}` and is imported by
  `overlays/default.nix` which composes all packages into the unified overlay.

**Why this vehicle, and not `git-branchless`.** This example was headed
`overlays/git-tools/git-branchless.nix` for a long time after that file stopped
having this shape — it now takes its `src` from the `inputs.git-branchless`
flake input rather than a pinned rev+hash, needs no sub-overlay in `ourPkgs`,
and reaches its base with `overrideAttrs`. `git-absorb` is the vehicle because
composing a sub-overlay into `ourPkgs` is part of the lesson, and
`git-branchless` cannot teach it. Keep the two in sync or move the example again
— do not re-point the heading at a file that does not match the body.

Note that the `.override`-on-the-builder seam above is a SEPARATE question from
cache-hit parity. Parity only cares that the base derivation and every build
input come from `ourPkgs`; which override seam is correct depends on how the
upstream builder is written. See the overlay-pattern fragment for that decision.

### `follows` defeats this by construction — and can HARD-FAIL, not just miss

`ourPkgs` guards the overlay ARGUMENT (`final` / `prev`). It cannot guard the
flake INPUT. A consumer writing

```nix
nix-agentic-tools = {
  url = "github:higherorderfunctor/nix-agentic-tools";
  inputs.nixpkgs.follows = "nixpkgs";   # UNSUPPORTED
};
```

rewrites THIS flake's `nixpkgs` input at lock time, before any of our code
evaluates, so `ourPkgs = import inputs.nixpkgs { … }` faithfully imports
**theirs**. No Nix expression can reference "my nixpkgs input, ignoring the
consumer's follows" — there is nothing `ourPkgs` could have done differently. It
is visible in the consumer's lock as
`nodes["nix-agentic-tools"].inputs.nixpkgs = ["nixpkgs"]`, a follows pointer
where our own locked node would otherwise be.

**Do not treat this as a hole to plug.** It is already encoded as unsupported:
the `followsControl` in `checks/cache-hit-parity.nix` constructs exactly this
scenario and asserts the output **drifts**. The check fails if `follows` ever
stops breaking parity.

**The cost is worse than the cache miss this fragment used to describe.**
Measured 2026-08-05 against a real consumer following an April 2026 nixpkgs
(`01fbdeef`, Go 1.26.2): `glab` did not merely rebuild from source, it failed
outright with `go.mod requires go >= 1.26.5 (running go 1.26.2)`. A package with
no toolchain-floor seam inherits whatever `go` the followed nixpkgs ships, and
`gh` was silently one bump behind the same fate.

The Go floor seam (overlay-pattern fragment) now covers all seven Go packages,
so that specific class is handled — a followed older nixpkgs gets a `go-bin`
toolchain instead of a failure. It does NOT make `follows` supported: the
consumer still gets zero cache hits, and the next toolchain-shaped dependency
that lacks a floor seam will break the same way. The README carries the
consumer-facing version of this warning.

### The trade-off (accepted in commit e5406977)

This pattern means **consumers get TWO nixpkgs evaluations in their
/nix/store**: their own (used for everything else) and this repo's (used to
build our packages). Most of the closure dedupes via content-addressing (glibc,
bash, coreutils are byte-identical when the source content matches between
pins), but anything that drifted between the two pins gets duplicated.

`flake.lock` grows because `nix-agentic-tools`'s inputs are not deduped against
the consumer's inputs (no `follows`). Disk usage goes up. Evaluation is slightly
slower.

**We accept this cost because cache hits are only reachable this way.** The
alternative (using `follows` to share inputs) produces a cleaner closure but
defeats the cachix substituter entirely: every consumer builds from source on
every rebuild.

### When you're writing a new overlay package

1. Accept `{inputs, final, ...}` as the function signature, and add the file to
   the right group attrset in `overlays/default.nix`, which is what threads
   `inputs` and `final` in.
2. Instantiate `ourPkgs = import inputs.nixpkgs { ... }` with any required
   sub-overlays.
3. Use `ourPkgs.X` for every build input.
4. Base the derivation on `ourPkgs.<package>`, never `prev.<package>`. Whether
   you reach it with `.override` or `overrideAttrs` is a separate decision
   (overlay-pattern fragment) — parity only cares where the base and the build
   inputs come from.
5. Verify: `nix eval --raw .#<package>` from this repo, then eval the same
   package through a consumer's nixpkgs with the overlay applied, and confirm
   the store path is byte-identical. If they differ, cache hits won't happen.

### Meta-only overrides can still fork the hash (`mainProgram`)

`overrideAttrs` is NOT free when it touches `meta.mainProgram`. Current nixpkgs
injects `NIX_MAIN_PROGRAM = meta.mainProgram` into the **build environment**
(`pkgs/stdenv/generic/make-derivation.nix`), so `mainProgram` is a derivation
input — an `overrideAttrs` that re-points it re-runs `mkDerivation`, re-derives
`NIX_MAIN_PROGRAM`, and forks the output hash. For a package whose base build
produces several role binaries (e.g. `agnix` builds `agnix` / `agnix-lsp` /
`agnix-mcp` in one derivation), exposing the role variants via `overrideAttrs`
therefore triggers a FULL, redundant rebuild per variant — invisible when
cached, but multiplied on every cold / toolchain-bump build.

Expose such variants with a plain attrset overlay instead, which does not re-run
`mkDerivation`:

```nix
# overlays/lsp-servers/agnix-lsp.nix
{agnix}: agnix // {meta = agnix.meta // {mainProgram = "agnix-lsp";};}
```

`//` overrides only the eval-time `meta` that `lib.getExe` reads, so all
variants share ONE derivation and ONE build while `getExe` still resolves the
correct per-role binary. Trade-off: the variant becomes a plain attrset (keeps
`type` / `drvPath` / `outPath` / `passthru`) and loses `.overrideAttrs` /
`.override` — fine when nothing overrides it further. The
`checks.cache-hit-parity` check asserts that `agnix`, `agnix-lsp`, and
`agnix-mcp` share one `drvPath`, so a regression back to `overrideAttrs` turns
it red.

### Verification

Automated (preferred): the `checks.cache-hit-parity` flake check evaluates every
compiled overlay package twice — once against `inputs.nixpkgs` (the "standalone"
/ CI path) and once against a deliberately divergent `inputs.nixpkgs-test` pin
playing the role of a consumer pkgs set. If any package's store path differs
between the two, the check fails with a drift report naming the offender.

A separate positive control re-imports the overlay with its own `inputs.nixpkgs`
substituted by `inputs.nixpkgs-test`, which models a consumer setting
`inputs.nixpkgs.follows`. The representative `fblog` output must drift from the
standalone path. This inversion proves the ordinary consumer simulation is not
silently blessing the configuration that defeats cache hits. Run the check
locally with:

```bash
nix build .#checks.x86_64-linux.cache-hit-parity
cat result   # "ok — no unintended drift detected" on success
```

Any regression — a new overlay package that uses `final.X` or `prev.X` for a
build input, an existing one that was refactored, or the `follows` control no
longer drifting — will turn the check red before it ships.

Manual (legacy, for ad-hoc debugging):

The two sides are spelled differently on purpose. `flake.nix` flattens every
package into `packages.<system>` for CLI ergonomics, so the standalone side is
`.#git-absorb`. The overlay itself is namespaced-only (`pkgs.ai.gitTools.*`,
`pkgs.ai.generic.*`, …) and never writes a top-level attribute, so the consumer
side MUST use the namespaced path — a bare `pkgs.git-absorb` there silently
resolves to plain nixpkgs' package and reports drift that is not real.

```bash
# 1. Standalone path (what CI builds and pushes to cachix)
cd ~/Documents/projects/nix-agentic-tools
STANDALONE=$(nix eval --raw .#git-absorb)

# 2. Consumer path (what your consumer gets via the overlay)
cd ~/Documents/projects/<consumer>
CONSUMER=$(nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs {
      system = "x86_64-linux";
      overlays = [ flake.inputs.nix-agentic-tools.overlays.default ];
      config.allowUnfree = true;
    };
  in pkgs.ai.gitTools.git-absorb.outPath')

# 3. MUST be identical
[ "$STANDALONE" = "$CONSUMER" ] && echo "OK" || echo "DRIFT"

# 4. Confirm cachix actually has it
HASH=$(basename "$STANDALONE" | cut -d- -f1)
curl -sI "https://nix-agentic-tools.cachix.org/${HASH}.narinfo" | head -1
# Expect: HTTP/2 200
```

### Exceptions

**Pinned external derivations preserve the upstream identity.** Semble is
selected directly from `inputs.llm-agents.packages.${system}.semble`, with no
nixpkgs follow, `overlays.shared-nixpkgs`, local `ourPkgs` rebuild, or
`overrideAttrs`. Its cache identity belongs to the upstream flake rather than to
this repository's nixpkgs pin. Both the standalone output and a deliberately
divergent consumer must match that upstream `drvPath` and `outPath` exactly.

The `semble-mcp` role uses the same plain attr/meta overlay pattern as the agnix
role variants, selecting `meta.mainProgram = "semble-mcp"` without re-running
`mkDerivation`. The parity check asserts the two Semble roles share one
derivation and that the CLI role is byte-identical to the pinned upstream
output. Distribution is separate from identity: CI substitutes from Numtide and
mirrors accepted `main` outputs into this project's Cachix cache.

The CLI overlay also adds `passthru.updateFlakeInput = "llm-agents"` through
that same plain attrset extension. `passthru` metadata changes neither `drvPath`
nor `outPath`; it tells the update-target completeness check that the normal
flake-input bump owns this versioned package. The MCP role inherits the property
with the rest of Semble's attrset.

The same metadata rule applies when an overlay rebuilds around a flake input:
`git-branchless` keeps its locally pinned `ourPkgs` build but declares
`passthru.updateFlakeInput = "git-branchless"`, because that input supplies both
its source and Cargo lock. Adding passthru through `overrideAttrs` is
derivation-neutral; the cache-hit parity gate remains the authority on the
resulting path.

**Content-only packages don't need this.** Packages that just ship markdown
files (coding-standards, stacked-workflows-content, fragments-ai) have no
compiled inputs, so their store paths are already byte-identical regardless of
which nixpkgs evaluates them. Skip the ourPkgs pattern for these.

"Content-only" means **no build inputs at all**. It does NOT mean "ships data
files rather than binaries" — a distinction worth being precise about, because
the `pkgs.ai.generic.*` packages (arkenfox, catppuccin-btop, dns-root-hints)
install nothing but data files and still need the full pattern: each runs a
fetcher (`fetchzip` / `fetchurl`) inside an stdenv derivation, and both of those
bind to whichever pkgs set supplies them. They are registered in
`config.checks.cacheHitParity` for exactly that reason. The test is not what a
package installs but whether it needs a `pkgs` set to evaluate; if it does, it
needs `ourPkgs`.

**Pure binary-fetch packages** (no build, just an `overrideAttrs` that swaps
`src`/`version`) still route through `ourPkgs` to keep the starting derivation
tied to this repo's nixpkgs pin. `copilot-cli` and `kiro-gateway` also ship
prebuilt binaries, but they are standalone `mkDerivation`s rather than
`overrideAttrs` — that is the next paragraph, not this one.

`overlays/kiro-cli.nix` used to head that list and no longer matches it: since
nixpkgs split the package, it overrides `ourPkgs.kiro-cli-unwrapped` and then
re-composes upstream's FHS wrapper with
`ourPkgs.kiro-cli.override {kiro-cli-unwrapped = pinned;}` (overlay-pattern
fragment, "When the attribute stops being the derivation"). **Parity is
unchanged and it is worth knowing why the extra branch cannot break it:** the
`ourPkgs ? kiro-cli-unwrapped` feature-detection reads `inputs.nixpkgs`, which
is the same pkgs set on BOTH sides of the parity check, so the two evaluations
always take the same branch. A detection keyed on `final`/`prev` would not have
that property — it would resolve against the consumer's pin and could take
different branches on the two sides, which is drift by construction. Keep
feature-detection on `ourPkgs`. The package remains covered by
`checks.cache-hit-parity`. The `withFhsPayload` function is passthru only and
therefore does not move the default derivation; calling it deliberately creates
a configuration-specific FHS derivation. Selecting `passthru.unwrapped` through
`useFhsSandbox = false` reuses the already pinned payload rather than building a
second copy.

**Standalone variant.** When upstream's attrs become incompatible with the
artifact we want to ship (different `sourceRoot`, `installPhase`, `buildInputs`,
wrapper shape, etc.), a per-platform overlay can instead be a standalone
`ourPkgs.stdenv.mkDerivation { ... }` rather than an `overrideAttrs`. The
cache-hit parity rule is unchanged — all build inputs still route through
`ourPkgs` — but no upstream attrs are inherited. `overlays/copilot-cli.nix` is
the current example: upstream rewrote `github-copilot-cli` from the per-platform
SEA tarball to a universal Node tarball, which would have required overriding
~every interesting attr, so the overlay holds its own SEA-shaped derivation
instead. Upstream-state detection lives in the Update workflow as a non-blocking
annotation step ("Detect upstream copilot-cli SEA restoration" in
`.github/workflows/update.yml`). It surfaces in the Update job's annotation
panel — same UX as the held-back-PR warnings — when upstream nixos-unstable HEAD
changes mechanism away from the universal-node layout we forked against.
