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
# `fetchNpmDeps` requires one. It is regenerated per upstream release with
# `npm install --package-lock-only --ignore-scripts` in an extracted copy of
# the tarball. `.*-package-lock\.json$` is already a cspell exclusion in
# devenv.nix, which is why the file is named `aihubmix-mcp-package-lock.json`
# rather than living in a subdirectory.
#
# THE PATCH ADDS A FEATURE UPSTREAM DOES NOT HAVE: an optional `save_path`
# argument on `image_generate` that writes generated images to disk.
# Re-verified against 1.1.0 on 2026-07-27 and the capability is still absent
# — see the fork note below.
#
# ── WHY THIS PACKAGE IS PINNED AND NOT IN THE 4x/DAY SWEEP ──────────────
#
# Every prior "what is left to absorb" sweep selected by "has a
# `*-sources.json` sidecar", so this package was invisible precisely BECAUSE
# nobody had ever automated it. Absorbing it silently un-automated would
# reproduce that, so the gap is stated here and machine-detected in CI.
#
# We now track `dist-tags.latest` (1.1.0, published 2026-07-01) by operator
# decision: be current, and adapt to interface changes as they land. What is
# pinned is the RELEASE, not the currency policy — the pin exists because the
# bump is human work, not because we want to lag.
#
# THE PATCH STILL CANNOT BE AUTOMATED, measured against 1.1.0 on 2026-07-27:
#
#   1. THE CAPABILITY IS NOT NATIVE. 1.1.0's `build/tools/painting-tools.js`
#      imports no `fs` and no `path` at all; `image_generate.execute` returns
#      base64 blobs and URLs and never touches disk. The new
#      `@aihubmix/media-adapters@0.2.2` dependency does not add one either —
#      zero `fs`/`writeFile`/download hits across its whole `dist/`. And
#      `build/tools/file-tools.js` (which does have a `write_file`) is
#      COMPILED BUT NEVER REGISTERED: `build/tools/index.js` exports
#      `{...paintingTools}` only, byte-identical in both releases, and
#      `server.js` dispatches from that. So there is no native save path and
#      no in-server fallback.
#   2. THE PATCH MUST BE RE-AUTHORED ON EVERY UPSTREAM REWRITE. The 1.0.0
#      patch did not apply to 1.1.0 — `patch -p1 --dry-run` took hunk 1 with
#      fuzz and FAILED hunks 2 and 3; painting-tools.js went 288 -> 624
#      lines. No update script can re-author a patch. A
#      `config.update.targets` row would therefore land a target that goes
#      RED the next time upstream rewrites that file, permanently occupying
#      the channel reserved for TRANSIENT failures and training operators to
#      ignore it.
#
# The re-authored patch is structured to survive as much drift as it can: the
# helper and both imports are ONE contiguous prepend at the top of the file
# (upstream's first two import lines are the only context, and they survived
# the 1.0.0 -> 1.1.0 rewrite verbatim), leaving just two small anchored
# insertions below. It is still a context diff against generated build output
# and WILL break on a sufficiently large rewrite. That is the honest ceiling.
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
#      build/tools/painting-tools.js. Confirm it applies with NO fuzz —
#      `patch` accepting a hunk with fuzz means it guessed at the location.
#   2. Regenerate aihubmix-mcp-package-lock.json:
#      `npm install --package-lock-only --ignore-scripts` in an extracted
#      copy of the new tarball (npm does not publish one).
#   3. Update `upstreamVersion` + both hashes below. Never hand-write a hash:
#      set it to `lib.fakeHash`, build, and take the `got:` value.
#   4. Re-check the annotation step still derives the version correctly.
#   5. Re-check whether upstream has grown a native save-to-disk argument. If
#      it ever does, DELETE the patch, drop the `config.update.excludePatterns`
#      entry and the update.yml detector, and add a real targets row — the
#      patch is the only thing keeping this package out of the sweep.
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

  # The published npm version we carry — currently npm `dist-tags.latest`.
  # The URL embeds it, so it cannot be derived from the source: a flat
  # `fetchurl` yields the .tgz FILE, not a tree, so
  # `vu.readPackageJsonVersion` has nothing to read and `vu.mkVersion` has
  # no rev to combine. Both are therefore unused here.
  upstreamVersion = "1.1.0";
in
  buildNpmPackage {
    pname = "aihubmix-mcp";

    # `+<local>` is this repo's established local-delta separator
    # (`vu.mkVersion` emits `<upstream>+<shortrev>`). It says plainly that
    # this is not a stock upstream release, and the annotation step in
    # update.yml reads the part before `+` as the upstream version.
    version = "${upstreamVersion}+save-to-file";

    src = fetchurl {
      url = "https://registry.npmjs.org/@aihubmix/mcp/-/mcp-${upstreamVersion}.tgz";
      hash = "sha256-h6IaQ+PCk5UdzD/IIYtTIufbWiotZWrxTkCZmU9uKu0=";
    };

    # npm tarballs extract to package/
    sourceRoot = "package";

    # Pre-built JS — skip the build step.
    dontNpmBuild = true;

    # Generated via: nix run nixpkgs#prefetch-npm-deps -- package-lock.json
    npmDepsHash = "sha256-qn8MKMElLquIifuTxel3WiqHP+vRNZYNvVHR7EjhNHg=";

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
      description = "AIHubMix image- and video-generation MCP server";
      homepage = "https://www.npmjs.com/package/@aihubmix/mcp";
      license = lib.licenses.mit;
      # Plain Node, no platform-specific code. The aarch64-darwin BUILD is
      # proven only by CI's required darwin leg — this host is x86_64-linux.
      platforms = lib.platforms.unix;
      mainProgram = "aihubmix-mcp";
    };
  }
