# otel-tui — the terminal OpenTelemetry viewer, re-pinned onto this
# repo's update cadence. Same shape as the gh owner recipe: a thin
# `overrideAttrs` over nixpkgs' own `buildGoModule` derivation moving only
# `version`, `src`, `vendorHash` and `passthru`.
#
# DELIBERATELY NOT the sibling repo's shape, which this replaces. That one
# was an `stdenv.mkDerivation` untarring a GoReleaser release asset, with
# a hand-written `phases` list that dropped `fixupPhase`, no `meta` at
# all, and a sidecar carrying only `x86_64-linux` — which on this repo's
# REQUIRED aarch64-darwin CI leg would not degrade, it would fail at
# EVALUATION. Overriding nixpkgs' SOURCE build instead inherits
# `env.GOWORK = "off"`, the `versionCheckHook` install check, the `-X
# main.version` ldflags, a complete `meta`, and nixpkgs' full platform
# list — so the darwin problem disappears rather than being worked
# around. Do not "restore" the prebuilt-binary shape.
#
# vendorHash lives in the SIDECAR for the reason spelled out in
# the gh owner recipe: `mkUpdateScript` rebuilds the sidecar from scratch on
# every write. The vendor fixer from `vu.mkGoUpdateExtract` runs as
# `extraExtract` right after, and the read is `sources.vendorHash or
# fakeHash` to cover the window between the two.
#
# The Go TOOLCHAIN comes from the locked go-overlay via `vu.mkGoToolchain`
# — same shape as the gh owner recipe, and reached with `.override` because a
# toolchain is a builder argument that `overrideAttrs` cannot touch. This
# header used to say "No Go toolchain override"; see the gh owner recipe for why that
# reasoning did not survive measurement.
#
# WHY THIS PACKAGE EXISTS: update CADENCE. A release lands here on the
# 4x/day sweep instead of waiting on a nixpkgs channel bump. It is NOT
# here to be ahead of nixpkgs at any given moment, and the gap is often
# zero — that is expected and is not a reason to delete the package.
#
# Do not re-add a claim that this resolves to the same store path as plain
# `pkgs.otel-tui`. It does not, measured at equal versions; see the gh owner recipe.
#
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip lib;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);

  # One mutable source path shared by the vendor fixer and update script.
  sourcesFile = repoPath ../../../../sources.json;

  goUpdate = vu.mkGoUpdateExtract {
    attr = "otel-tui";
    inherit pkgs;
    pname = "otel-tui";
    inherit sourcesFile;
  };
  inherit (goUpdate) fixGoFloor fixVendorHash;

  # DERIVED from the pinned source's go.mod by `fixGoFloor`, never
  # hand-written. See `vu.mkGoFloorFix` for why, and
  # `checks/packaging/go-floor-drift.nix` for the gate that keeps it honest.
  goFloor = sources.goFloor or vu.goFloorUnknown;
in
  # TWO override seams — the toolchain is a BUILDER argument reachable
  # only via `.override`, while version/src/vendorHash are ordinary attrs
  # composed on the output. See the gh owner recipe and the overlays fragment.
  ((vu.mkGoToolchain {
      floor = goFloor;
      inherit pkgs;
      pname = "otel-tui";
    }).overridePackage
    pkgs.otel-tui)
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
          inherit pkgs;
          pname = "otel-tui";
          repo = "ymtdzzz/otel-tui";
          inherit sourcesFile;
        };
      };
  })
