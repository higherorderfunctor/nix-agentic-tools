# aihubmix-mcp — AIHubMix image-generation MCP server, absorbed from the
# sibling nixos-config overlay.
#
# NOT IN NIXPKGS. Verified against THIS repo's pin:
# `inputs.nixpkgs.legacyPackages.x86_64-linux ? aihubmix-mcp` -> false. So
# there is no upstream derivation to `.override` or `overrideAttrs`, and the
# `.override`-vs-`overrideAttrs` trap that overlays/generic/bruno.nix
# documents for `lib.extendMkDerivation` builders simply does not arise —
# this is a 100%-delta fresh derivation, like overlays/generic/gluetun.nix.
# `buildNpmPackage` is called directly, so `npmDepsHash` is an INCOMING arg
# and is honored.
#
# THE SRC IS A FLAT NPM-REGISTRY TARBALL, NOT A GITHUB ARCHIVE. `fetchurl`
# of `registry.npmjs.org/@aihubmix/mcp/-/mcp-<ver>.tgz`, hashed as the FLAT
# FILE. That rules out `vu.ghArchiveUpdateScript` / `vu.ghLatestVersionCmd`
# on two independent counts: the source is not GitHub-hosted (upstream's
# package.json names github.com/inferera/aihubmix, but that repo is not what
# we fetch), and `ghArchiveUpdateScript` records a `nix-prefetch-url
# --unpack` hash, which is the UNPACKED-NAR value and would fail this
# fetcher's fixed-output check. `sourceRoot = "package"` because npm
# tarballs extract under `package/`.
#
# PREBUILT JS. The published tarball ships `build/`, so `dontNpmBuild`.
#
# THE LOCKFILE IS VENDORED because the npm tarball does not ship one and
# `fetchNpmDeps` requires one. It is byte-identical to the sibling's, which
# is what makes this absorption behavior-preserving rather than a silent
# re-resolution of every `^` range. `.*-package-lock\.json$` is already a
# cspell exclusion in devenv.nix, which is why the file is named
# `aihubmix-mcp-package-lock.json` rather than living in a subdirectory.
#
# THE PATCH ADDS A FEATURE UPSTREAM DOES NOT HAVE: an optional `save_path`
# argument on `image_generate` that writes generated images to disk. Neither
# 1.0.0 nor 1.1.0 has any equivalent (`grep -c save_path` -> 0 in both), so
# dropping it would remove a capability the consumer uses.
#
# ── WHY THIS PACKAGE IS PINNED AND NOT IN THE 4x/DAY SWEEP ──────────────
#
# Every prior "what is left to absorb" sweep selected by "has a
# `*-sources.json` sidecar", so this package was invisible precisely BECAUSE
# nobody had ever automated it. Absorbing it silently un-automated would
# reproduce that, so the gap is stated here and machine-detected in CI.
#
# Upstream is AHEAD: npm `dist-tags.latest` is 1.1.0 (published 2026-07-01);
# we pin 1.0.0. That is not an oversight — measured 2026-07-27:
#
#   1. THE LOCAL PATCH DOES NOT APPLY TO 1.1.0. `patch -p1 --dry-run` against
#      the 1.1.0 tarball: hunk 1 applies with fuzz, hunks 2 and 3 FAIL.
#      `build/tools/painting-tools.js` was rewritten, 288 -> 624 lines.
#   2. 1.1.0 IS A BREAKING INTERFACE CHANGE FOR CONSUMERS. `image_generate`'s
#      `model` enum was replaced wholesale: 1.0.0 lists five provider wire
#      names, 1.1.0 lists ~25 friendly aliases resolved through a new
#      internal registry, and NOT ONE of 1.0.0's five values survives. Every
#      existing tool call stops resolving. 1.1.0 also pulls in a new
#      `@aihubmix/media-adapters` dependency and adds video tooling.
#
# So a version bump is not a hash refresh — it needs a human to re-author the
# patch against a rewritten file and to accept a breaking tool-schema change.
# No update script can carry a local patch across an upstream rewrite. Wiring
# a `config.update.targets` row would therefore land a target that is HELD
# BACK on its very first sweep and every sweep after, permanently occupying
# the channel reserved for TRANSIENT failures and training operators to
# ignore it.
#
# Instead the gap is LOUD but cheap, joining update.yml's established
# non-blocking annotation family (the copilot-cli SEA detector, the pnpm
# new-major detector) which exists for exactly this class — movement a human
# must adjudicate. `.github/workflows/update.yml` step "Detect a newer
# @aihubmix/mcp on npm" compares `dist-tags.latest` against the version
# DERIVED from this file (never a literal) and warns 4x/day while we lag.
# `config/update-targets.nix` records the exclusion.
#
# TO BUMP (human, deliberate):
#   1. Re-author aihubmix-mcp-save-to-file.patch against the new
#      build/tools/painting-tools.js.
#   2. Regenerate aihubmix-mcp-package-lock.json:
#      `npm install --package-lock-only --ignore-scripts` in an extracted
#      copy of the new tarball (npm does not publish one).
#   3. Update `upstreamVersion` + both hashes below. Never hand-write a hash:
#      set it to `lib.fakeHash`, build, and take the `got:` value.
#   4. Re-check the annotation step still derives the version correctly.
#
# Cache-hit parity: every build input comes from THIS repo's nixpkgs pin,
# never the consumer's `final`. `final.stdenv.hostPlatform.system` is the
# only thing read from the consumer — see
# dev/fragments/overlays/overlay-pattern.md.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage fetchurl lib;
  vu = import ../lib.nix;

  # The published npm version we pin. The URL embeds it, so it cannot be
  # derived from the source: a flat `fetchurl` yields the .tgz FILE, not a
  # tree, so `vu.readPackageJsonVersion` has nothing to read and
  # `vu.mkVersion` has no rev to combine. Both are therefore unused here.
  upstreamVersion = "1.0.0";
