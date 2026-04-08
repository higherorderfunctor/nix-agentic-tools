# Overlay cache-hit parity fix

> Extracted from `docs/plan.md` during 2026-04-07 backlog grooming.
> Full long-form version of the "overlays must instantiate their own
> pkgs" backlog item. Referenced by the short item in plan.md.

## Problem

Every compiled overlay package in this repo currently builds against
the **consumer's** nixpkgs/rust-overlay/etc. when the overlay is
composed into a downstream flake. CI builds them standalone against
this repo's pinned `inputs.nixpkgs` and pushes to
`nix-agentic-tools.cachix.org`. The two store paths differ because
rustc/glibc/openssl/python/nodejs/go-toolchain/build-helpers come
from different nixpkgs revs. Result: cache miss on every consumer
rebuild even though the cachix substituter is wired up correctly.

Real-world surfaced 2026-04-06 when nixos-config consumed
`inputs.nix-agentic-tools.overlays.default` after the overlay swap
to use the full overlay (not just `ai-clis`). git-branchless forced
a local Rust compile despite `nix-agentic-tools.cachix.org` being
in `nix.settings.substituters`. Verified by computing both store
paths and querying narinfo:

- Standalone (this repo, `nix eval --raw .#git-branchless`):
  `/nix/store/<HASH_A>-git-branchless-0.10.0`
  → `curl cachix.org/<HASH_A>.narinfo` → **HTTP 200**
- Consumer (nixos-config, eval via `import nixpkgs { overlays = ...; }`):
  `/nix/store/<HASH_B>-git-branchless-0.10.0`
  → narinfo lookup against all known caches → **HTTP 404 everywhere**

