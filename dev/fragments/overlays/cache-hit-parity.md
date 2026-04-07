## Overlay Cache-Hit Parity

> **Last verified:** 2026-04-07 (commit 0f4228d). If you touch any
> `packages/<group>/*.nix` overlay file or the overlay composition
> machinery and this fragment isn't updated in the same commit,
> stop and fix it. This rule is documented in detail as an OPEN
> backlog item in `docs/plan.md` ("Overlays must instantiate their
> own pkgs from `inputs.nixpkgs`").

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
# packages/git-tools/git-branchless.nix — CORRECT
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
        inherit (nv) src cargoHash;
        version = ourPkgs.lib.removePrefix "v" nv.version;
      });
  });
}
```

- `final.system` is the only thing we read from the consumer —
  we need it to know which platform to instantiate `ourPkgs` for.
- `ourPkgs` is built from THIS repo's `inputs.nixpkgs` plus any
  sub-overlays the package needs (rust-overlay here).
- Every downstream reference (`ourPkgs.git-branchless`,
  `ourPkgs.rust-bin`, `ourPkgs.makeRustPlatform`, `ourPkgs.lib`)
  routes through `ourPkgs`, not `final`/`prev`.
- The package function still takes `final: prev:` because the
  overlay protocol requires it and consumers expect
  `pkgs.git-branchless` to be available on their pkgs set.

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

### Status: backlog item in progress

As of 2026-04-07 the rule is NOT yet consistently applied. Current
overlay code in `packages/git-tools/git-branchless.nix` (and
friends) still uses `final.rust-bin` and `prev.git-branchless`.
The store path consumers get differs from CI's standalone-build
store path. Cache miss confirmed via narinfo lookup against
`nix-agentic-tools.cachix.org`.

The full fix plan, file enumeration, verification protocol, and
verification bash script all live in `docs/plan.md` under the
backlog item
"Overlays must instantiate their own pkgs from `inputs.nixpkgs`".
Read that before making changes — the answer is longer than
this fragment.

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

### Verification protocol

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
that swaps `src`/`version`) are borderline. If the `overrideAttrs`
uses `prev.X` for nothing except the starting meta, the store
path may still match. In practice, `copilot-cli.nix` and
`kiro-cli.nix` use this pattern and the cache parity is the
subject of ongoing verification — see the backlog item.
