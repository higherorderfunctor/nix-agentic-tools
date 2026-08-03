# pnpm — shared builder for the majored `pkgs.ai.generic.pnpm_<N>`
# attributes. Called once per major from the thin `pnpm_10.nix` /
# `pnpm_11.nix` files, which exist so each major keeps its own path for
# `--override-filename` in config/update-targets.nix and its own sidecar
# beside it. Everything except the major itself is here: two files that
# differ only in a version number are a smell.
#
# A thin `overrideAttrs` over nixpkgs' own `pnpm_<N>` derivation: only
# `version`, `src` and `passthru.updateScript` move, so every build
# input, phase and hook stays whatever nixpkgs ships.
#
# NAMESPACED ONLY. This writes `pkgs.ai.generic.pnpm_10` /
# `pkgs.ai.generic.pnpm_11` and never a top-level `pkgs.pnpm_10`. The bare
# nixpkgs attributes stay untouched — overlays/dev-tools/oxlint.nix
# reads `ourPkgs.pnpm_10` out of a fresh `import inputs.nixpkgs` that
# does not have this overlay applied, and every consumer of the overlay
# gets an additive change they do not have to audit.
#
# WHY `src` MUST BE OVERRIDDEN, not just `version`. nixpkgs' generic.nix
# is finalAttrs-style and builds the tarball URL from
# `finalAttrs.version`, so an override that moved `version` alone would
# point the fetch at the new URL while keeping the OLD `hash` argument —
# a fixed-output mismatch on every bump. Overriding `src` outright from
# the sidecar is the only correct shape.
#
# WHY THE MAJOR GUARD BELOW IS NOT DECORATIVE. Three things in
# generic.nix read the ARGUMENT `version` rather than
# `finalAttrs.version`, so they do NOT follow an override (measured with
# a sentinel version): `passthru.majorVersion`, the `postInstall`
# completion branch, and nixpkgs' own `passthru.updateScript`. A
# `pnpm_10.nix` accidentally pointed at an 11.x sidecar would therefore
# ship a derivation running 11.x while announcing `majorVersion = "10"`,
# and consumers keying off that attribute would silently get the wrong
# interpreter. The guard turns that into an eval-time throw.
#
# `meta.changelog`, by contrast, DOES follow the override — it is built
# from `finalAttrs.version` — so there is no changelog rewrite here.
# (nixos-config's older pnpm overlay carries one; against this
# finalAttrs-style expression it is dead code. Do not port it back.)
# `passthru.configHook` likewise needs no handling: it does not rebind on
# `overrideAttrs` (byte-identical store path before and after), and it is
# deprecated in favour of the top-level `pnpmConfigHook` anyway.
#
# Not agentic-tools-specific — it lives under overlays/generic/ so the
# earmarked repo split can lift the subtree whole.
#
# Free (MIT). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  major,
  ...
}: let
  # Cache-hit parity: every build input comes from THIS repo's nixpkgs
  # pin, never the consumer's `final`. `final.stdenv.hostPlatform.system`
  # is the only thing read from the consumer — see
  # dev/fragments/overlays/overlay-pattern.md.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchurl;
  vu = import ../lib.nix;

  attr = "pnpm_${major}";
  sourcesFile = "overlays/generic/${attr}-sources.json";
  sources = builtins.fromJSON (builtins.readFile (./. + "/${attr}-sources.json"));

  majorMatch = builtins.match "([0-9]+)\\..*" sources.version;
  sidecarMajor =
    if majorMatch == null
    then null
    else builtins.head majorMatch;

  drv = ourPkgs.${attr}.overrideAttrs (prev: {
    inherit (sources) version;
    # fetchurl of the npm registry tarball, so the recorded hash is the
    # FLAT FILE's — no --unpack on the prefetch below, unlike the
    # fetchzip packages in this directory. Same fetcher and same URL
    # nixpkgs uses, which is what makes the store-path parity noted in
    # the per-major files possible.
    src = fetchurl {inherit (sources.src) url hash;};

    # Merge, never replace: nixpkgs hangs `configHook`, `fetchDeps`,
    # `majorVersion`, `nodejs-slim` and `tests` here and replacing the
    # set drops all of them. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
        updateScript = vu.mkUpdateScript {
          pkgs = ourPkgs;
          pname = attr;
          inherit sourcesFile;
          platforms = {
            # One platform-independent tarball — npm publishes a single
            # artifact — so the sidecar has a single `src` key rather
            # than per-platform ones.
            src = ver: "https://registry.npmjs.org/pnpm/-/pnpm-${ver}.tgz";
          };
          # npm's dist-tags already express "latest within major N", so
          # the check reads the tag directly instead of filtering the
          # full package document by major.
          #
          # `// empty` matters: a missing dist-tag makes `jq -r` print
          # the string "null", which would sail past mkUpdateScript's
          # emptiness guard and send the prefetch after
          # `pnpm-null.tgz`. Emitting nothing instead makes a retired
          # `latest-<major>` fail loud on the guard.
          #
          # Absolute store paths: this string is interpolated into a
          # writeShellScript wrapper, which the update pipeline invokes
          # directly and which therefore cannot assume a PATH.
          versionCheck.cmd = "${ourPkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${ourPkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-${major}\"] // empty'";
        };
      };
  });
in
  if sidecarMajor == null
  then
    throw ''
      pnpm_${major}: ${sourcesFile} records version "${sources.version}", which does not parse as a "<major>.<rest>" semver. Refusing to build a majored pnpm from an unparseable version.
    ''
  else if sidecarMajor != major
  then
    throw ''
      pnpm_${major}: ${sourcesFile} records version "${sources.version}" (major ${sidecarMajor}), but this attribute is pnpm_${major}.
      nixpkgs' passthru.majorVersion is derived from the ARGUMENT version and does NOT follow an overrideAttrs version bump, so this would ship a derivation running ${sidecarMajor}.x while announcing majorVersion = "${major}".
      Either point the sidecar back at a ${major}.x release, or add a pnpm_${sidecarMajor} attribute and move it there.
    ''
  else drv
