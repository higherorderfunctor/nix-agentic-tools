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

  sources = builtins.fromJSON (builtins.readFile ./arkenfox-sources.json);
in
  ourPkgs.stdenvNoCC.mkDerivation {
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
      pkgs = ourPkgs;
      pname = "arkenfox";
      repo = "arkenfox/user.js";
      sourcesFile = "overlays/generic/arkenfox-sources.json";
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
