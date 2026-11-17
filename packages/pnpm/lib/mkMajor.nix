# pnpm — shared builder for the JAVASCRIPT-DISTRIBUTED majors of
# `pkgs.ai.generic.pnpm_<N>`. Called from the thin `pnpm_10/package.nix` /
# `pnpm_11/package.nix` recipes, which exist so each major keeps its own path
# for `--override-filename` in the owner registry.nix and its own sidecar
# beside it, and once more by pnpm_12/package.nix for the frozen pnpm 11 that
# builds its bootstrap (`sidecar`/`sources` point at sources-12-bootstrap.json,
# `updateScript = false`). Two files that differ only in a version number are
# a smell, so everything else is here.
#
# pnpm_12 itself uses nixpkgs' separate Rust expression through .override,
# with our source/cargo pins and locked compiler; see
# ../packages/ai/generic/pnpm_12/package.nix.
#
# A thin `overrideAttrs` over nixpkgs' own `pnpm_<N>` derivation: `version`
# and `src` move, and `passthru.updateScript` is replaced by ours, or removed
# when `updateScript = false`.
# Every other build input, phase and hook stays whatever nixpkgs ships.
#
# NAMESPACED ONLY. This writes `pkgs.ai.generic.pnpm_10` /
# `pkgs.ai.generic.pnpm_11` and never a top-level `pkgs.pnpm_10`. The bare
# nixpkgs attributes stay untouched, so a consumer's own packages keep
# nixpkgs' pnpm. This repository's recipes are the opposite case: they
# take `pkgs.ai.generic.pnpm_<N>` explicitly (overlay-pattern fragment).
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
# `pnpm_10/package.nix` accidentally pointed at an 11.x sidecar would therefore
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
# FROZEN BUILDERS. The pnpm_12 bootstrap builds with JavaScript pnpm 11 from
# the `builder` pin in its own sidecar, so a pnpm_11 bump neither rebuilds
# nor breaks it. That caller passes `sidecar`, `sources` and
# `updateScript = false`; passthru is outside the derivation, so the store
# path equals the shipped pnpm_11's at the same version.
#
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  major,
  sidecar ? ../. + "/sources-${major}.json",
  sources ? builtins.fromJSON (builtins.readFile sidecar),
  updateScript ? true,
  ...
}: let
  inherit (pkgs) fetchurl lib;
  vu = packageLib;

  attr = "pnpm_${major}";
  sourcesFile = repoPath sidecar;

  majorMatch = builtins.match "([0-9]+)\\..*" sources.version;
  sidecarMajor =
    if majorMatch == null
    then null
    else builtins.head majorMatch;

  drv = pkgs.${attr}.overrideAttrs (prev: {
    inherit (sources) version;
    # fetchurl of the npm registry tarball, so the recorded hash is the
    # FLAT FILE's — no --unpack on the prefetch below, unlike the
    # fetchzip packages in this directory. Same fetcher and same URL
    # nixpkgs uses, which is what makes the store-path parity noted in
    # the per-major files possible.
    src = fetchurl {inherit (sources.src) url hash;};

    # Merge, never replace: nixpkgs hangs `configHook`, `fetchDeps`,
    # `majorVersion`, `nodejs-slim` and `tests` here and replacing the
    # set drops all of them. See the nix-standards fragment. Only nixpkgs'
    # own `updateScript` goes, so a frozen builder carries none.
    passthru =
      (builtins.removeAttrs (prev.passthru or {}) ["updateScript"])
      // lib.optionalAttrs updateScript {
        updateScript = vu.mkUpdateScript {
          inherit pkgs;
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
          versionCheck.cmd = "${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${pkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-${major}\"] // empty'";
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
