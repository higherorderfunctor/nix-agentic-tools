# Catppuccin theme files for btop — four `.theme` files, no build step.
# Tagged with bare semver (`1.0.0`), hence `tagPrefix = ""`.
#
# `$out` IS the themes directory: upstream ships them under `themes/`,
# and consumers point the btop theme-directory option straight at the
# store path, so the wrapper directory is dropped rather than nested.
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
in
  pkgs.stdenv.mkDerivation {
    pname = "catppuccin-btop";
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack.
    src = fetchzip {inherit (sources.src) url hash;};

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mv themes "$out"
      runHook postInstall
    '';

    passthru.updateScript = vu.ghArchiveUpdateScript {
      inherit pkgs;
      pname = "catppuccin-btop";
      repo = "catppuccin/btop";
      sourcesFile = repoPath ../../../../sources.json;
      # Tags are bare semver, with no `v` prefix.
      tagPrefix = "";
    };

    meta = {
      description = "Catppuccin theme files for btop";
      homepage = "https://github.com/catppuccin/btop";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
