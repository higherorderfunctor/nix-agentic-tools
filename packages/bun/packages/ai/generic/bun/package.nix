# bun — the JavaScript runtime, re-pinned onto this repo's update
# cadence. Upstream ships pre-built release zips, so this is the
# per-platform binary shape: an `overrideAttrs` over nixpkgs' own
# derivation moving `version` and the per-platform sources, with every
# phase, hook and patch (autoPatchelf on Linux, install_name_tool +
# rcodesign on Darwin) left as nixpkgs wrote it.
#
# BOTH platforms are mandatory, not a nicety. nixpkgs resolves `src`
# through `passthru.sources.${system} or (throw "Unsupported system")`,
# and this repo's REQUIRED CI checks include an aarch64-darwin leg — so
# a sidecar carrying only x86_64-linux does not degrade on darwin, it
# fails that leg at EVALUATION. Overriding `passthru.sources` rather
# than `src` alone also keeps `meta.platforms` honest: nixpkgs derives
# it from `builtins.attrNames finalAttrs.passthru.sources`, so it now
# names exactly the two platforms we pin, and no stale-hash fetcher for
# a version we no longer ship survives in the attrset.
#
# The URL comes from the `assets` binding + the sidecar's version, and
# only the HASH comes from the sidecar. The sidecar is a GENERATED
# artifact — mkUpdateScript writes it out of the very `platforms`
# templates below — so deriving the fetch URL back out of it would
# close a loop and let a hand-edited sidecar silently re-point what we
# fetch. Same resolution as dns-root-hints.
#
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  inherit (pkgs) fetchurl;
  vu = packageLib;

  sources = builtins.fromJSON (builtins.readFile ../../../../sources.json);

  # Release-asset basename per Nix system. Single source for the fetch
  # URLs, the updateScript's URL templates and `meta.platforms`.
  assets = {
    "aarch64-darwin" = "bun-darwin-aarch64";
    "x86_64-linux" = "bun-linux-x64";
  };
  assetUrl = asset: ver: "https://github.com/oven-sh/bun/releases/download/bun-v${ver}/${asset}.zip";

  # fetchurl of a zip, so the recorded hash is the FLAT-FILE hash —
  # mkUpdateScript is left at `unpack = false` to match. nixpkgs' own
  # `sourceRoot` table unpacks the darwin archive; nothing to add here.
  platformSrcs =
    builtins.mapAttrs (
      system: asset:
        fetchurl {
          url = assetUrl asset sources.version;
          inherit (sources.${system}) hash;
        }
    )
    assets;
in
  pkgs.bun.overrideAttrs (prev: {
    inherit (sources) version;

    # Set explicitly as well as through passthru.sources below. nixpkgs'
    # own `src` reads `finalAttrs.passthru.sources.${system}` and would
    # pick the override up on its own, but a package's source is not
    # something to leave resting on fixpoint re-entry — and the message
    # is ours, naming the sidecar the reader has to edit.
    src =
      platformSrcs.${system}
      or (throw "bun: no source pinned for ${system} in packages/bun/sources.json");

    # Merge, never replace: nixpkgs attaches helpers here and dropping
    # them triggers eval warnings. See the nix-standards fragment.
    # `sources` is REPLACED within the merge on purpose — see header.
    passthru =
      (prev.passthru or {})
      // {
        sources = platformSrcs;
        updateScript = vu.mkUpdateScript {
          inherit pkgs;
          platforms = builtins.mapAttrs (_: assetUrl) assets;
          pname = "bun";
          sourcesFile = repoPath ../../../../sources.json;
          versionCheck.cmd = vu.ghLatestVersionCmd {
            inherit pkgs;
            repo = "oven-sh/bun";
            tagPrefix = "bun-v";
          };
        };
      };
  })
