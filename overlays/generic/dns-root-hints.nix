# DNS root hints — the IANA root name server list served by InterNIC,
# installed as `$out/root.hints` for a resolver's `hint` zone (unbound's
# `root-hints`, BIND's `type hint`).
#
# Unlike every other sourced package here, the URL is VERSION-INDEPENDENT:
# there is one canonical path and it is re-served whenever the root zone
# changes. The "version" is the root-zone serial stamped inside the file
# body itself, which is why the version check greps the fetched content
# rather than a tag or a release redirect, and why the URL template
# ignores its `ver` argument. `mkUpdateScript`'s per-platform mapping
# collapses to the single `src` key for the same reason — the artifact is
# platform-independent.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (public domain). ensureUnfreeCheck in default.nix passes free
# packages through unwrapped.
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
  inherit (ourPkgs) fetchurl lib;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./dns-root-hints-sources.json);

  url = "https://www.internic.net/domain/named.root";
in
  ourPkgs.stdenvNoCC.mkDerivation {
    pname = "dns-root-hints";
    inherit (sources) version;
    # fetchurl of a single flat file, so the recorded hash is the FILE's
    # — no --unpack on the prefetch below, unlike the fetchzip packages
    # in this directory.
    src = fetchurl {inherit (sources.src) url hash;};

    # `src` is a bare file, so there is nothing to unpack and no source
    # tree to configure or build. Expressed with the `dont*` flags rather
    # than the legacy `phases` list, which suppresses the runHook
    # plumbing along with the phases.
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp "$src" "$out/root.hints"
      runHook postInstall
    '';

    passthru.updateScript = vu.mkUpdateScript {
      pkgs = ourPkgs;
      pname = "dns-root-hints";
      sourcesFile = "overlays/generic/dns-root-hints-sources.json";
      platforms = {
        # One platform-independent artifact, and the URL carries no
        # version — hence the ignored `ver` argument.
        src = _: url;
      };
      # Absolute store paths: this string is interpolated into a
      # writeShellScript wrapper, which the update pipeline invokes
      # directly and which therefore cannot assume a PATH.
      versionCheck.cmd = "${ourPkgs.curl}/bin/curl -fsSL ${url} | ${ourPkgs.gnugrep}/bin/grep -oP 'version of root zone:\\s+\\K[0-9]{8}' | ${ourPkgs.coreutils}/bin/head -1";
    };

    meta = {
      description = "IANA DNS root name server hints (named.root)";
      homepage = "https://www.internic.net/domain/named.root";
      license = lib.licenses.publicDomain;
      platforms = lib.platforms.all;
    };
  }
