# gluetun — the multi-provider VPN client, packaged from source. Unlike
# every other entry in this directory this is a FRESH `buildGoModule`
# derivation rather than an override, because nixpkgs does not carry
# gluetun at all: there is nothing to override.
#
# UPSTREAM MOVED. The canonical repository is `passteque/gluetun`, not
# `qdm12/gluetun`. Verified against the releases/latest redirect, which
# resolves to `https://github.com/passteque/gluetun/releases/tag/v3.41.1`,
# and against the API, which reports `full_name: passteque/gluetun`. The
# old owner still works only through GitHub's rename redirect — a latent
# breakage the moment that redirect is reclaimed or retired — so both the
# archive URL and the version check name the canonical owner. The archive
# content is unaffected: both URLs prefetch to the identical unpacked NAR
# (sha256-tLfX0bIj/6XC7sSdVqFcJMOv+EChYMqakFuQiZ4WXz8=), so the rename
# costs no rebuild. The Go MODULE PATH is still `github.com/qdm12/gluetun`
# and is left alone — that is upstream's identifier, not ours to rewrite.
#
# LINUX ONLY, and this is the one package in the repo that genuinely is.
# `internal/routing` uses `unix.RT_TABLE_MAIN` / `unix.RT_TABLE_LOCAL`,
# constants `golang.org/x/sys/unix` defines on Linux and nowhere else;
# measured by cross-compiling `GOOS=darwin GOARCH=arm64 go build
# ./cmd/gluetun` against the pinned source, which fails on exactly those
# three references. So `meta.platforms` is honest, AND
# overlays/default.nix gates the ATTRIBUTE to Linux — a restrictive
# `meta.platforms` alone would make `packages.aarch64-darwin.gluetun`
# throw "not available on the requested hostPlatform" the instant its
# `drvPath` is forced, which is what this repo's required darwin CI leg
# and `nix flake check` both do. The package is simply absent there, and
# `config.checks.cacheHitParity.gluetun.platforms` says so too.
#
# `subPackages = ["cmd/gluetun"]` is load-bearing twice over: `ci/` is a
# NESTED Go module with its own go.mod that the default package sweep
# trips over, and narrowing to the one real binary also narrows the check
# phase to `cmd/gluetun`, which has no tests — so the whole `internal/*`
# test sweep, and the tun-device removal it used to need, are gone with
# it.
#
# THE GO TOOLCHAIN IS DERIVED, NOT PINNED, and so is the floor it derives
# from — do not "clean up" either. A pinned toolchain cannot tell "still
# filling a real gap" from "nixpkgs caught up and this is now a
# downgrade", and a hand-written floor is just a slower-rotting pin: the
# 4x/day sweep bumps this package and would never touch it.
#
# So `goFloor` is EXTRACTED from the pinned source's go.mod into the
# sidecar by `vu.mkGoFloorFix`, and `vu.mkGoBuilder` turns it into a
# builder. No version literals here on purpose — the sidecar holds the
# current value and `checks/go-floor-drift.nix` asserts it still matches
# source. `goToolchainForFloor` returns `ourPkgs.go` whenever our pin
# satisfies the floor, reaching for a prebuilt `go-bin` only when upstream
# outruns nixpkgs-unstable, and self-clearing the moment nixpkgs catches
# up. See overlays/lib.nix, and checks/go-toolchain-floor.nix for the
# selector's branch coverage.
#
# vendorHash lives in the SIDECAR rather than inline: `mkUpdateScript`
# rebuilds the sidecar from scratch on every write, so any key it does not
# itself produce is destroyed. `vu.mkGoVendorFix` runs as `extraExtract`
# right after and restores it; the `or fakeHash` read covers that window.
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
  # INSIDE this import, the same way overlays/agnix.nix applies
  # rust-overlay, so `go-bin` is still resolved against our own pin.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./gluetun-sources.json);

  # Bound once: passed to BOTH the vendor fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/generic/gluetun-sources.json";

  fixVendorHash = vu.mkGoVendorFix {
    attr = "gluetun";
    pkgs = ourPkgs;
    pname = "gluetun";
    inherit sourcesFile;
  };

  fixGoFloor = vu.mkGoFloorFix {
    attr = "gluetun";
    pkgs = ourPkgs;
    pname = "gluetun";
    inherit sourcesFile;
  };

  # DERIVED from the pinned source's go.mod by `fixGoFloor` above, never
  # hand-written. This used to be the literal `"1.25.0"`, which was
  # correct only for as long as someone kept re-checking it — the update
  # pipeline bumps this package 4x/day and never touched it. See
  # `vu.goFloorUnknown` for why the missing-key fallback is silent and
  # `checks/go-floor-drift.nix` for the loud half.
  goFloor = sources.goFloor or vu.goFloorUnknown;

  buildGoModule = vu.mkGoBuilder {
    floor = goFloor;
    pkgs = ourPkgs;
    pname = "gluetun";
  };
in
  buildGoModule {
    pname = "gluetun";
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack.
    src = fetchzip {inherit (sources.src) url hash;};
    vendorHash = sources.vendorHash or lib.fakeHash;

    subPackages = ["cmd/gluetun"];

    passthru = {
      inherit fixGoFloor fixVendorHash goFloor;
      updateScript = vu.ghArchiveUpdateScript {
        # ORDER: hash fixer first, then the floor. `fixGoFloor` builds
        # `.src`, so anything restoring a src hash has to land before it.
        extraExtract = ''
          ${fixVendorHash}
          ${fixGoFloor}
        '';
        pkgs = ourPkgs;
        pname = "gluetun";
        repo = "passteque/gluetun";
        inherit sourcesFile;
      };
    };

    meta = {
      description =
        "VPN client in a thin Docker container for multiple VPN providers, written in Go, and using "
        + "OpenVPN or WireGuard, DNS over TLS, with a few proxy servers built-in";
      homepage = "https://github.com/passteque/gluetun";
      license = lib.licenses.mit;
      mainProgram = "gluetun";
      platforms = lib.platforms.linux;
    };
  }