This is the consequence of commit `e5406977` ("drop input follows
that defeat cachix substituters") — cachix substituters require
this repo's inputs to be a closed closure independent of consumers.
The deliberate trade-off was accepted: consumers get TWO nixpkgs in
their /nix/store (theirs + ours, mostly content-addressed dedup),
flake.lock grows, but cache hits work. The current overlay code
only completes HALF of that decision: cargoHash/src/version are
pinned to this repo's nvfetcher data, but the build infrastructure
(rustc, build helpers, base derivations) borrows from the consumer.
Need to commit fully.

## Fix pattern

Each compiled overlay package must instantiate `ourPkgs` from
`inputs.nixpkgs` (with whatever sub-overlays it needs from
`inputs.rust-overlay` etc.) and use `ourPkgs` for ALL build inputs
AND the base derivation. The overlay function signature still
receives `final`/`prev` from the consumer (overlay protocol
requirement), but only uses `final.system` to know the platform.

Threading: `inputs` is currently passed to the top-level overlay
composition functions (e.g. `packages/git-tools/default.nix` takes
`{inputs, ...}`), but is NOT threaded down to per-package overlay
files. The fix requires threading `inputs` (or at minimum
`inputs.nixpkgs` and `inputs.rust-overlay`) into each per-package
function.

### Example transformation for `packages/git-tools/git-branchless.nix`

```nix
# BEFORE — uses consumer's pkgs for everything except src/cargoHash
sources: final: prev: let
  nv = sources.git-branchless;
  rust = final.rust-bin.stable."1.88.0".default;
  rustPlatform = final.makeRustPlatform { cargo = rust; rustc = rust; };
in {
  git-branchless = prev.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (final.lib.toFunction args) finalAttrs;
      in a // {
        version = final.lib.removePrefix "v" nv.version;
        inherit (nv) src cargoHash;
        postPatch = null;
      });
  });
}

# AFTER — instantiates ourPkgs internally, uses it for everything
{inputs}: sources: final: _prev: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final) system;
    overlays = [(import inputs.rust-overlay)];
    config.allowUnfree = true;
  };
  nv = sources.git-branchless;
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform { cargo = rust; rustc = rust; };
in {
  git-branchless = ourPkgs.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in a // {
        version = ourPkgs.lib.removePrefix "v" nv.version;
        inherit (nv) src cargoHash;
        postPatch = null;
      });
  });
}
```

Note: `final.system` is still used to discover platform; everything
else is `ourPkgs.X`. The result is a derivation whose closure
traces back entirely to `inputs.nixpkgs` (this repo's pin), not the
consumer's. Store path is byte-identical to
`nix build .#git-branchless` run from this repo standalone → cache
hit.

## Threading inputs into per-package files

`packages/git-tools/default.nix` currently:

```nix
{inputs, ...}: let
  withSources = overlayPaths: final: prev: let
    sources = import ./sources.nix { inherit (final) fetchurl ...; };
    applyOverlay = path: (import path) sources final prev;  # ← no inputs
  in lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);
in
  lib.composeManyExtensions [
    inputs.rust-overlay.overlays.default
    (withSources localOverlays)
  ]
```

Update `applyOverlay` to pass `inputs` and drop the top-level
`inputs.rust-overlay.overlays.default` (since each package now
applies it internally to its own ourPkgs):

```nix
{inputs, ...}: let
  withSources = overlayPaths: final: prev: let
    sources = import ./sources.nix { inherit (final) fetchurl ...; };
    applyOverlay = path: (import path) {inherit inputs;} sources final prev;
  in lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);
in
  withSources localOverlays
```

Same threading change applies to `packages/mcp-servers/default.nix`
(already has the `{inputs, ...}` pattern via `callPkg` for some
packages — needs to be applied to ALL).

## Files to modify (audit completed 2026-04-06)

**`packages/git-tools/`** — every package builds Rust or Python:

- `default.nix` — thread `inputs` into per-package overlays; drop
  top-level `inputs.rust-overlay.overlays.default` (now per-package)
- `git-absorb.nix` — Rust, uses
  `final.rust-bin.stable.latest.default`
- `git-branchless.nix` — Rust, pinned to 1.88.0
- `git-revise.nix` — `final.python3Packages.buildPythonApplication`
  - hatchling. Python version-sensitive.
- `agnix.nix` — Rust, uses `final.rust-bin.stable.latest.default`,
  `final.pkg-config`, `final.apple-sdk_15` (darwin)

**`packages/mcp-servers/`** — npm/Python/Go builds, all currently
use `final`:

- `default.nix` — `callPkg` already supports `{inputs, ...}`
  pattern but most package files don't take `inputs`. Update each
  package file.
- npm: `context7-mcp.nix`, `effect-mcp.nix`, `git-intel-mcp.nix`,
  `openmemory-mcp.nix`, `sequential-thinking-mcp.nix` — use
  `final.buildNpmPackage`, `final.nodejs`, `final.makeWrapper`
- Python: `fetch-mcp.nix`, `git-mcp.nix`, `kagi-mcp.nix`,
  `mcp-proxy.nix`, `nixos-mcp.nix`, `serena-mcp.nix`,
  `sympy-mcp.nix` — use `final.python3Packages.X` or
  `final.python3.withPackages`
- Go: `github-mcp.nix`, `mcp-language-server.nix` — use
  `final.buildGoModule`

**`packages/ai-clis/`** — mixed:

- `claude-code.nix` — `prev.claude-code.override` (npm build) +
  `final.symlinkJoin` + `final.writeShellScript` + `final.bun`. The
  Bun runtime in the wrapper will close over consumer's bun version
  → AFFECTED. Fix: build everything against ourPkgs.
- `copilot-cli.nix` — `prev.github-copilot-cli.overrideAttrs` with
  just `src`/`version`. Pure binary install, low impact but still
  technically affected (base derivation comes from consumer). Lower
  priority unless verified to be cache-missing.
- `kiro-cli.nix` — same as copilot-cli plus `final.makeWrapper` for
  postFixup. Same priority.
- `kiro-gateway.nix` — uses `final.python314.withPackages` with
  explicit Python 3.14 + fastapi/httpx/etc. AFFECTED — Python env
  closure changes with consumer's nixpkgs.

**`packages/coding-standards/`, `fragments-ai/`, `fragments-docs/`,
`stacked-workflows/`** — pure content (markdown files in
derivations, no compilation). NOT affected. Skip.

## Verification protocol

After fixing each package, verify the consumer-side store path
matches the standalone-build store path:

```bash
# 1. Standalone path (CI builds this)
cd ~/Documents/projects/nix-agentic-tools
STANDALONE=$(nix eval --raw .#git-branchless)
echo "standalone: $STANDALONE"

# 2. Consumer path (eval the overlay through consumer's nixpkgs)
cd ~/Documents/projects/nixos-config
CONSUMER=$(nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs {
      system = "x86_64-linux";
      overlays = import ./overlays { inherit (flake) inputs; lib = flake.inputs.nixpkgs.lib; };
      config.allowUnfree = true;
    };
  in pkgs.git-branchless.outPath')
echo "consumer:   $CONSUMER"

# 3. Must be identical
[ "$STANDALONE" = "$CONSUMER" ] && echo "MATCH" || echo "DRIFT"

# 4. Confirm cache hit possible
HASH=$(basename "$STANDALONE" | cut -d- -f1)
curl -sI "https://nix-agentic-tools.cachix.org/${HASH}.narinfo" | head -1
# Expect: HTTP/2 200
```

Repeat for each package after fixing it. Add a flake check or CI
test that runs this comparison automatically — would catch any
future drift where someone introduces `final.X` for a build input.

## Why this isn't free (the trade-off the user already accepted)

The consumer's /nix/store ends up holding TWO nixpkgs evaluations:
their own (used for everything else) and ours (used to build our
packages). Most of the closure deduplicates via content-addressing
(glibc, bash, coreutils are byte-identical when source content
matches), but anything that drifted between the two pins is
duplicated. flake.lock grows because nix-agentic-tools' inputs
aren't deduped against the consumer's. Disk usage goes up, but
cache hits become reliable instead of theoretical.

This is the deliberate cost of `e5406977`. The fix here finishes
what that commit started.

## Lower-priority follow-ups

- Add a flake check `checks.x86_64-linux.cache-hit-parity` that
  fails if any consumer-side eval produces a store path different
  from the standalone build. Prevents regression.
- Document this pattern in `dev/docs/concepts/` so future overlay
  additions follow it from day one.
- Consider abstracting the `ourPkgs = import inputs.nixpkgs { ... }`
  boilerplate into a `lib/our-pkgs.nix` helper that takes `inputs`
  and `final.system` and returns a configured pkgs set. Each
  package file becomes a one-liner `{inputs}: ... let pkgs =
ourPkgs inputs final.system; in { ... };`.

## Related

- `dev/fragments/overlays/cache-hit-parity.md` — architecture
  fragment that scopes to overlay package files and points at this
  note.
- Commit `e5406977` — dropped input follows to enable cachix
  substituters.
