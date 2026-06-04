## Overlay Cache-Hit Parity

> **Last verified:** 2026-06-04 (commit pending — agnix
> mainProgram/NIX_MAIN_PROGRAM single-build gotcha). If you touch any
> `overlays/<name>.nix` overlay file or the overlay composition
> machinery and this fragment isn't updated in the same commit,
> stop and fix it. Regressions are gated by the
> `checks.cache-hit-parity` flake check (see "Verification" below).

### The rule

**Every compiled overlay package in this repo must instantiate its
own `pkgs` from `inputs.nixpkgs` and use THAT for all build inputs
and the base derivation.** Do not use the `final` / `prev` arguments
for anything other than discovering `final.system`.

If you use `final` or `prev` for build inputs, the derivation binds
to the **consumer's** nixpkgs pin. CI builds against this repo's
own nixpkgs pin. Different pins → different store paths →
`nix-agentic-tools.cachix.org` does not serve the consumer because
the hash they're asking for was never computed. Cache miss on
every consumer rebuild.

### The pattern

```nix
# overlays/git-tools/git-branchless.nix — CORRECT
{inputs, final, ...}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [(import inputs.rust-overlay)];
    config.allowUnfree = true;
  };
  vu = import ../lib.nix;

  rev = "abc1234...";
  src = ourPkgs.fetchFromGitHub {
    owner = "arxanas";
    repo = "git-branchless";
    inherit rev;
    hash = "sha256-...";
  };
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform { cargo = rust; rustc = rust; };
in
  ourPkgs.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in a // {
        inherit src;
        version = vu.mkVersion {
          upstream = vu.readCargoWorkspaceVersion "${src}/Cargo.toml";
          inherit rev;
        };
        cargoHash = "sha256-...";
      });
  })
```

- `final.stdenv.hostPlatform.system` is the only thing we read from
  the consumer — we need it to know which platform to instantiate
  `ourPkgs` for.
- `ourPkgs` is built from THIS repo's `inputs.nixpkgs` plus any
  sub-overlays the package needs (rust-overlay here).
- Every downstream reference (`ourPkgs.git-branchless`,
  `ourPkgs.rust-bin`, `ourPkgs.makeRustPlatform`, `ourPkgs.lib`)
  routes through `ourPkgs`, not `final`/`prev`.
- Version is computed at eval time from the source via `mkVersion`,
  producing `"x.y.z+abc1234"` (upstream version + short rev).
- The per-package file takes `{inputs, final, ...}` and is imported
  by `overlays/default.nix` which composes all packages into the
  unified overlay.

### The trade-off (accepted in commit e5406977)

This pattern means **consumers get TWO nixpkgs evaluations in
their /nix/store**: their own (used for everything else) and
this repo's (used to build our packages). Most of the closure
dedupes via content-addressing (glibc, bash, coreutils are
byte-identical when the source content matches between pins),
but anything that drifted between the two pins gets duplicated.

`flake.lock` grows because `nix-agentic-tools`'s inputs are
not deduped against the consumer's inputs (no `follows`).
Disk usage goes up. Evaluation is slightly slower.

**We accept this cost because cache hits are only reachable
this way.** The alternative (using `follows` to share inputs)
produces a cleaner closure but defeats the cachix substituter
entirely: every consumer builds from source on every rebuild.

### When you're writing a new overlay package

1. Accept `{inputs}: sources: final: _prev:` as the function
   signature (threading `inputs` is done in
   `packages/<group>/default.nix`).
2. Instantiate `ourPkgs = import inputs.nixpkgs { ... }` with any
   required sub-overlays.
3. Use `ourPkgs.X` for every build input.
4. Use `ourPkgs.package.override` (or similar) for the base
   derivation, not `prev.package.override`.
5. Verify: `nix eval --raw .#<package>` from this repo, then eval
   the same package through a consumer's nixpkgs with the overlay
   applied, and confirm the store path is byte-identical. If they
   differ, cache hits won't happen.

### Meta-only overrides can still fork the hash (`mainProgram`)

