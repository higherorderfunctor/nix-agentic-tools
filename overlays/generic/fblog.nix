# fblog — the command-line JSON log viewer, re-pinned onto this repo's
# update cadence. An `overrideAttrs` over nixpkgs' own
# `rustPlatform.buildRustPackage` derivation: `version`, `src` and
# `cargoDeps` move, everything else (hooks, versionCheckHook, meta)
# stays whatever nixpkgs ships.
#
# ONE hash, on purpose. nixpkgs carries an inline `cargoHash` alongside
# the src hash, and `ghArchiveUpdateScript` refreshes only the src hash
# in the sidecar — so a version bump would land a stale vendor hash
# every single time, which is the transitive-hash gap this repo already
# tracks as an open defect. Reading `Cargo.lock` straight out of the
# PINNED source (IFD) instead means there is nothing to keep in sync:
# the vendor set is derived from the same pin the sidecar names, and it
# self-updates with it. The `cargoHash` in the nixpkgs args is left
# alone; nothing forces the `fetchCargoVendor` it feeds once
# `cargoDeps` is overridden.
#
# `overrideAttrs` + `importCargoLock` rather than a `.override` that
# swaps out `buildRustPackage` wholesale: same result, one seam instead
# of two, and it is the shape overlays/git-tools/git-branchless.nix
# already uses for exactly this job.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (WTFPL). ensureUnfreeCheck in default.nix passes free packages
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
  inherit (ourPkgs) fetchzip;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./fblog-sources.json);

  # Bound once: `cargoDeps` reads the lock file out of this exact
  # derivation, so src and vendor set can never point at two revisions.
  # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
  # why the updateScript below prefetches with --unpack.
  src = fetchzip {inherit (sources.src) url hash;};
in
  ourPkgs.fblog.overrideAttrs (prev: {
    inherit (sources) version;
    inherit src;

    cargoDeps = ourPkgs.rustPlatform.importCargoLock {
      lockFile = "${src}/Cargo.lock";
      allowBuiltinFetchGit = true;
    };

    # Merge, never replace: buildRustPackage attaches helpers here and
    # dropping them triggers eval warnings. See the nix-standards
    # fragment.
    passthru =
      (prev.passthru or {})
      // {
        updateScript = vu.ghArchiveUpdateScript {
          pkgs = ourPkgs;
          pname = "fblog";
          repo = "brocode/fblog";
          sourcesFile = "overlays/generic/fblog-sources.json";
        };
      };
  })
