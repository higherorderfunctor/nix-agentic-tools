# gh — the GitHub CLI, re-pinned onto this repo's update cadence. A thin
# `overrideAttrs` over nixpkgs' own `buildGoModule` derivation: only
# `version`, `src`, `vendorHash` and `passthru` move, so nixpkgs' Makefile
# build, its manpages and shell completions, the
# `--set-default GH_TELEMETRY false` wrapper, `__structuredAttrs` and
# `doCheck = false` all stay exactly as shipped.
#
# TWO hashes here, unlike the Rust packages in this directory. A Go
# package's vendor set is not derivable from a lockfile the way
# `importCargoLock` derives one from `Cargo.lock` — `go.sum` records
# module hashes, not a Nix-fetchable vendor tree — so `vendorHash` has to
# be recorded. It lives in the SIDECAR rather than inline because
# `mkUpdateScript` rebuilds the sidecar FROM SCRATCH on every write
# (`jq -n --arg v "$latest" '{version: $v}'`), which destroys any key the
# writer does not itself produce. `vu.mkGoVendorFix` runs as
# `extraExtract` immediately after that write and puts the correct value
# back, which is why the read below is `sources.vendorHash or fakeHash`:
# the `or` covers exactly the window between the two.
#
# The Go TOOLCHAIN is derived from the go.mod floor, via `vu.mkGoBuilder`.
# That needs `.override` rather than `overrideAttrs` — it is a builder
# argument, not an attr — so this file uses both seams: `.override` for
# the builder, `overrideAttrs` for version/src/vendorHash.
#
# This header used to say "No Go toolchain override", on the reasoning
# that threading one through "would perturb the byte-identical-to-nixpkgs
# derivation that is the whole point of a thin override". Both halves
# were wrong. Measured: `buildGoModule.override` with an unchanged
# toolchain is derivation-IDENTICAL, so adopting the seam moved no store
# path. And cli/cli quietly raised its floor to `go 1.26.5` — the version
# that broke `glab` for consumers on an older nixpkgs — so gh was one bump
# from the same failure while this file asserted it could not happen.
#
# WHY THIS PACKAGE EXISTS: update CADENCE. A gh release lands here on the
# 4x/day sweep instead of waiting on a nixpkgs channel bump. It is NOT
# here to be ahead of nixpkgs at any given moment, and the gap is often
# zero — that is expected and is not a reason to delete the package.
#
# Do not re-add a claim that this resolves to the same store path as plain
# `pkgs.gh`. It does not, measured at equal versions with identical `src`,
# `vendorHash` and derivation `env`; the divergence is in an input and has
# not been root-caused. The old claim predated that measurement.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (MIT). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md. go-overlay is applied
  # INSIDE this import so `go-bin` resolves against our own pin; it is
  # purely additive (`pkgs.go` is byte-identical with and without it), so
  # it moves no derivation.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./gh-sources.json);

  # Bound once: passed to BOTH the vendor fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/dev-tools/gh-sources.json";

  goUpdate = vu.mkGoUpdateExtract {
    attr = "gh";
    pkgs = ourPkgs;
    pname = "gh";
    inherit sourcesFile;
  };
  inherit (goUpdate) fixGoFloor fixVendorHash;

  # DERIVED from the pinned source's go.mod by `fixGoFloor`, never
  # hand-written. See `vu.mkGoFloorFix` for why, and
  # `checks/go-floor-drift.nix` for the gate that keeps it honest.
  goFloor = sources.goFloor or vu.goFloorUnknown;
in
  # TWO override seams, and they are not interchangeable. The toolchain is
  # a BUILDER argument, so it can only be reached with `.override`;
  # `version`/`src`/`vendorHash` are ordinary attrs that `buildGoModule`
  # reads off `finalAttrs`, so they compose on the output with
  # `overrideAttrs`. See the overlays fragment's `.override`-vs-
  # -`overrideAttrs` rule.
  (ourPkgs.gh.override {
    buildGoModule = vu.mkGoBuilder {
      floor = goFloor;
      pkgs = ourPkgs;
      pname = "gh";
    };
  })
  .overrideAttrs (prev: {
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack.
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;

    # Merge, never replace: buildGoModule hangs `goModules` and
    # `overrideModAttrs` here, module.nix warns loudly when an overlay
    # drops them, and `fixVendorHash` builds `.goModules` through this
    # very attrset. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
        inherit fixGoFloor fixVendorHash goFloor;
        goUpdateExtract = goUpdate.extract;
        updateScript = vu.ghArchiveUpdateScript {
          # ORDER is owned by `vu.mkGoUpdateExtract`, not restated
          # here. It was restated here, and it was wrong: the vendor
          # fixer compiles Go and so must follow the floor fixer.
          extraExtract = "${goUpdate.extract}";
          pkgs = ourPkgs;
          pname = "gh";
          repo = "cli/cli";
          inherit sourcesFile;
        };
      };
  })