`overrideAttrs` is NOT free when it touches `meta.mainProgram`.
Current nixpkgs injects `NIX_MAIN_PROGRAM = meta.mainProgram` into the
**build environment** (`pkgs/stdenv/generic/make-derivation.nix`), so
`mainProgram` is a derivation input — an `overrideAttrs` that re-points
it re-runs `mkDerivation`, re-derives `NIX_MAIN_PROGRAM`, and forks the
output hash. For a package whose base build produces several role
binaries (e.g. `agnix` builds `agnix` / `agnix-lsp` / `agnix-mcp` in one
derivation), exposing the role variants via `overrideAttrs` therefore
triggers a FULL, redundant rebuild per variant — invisible when cached,
but multiplied on every cold / toolchain-bump build.

Expose such variants with a plain attrset overlay instead, which does
not re-run `mkDerivation`:

```nix
# overlays/lsp-servers/agnix-lsp.nix
{agnix}: agnix // {meta = agnix.meta // {mainProgram = "agnix-lsp";};}
```

`//` overrides only the eval-time `meta` that `lib.getExe` reads, so all
variants share ONE derivation and ONE build while `getExe` still
resolves the correct per-role binary. Trade-off: the variant becomes a
plain attrset (keeps `type` / `drvPath` / `outPath` / `passthru`) and
loses `.overrideAttrs` / `.override` — fine when nothing overrides it
further. The `checks.cache-hit-parity` check asserts that `agnix`,
`agnix-lsp`, and `agnix-mcp` share one `drvPath`, so a regression back
to `overrideAttrs` turns it red.

### Verification

Automated (preferred): the `checks.cache-hit-parity` flake check
evaluates every compiled overlay package twice — once against
`inputs.nixpkgs` (the "standalone" / CI path) and once against a
deliberately divergent `inputs.nixpkgs-test` pin playing the role
of a consumer pkgs set. If any package's store path differs
between the two, the check fails with a drift report naming the
offender. Run it locally with:

```bash
nix build .#checks.x86_64-linux.cache-hit-parity
cat result   # "ok — no drift detected" on success
```

Any regression — a new overlay package that uses `final.X` or
`prev.X` for a build input, or an existing one that was
refactored — will turn the check red before it ships.

Manual (legacy, for ad-hoc debugging):

```bash
# 1. Standalone path (what CI builds and pushes to cachix)
cd ~/Documents/projects/nix-agentic-tools
STANDALONE=$(nix eval --raw .#git-branchless)

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
  in pkgs.git-branchless.outPath')

# 3. MUST be identical
[ "$STANDALONE" = "$CONSUMER" ] && echo "OK" || echo "DRIFT"

# 4. Confirm cachix actually has it
HASH=$(basename "$STANDALONE" | cut -d- -f1)
curl -sI "https://nix-agentic-tools.cachix.org/${HASH}.narinfo" | head -1
# Expect: HTTP/2 200
```

### Exceptions

**Content-only packages don't need this.** Packages that just
ship markdown files (coding-standards, stacked-workflows-content,
fragments-ai) have no compiled inputs, so their store paths are
already byte-identical regardless of which nixpkgs evaluates
them. Skip the ourPkgs pattern for these.

**Pure binary-fetch packages** (no build, just an `overrideAttrs`
that swaps `src`/`version`) still route through `ourPkgs` to keep
the starting derivation tied to this repo's nixpkgs pin. The
`copilot-cli`, `github-copilot-cli`, `kiro-cli`, and
`kiro-gateway` overlays in `packages/ai-clis/` follow this shape
and are covered by the `checks.cache-hit-parity` flake check.

**Standalone variant.** When upstream's attrs become incompatible
with the artifact we want to ship (different `sourceRoot`,
`installPhase`, `buildInputs`, wrapper shape, etc.), a per-platform
overlay can instead be a standalone `ourPkgs.stdenv.mkDerivation { ... }`
rather than an `overrideAttrs`. The cache-hit parity rule is
unchanged — all build inputs still route through `ourPkgs` — but
no upstream attrs are inherited. `overlays/copilot-cli.nix` is the
current example: upstream rewrote `github-copilot-cli` from the
per-platform SEA tarball to a universal Node tarball, which would
have required overriding ~every interesting attr, so the overlay
holds its own SEA-shaped derivation instead. Upstream-state
detection lives in the Update workflow as a non-blocking
annotation step ("Detect upstream copilot-cli SEA restoration" in
`.github/workflows/update.yml`). It surfaces in the Update job's
annotation panel — same UX as the held-back-PR warnings — when
upstream nixos-unstable HEAD changes mechanism away from the
universal-node layout we forked against.
