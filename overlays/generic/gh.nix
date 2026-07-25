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
# No Go toolchain override. nixpkgs owns this derivation's builder and
# ships a `go` that satisfies cli/cli's go.mod (`go 1.26.0`,
# `toolchain go1.26.4`, against our pin's go 1.26.5), and threading a
# builder override through would perturb the byte-identical-to-nixpkgs
# derivation that is the whole point of a thin override. If a future
# release raises the floor past our pin the build fails loudly with go's
# own "go.mod requires go >= X" — `GOTOOLCHAIN=local` forbids a silent
# download — and the fix is the `goToolchainForFloor` seam that
# generic/gluetun.nix and generic/oh-my-posh.nix already carry.
#
# EXPECTED: while our pin and nixpkgs' pin name the same version,
# `pkgs.generic.gh` resolves to the SAME store path as plain `pkgs.gh`. A
# fixed-output derivation's path follows its hash, not its fetcher, and
# our `fetchzip` of the repo-archive tarball hashes the same unpacked NAR
# `fetchFromGitHub` does. That is not a bug and not a reason to delete the
# package: it exists so a gh release lands here on the 4x/day update sweep
# instead of waiting on a nixpkgs channel bump, and the paths diverge the
# moment upstream moves.
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
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchzip lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./gh-sources.json);

  # Bound once: passed to BOTH the vendor fixer and the update script, and
  # the default (`overlays/<pname>-sources.json`) is wrong for a grouped
  # subtree.
  sourcesFile = "overlays/generic/gh-sources.json";

  fixVendorHash = vu.mkGoVendorFix {
    attr = "gh";
    pkgs = ourPkgs;
    pname = "gh";
    inherit sourcesFile;
  };
in
  ourPkgs.gh.overrideAttrs (prev: {
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
        inherit fixVendorHash;
        updateScript = vu.ghArchiveUpdateScript {
          extraExtract = "${fixVendorHash}";
          pkgs = ourPkgs;
          pname = "gh";
          repo = "cli/cli";
          inherit sourcesFile;
        };
      };
  })