in
  buildNpmPackage {
    pname = "aihubmix-mcp";

    # `+<local>` is this repo's established local-delta separator
    # (`vu.mkVersion` emits `<upstream>+<shortrev>`). It says plainly that
    # this is not stock 1.0.0, and the annotation step in update.yml reads
    # the part before `+` as the upstream version.
    version = "${upstreamVersion}+save-to-file";

    src = fetchurl {
      url = "https://registry.npmjs.org/@aihubmix/mcp/-/mcp-${upstreamVersion}.tgz";
      hash = "sha256-xsAssFc3Y6wJPYsxU/ZsNrBhA3QTYZOqHsv0Dw6cz3Q=";
    };

    # npm tarballs extract to package/
    sourceRoot = "package";

    # Pre-built JS — skip the build step.
    dontNpmBuild = true;

    # Generated via: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
    npmDepsHash = "sha256-bBOgia+NSuEk2cqsJr0ZnvStS04qiU7B7F0qIThKdw4=";

    # Lockfile not shipped in the tarball — use our vendored one. This runs
    # BEFORE `patches` (stdenv applies patches in patchPhase, and postPatch
    # follows), so the copy is unaffected by the patch and vice versa.
    postPatch = ''
      cp ${./aihubmix-mcp-package-lock.json} package-lock.json
    '';

    patches = [
      ./aihubmix-mcp-save-to-file.patch
    ];

    # The npm `bin` field maps `aihubmix-mcp` -> build/server.js, and
    # npmInstallHook installs it, so no explicit installPhase is needed.
    doInstallCheck = true;

    # A MARKER, not the marker-less default. `vu.mkMcpSmokeTest`'s
    # precondition is a stdio MCP binary at `$out/bin/<bin>` that produces
    # output within 2s — met. But with `marker = null` the helper only
    # asserts the process ran, and its `|| true` swallows an import-time
    # crash, which is the anti-pattern dev/fragments/mcp-servers/
    # js-server-packaging.md names. This server logs `MCP server running on
    # stdio` through winston to STDERR (never stdout, so JSON-RPC stays
    # clean) only after `initializeTools()` and `server.connect()` both
    # succeed, so the marker proves the whole module graph imported.
    installCheckPhase = vu.mkMcpSmokeTest {
      bin = "aihubmix-mcp";
      marker = "MCP server running on stdio";
    };

    meta = {
      description = "AIHubMix image-generation MCP server";
      homepage = "https://www.npmjs.com/package/@aihubmix/mcp";
      license = lib.licenses.mit;
      # Plain Node, no platform-specific code. The aarch64-darwin BUILD is
      # proven only by CI's required darwin leg — this host is x86_64-linux.
      platforms = lib.platforms.unix;
      mainProgram = "aihubmix-mcp";
    };
  }
