# btop — the resource monitor, re-pinned onto this repo's update
# cadence. A thin `overrideAttrs` over nixpkgs' own derivation: only
# `version`, `src` and `passthru.updateScript` move, so every build
# input, phase and hook stays whatever nixpkgs ships.
#
# EXPECTED: while our pin and nixpkgs' pin agree, `pkgs.ai.generic.btop`
# resolves to the SAME store path as plain `pkgs.btop`. A fixed-output
# derivation's path follows its hash, not its fetcher, and our fetchzip
# of the repo-archive tarball hashes the same unpacked NAR that
# nixpkgs' fetchFromGitHub does — so `src` is byte-identical and the
# rest of the derivation is untouched. That is not a bug and not a
# reason to delete the package: it exists so a btop release can land
# here on the 4x/day update sweep instead of waiting on a nixpkgs
# channel bump, and the paths diverge the moment upstream moves.
#
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchzip;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);
in
  pkgs.btop.overrideAttrs (prev: {
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack.
    src = fetchzip {inherit (sources.src) url hash;};

    # Merge, never replace: nixpkgs attaches helpers here and dropping
    # them triggers eval warnings. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
        updateScript = vu.ghArchiveUpdateScript {
          inherit pkgs;
          pname = "btop";
          repo = "aristocratos/btop";
          sourcesFile = repoPath ../../../../sources.json;
        };
      };
  })
