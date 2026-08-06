# otel-tui — the terminal OpenTelemetry viewer, re-pinned onto this
# repo's update cadence. Same shape as dev-tools/gh.nix: a thin
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
# dev-tools/gh.nix: `mkUpdateScript` rebuilds the sidecar from scratch on
# every write, so `vu.mkGoVendorFix` runs as `extraExtract` right after
# and the read is `sources.vendorHash or fakeHash` to cover the window
# between the two.
#
# The Go TOOLCHAIN is derived from the go.mod floor, via `vu.mkGoBuilder`
# — same shape as dev-tools/gh.nix, and reached with `.override` because a
# toolchain is a builder argument that `overrideAttrs` cannot touch. This
# header used to say "No Go toolchain override"; see gh.nix for why that
# reasoning did not survive measurement.
#
# WHY THIS PACKAGE EXISTS: update CADENCE. A release lands here on the
# 4x/day sweep instead of waiting on a nixpkgs channel bump. It is NOT
# here to be ahead of nixpkgs at any given moment, and the gap is often
# zero — that is expected and is not a reason to delete the package.
#
# Do not re-add a claim that this resolves to the same store path as plain
# `pkgs.otel-tui`. It does not, measured at equal versions; see gh.nix.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (Apache-2.0). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  # go-overlay is applied INSIDE this import so `go-bin` resolves against
  # our own pin; it is purely additive (`pkgs.go` is byte-identical with
  # and without it), so it moves no derivation.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./otel-tui-sources.json);

  # Bound once: passed to BOTH the vendor fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/generic/otel-tui-sources.json";

  fixVendorHash = vu.mkGoVendorFix {
    attr = "otel-tui";
    pkgs = ourPkgs;
    pname = "otel-tui";
    inherit sourcesFile;
  };

  fixGoFloor = vu.mkGoFloorFix {
    attr = "otel-tui";
    pkgs = ourPkgs;
    pname = "otel-tui";
    inherit sourcesFile;
  };

  # DERIVED from the pinned source's go.mod by `fixGoFloor`, never
  # hand-written. See `vu.mkGoFloorFix` for why, and
  # `checks/go-floor-drift.nix` for the gate that keeps it honest.
  goFloor = sources.goFloor or vu.goFloorUnknown;
in
  # TWO override seams — the toolchain is a BUILDER argument reachable
  # only via `.override`, while version/src/vendorHash are ordinary attrs
  # composed on the output. See gh.nix and the overlays fragment.
  (ourPkgs.otel-tui.override {
    buildGoModule = vu.mkGoBuilder {
      floor = goFloor;
      pkgs = ourPkgs;
      pname = "otel-tui";
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
        updateScript = vu.ghArchiveUpdateScript {
          # ORDER: hash fixer first, then the floor. `fixGoFloor` builds
          # `.src`, so anything restoring a src hash lands before it.
          extraExtract = ''
            ${fixVendorHash}
            ${fixGoFloor}
          '';
          pkgs = ourPkgs;
          pname = "otel-tui";
          repo = "ymtdzzz/otel-tui";
          inherit sourcesFile;
        };
      };
  })
