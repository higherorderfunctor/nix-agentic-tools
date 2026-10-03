# pnpm — shared builder for the JAVASCRIPT-DISTRIBUTED majors of
# `pkgs.ai.generic.pnpm_<N>`. Called once per major from the thin
# `pnpm_10/package.nix` / `pnpm_11/package.nix` recipes, which exist so each major keeps
# its own path for `--override-filename` in the owner registry.nix and
# its own sidecar beside it. Everything except the major itself is here:
# two files that differ only in a version number are a smell.
#
# `pnpm_12/package.nix` IS NOT A CALLER, and that is not an oversight to tidy up.
# pnpm 12 moved the implementation out of the npm package and into
# per-platform native binaries (`@pnpm/exe.<platform>`), leaving
# `package/pnpm` a placeholder text file — so overriding the JavaScript
# bundle does not fit it (nixpkgs had no `pnpm_12` at all when it landed),
# and nixpkgs' own generic expression cannot build a 12.x tarball either. It is a standalone prebuilt-binary
# derivation instead; its header carries the measurements. The guard
# below still matters for 10 and 11 and must not be relaxed on its
# account.
#
# A thin `overrideAttrs` over nixpkgs' own `pnpm_<N>` derivation:
# `version`, `src` and `passthru.updateScript` move, plus a `postPatch`
# that binds hardened shim helpers to store paths (see below). Every other
# build input, phase and hook stays whatever nixpkgs ships.
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
# Supporting package; its public role is encoded by the native recipe tree.
# earmarked repo split can lift the subtree whole.
{
  pkgs,
  packageLib,
  repoPath,
  major,
  ...
}: let
  inherit (pkgs) fetchurl;
  vu = packageLib;

  attr = "pnpm_${major}";
  sourcesFile = repoPath (../. + "/sources-${major}.json");
  sources = builtins.fromJSON (builtins.readFile (../. + "/sources-${major}.json"));

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

    # pnpm 11.28.2 hardened its generated `node_modules/.bin` shims with
    # `command -p readlink|sed|uname`, so a dependency's bin cannot shadow
    # those helpers. `command -p` ignores PATH and searches /bin:/usr/bin,
    # which a Linux build sandbox does not have: oxlint's napi shim died with
    # `sed: not found` while darwin, which has /usr/bin, built. Bind the
    # helpers to store paths instead, which keeps upstream's isolation; the
    # shims it then writes stay valid while this pnpm's store path is alive.
    # Rewritten by content, not by version, so a full or partial backport to
    # another major, or an equivalent nixpkgs patch, is handled. `printf` is a
    # shell builtin and `cygpath`/`wslpath` run only on Cygwin/WSL; any other
    # `command -p` helper left in the bundle fails the build here instead of
    # inside a consumer's build. The shims vendored under dist/node_modules/.bin
    # are not scanned: pnpm never puts its own .bin on a script's PATH.
    # Scoped in a subshell: later nixpkgs hooks in this build read unset vars.
    postPatch =
      (prev.postPatch or "")
      + ''
        (
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        bundles=0
        for bundle in dist/pnpm.cjs dist/pnpm.mjs; do
          [ -f "$bundle" ] || continue
          bundles=$((bundles + 1))
          substituteInPlace "$bundle" \
            --replace-quiet 'command -p readlink' '${pkgs.coreutils}/bin/readlink' \
            --replace-quiet 'command -p sed' '${pkgs.gnused}/bin/sed' \
            --replace-quiet 'command -p uname' '${pkgs.coreutils}/bin/uname'
          unhandled=$(grep -Eo 'command -p [A-Za-z0-9_-]+' "$bundle" | sort -u \
            | grep -Ev ' (printf|cygpath|wslpath)$' || true)
          if [ -n "$unhandled" ]; then
            echo "pnpm_${major}: unhandled shim helper(s) in $bundle: $unhandled" >&2
            false
          fi
        done
        if [ "$bundles" -eq 0 ]; then
          echo "pnpm_${major}: no dist/pnpm.cjs or dist/pnpm.mjs; the shim rewrite above found nothing to check" >&2
          false
        fi
        )
      '';

    # Merge, never replace: nixpkgs hangs `configHook`, `fetchDeps`,
    # `majorVersion`, `nodejs-slim` and `tests` here and replacing the
    # set drops all of them. See the nix-standards fragment.
    passthru =
      (prev.passthru or {})
      // {
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
