# arkenfox user.js — the community-maintained hardened Firefox
# preference set, versioned against Firefox releases (bare numeric tags
# like `144.0`, hence `tagPrefix = ""`).
#
# `$out` is the `user.js` FILE, not a directory. That is upstream's own
# convention and is deliberate: consumers point a single preference-file
# option at it (e.g. home-manager's
# `programs.firefox.profiles.<p>.extraConfig`), so wrapping it in a
# directory would only add a path segment every consumer has to append.
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
  pkgs.stdenvNoCC.mkDerivation {
    pname = "arkenfox";
    inherit (sources) version;
    # fetchzip, so the recorded hash is over the UNPACKED NAR — which is
    # why the updateScript below prefetches with --unpack.
    src = fetchzip {inherit (sources.src) url hash;};

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mv user.js "$out"
      runHook postInstall
    '';

    passthru.updateScript = vu.ghArchiveUpdateScript {
      inherit pkgs;
      pname = "arkenfox";
      repo = "arkenfox/user.js";
      sourcesFile = repoPath ../../../../sources.json;
      # Tags are bare Firefox versions, with no `v` prefix.
      tagPrefix = "";
    };

    meta = {
      description = "Hardened Firefox user.js preference set";
      homepage = "https://github.com/arkenfox/user.js";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
