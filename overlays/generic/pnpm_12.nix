# pnpm 12 — `pkgs.ai.generic.pnpm_12`, re-pinned onto this repo's update
# cadence off npm's `latest-12` dist-tag, exactly like its pnpm_10 /
# pnpm_11 siblings.
#
# THIS FILE DELIBERATELY DOES NOT USE ./pnpm-major.nix, and that is the
# whole point of it. Do not "unify" it back — the unification is what is
# impossible, not what is missing.
#
# pnpm 12 CHANGED ITS DISTRIBUTION MODEL. Through pnpm 11 the npm `pnpm`
# package WAS pnpm: a JavaScript bundle at `dist/pnpm.cjs` (<= 10) or
# `dist/pnpm.mjs` (11), which is what nixpkgs' pnpm expression installs
# and what ./pnpm-major.nix overrides the version and `src` of. In 12 the
# published `pnpm` tarball contains no implementation at all. Measured on
# 12.2.1: `package/pnpm` is a PLAIN TEXT FILE reading
#
#   This is a placeholder. pnpm's native binary replaces this file during
#   installation (see ./install.js).
#
# The implementation is now a native (Rust) binary published as EIGHT
# separate per-platform npm packages — `@pnpm/exe.linux-x64`,
# `@pnpm/exe.darwin-arm64`, `@pnpm/exe.linux-x64-musl`, … — pinned in the
# wrapper's `optionalDependencies` at the SAME version, and linked over
# the placeholder by a `preinstall` script. `package/dist/` is down to
# `node-gyp-bin` plus a `node_modules` of install-time helpers.
#
# So there are three consequences, and each one closes a door:
#
#   1. THERE IS NO `pkgs.pnpm_12` TO OVERRIDE. nixpkgs' own
#      pkgs/development/tools/pnpm/default.nix carries `variants` for
#      10_29_2, 10_34_0, 10 and 11 and stops — checked against nixpkgs
#      MASTER, not just this repo's pin. ./pnpm-major.nix is a thin
#      `ourPkgs.pnpm_${major}.overrideAttrs`, so for major 12 it does not
#      merely produce a wrong package, it fails to evaluate.
#
#   2. NIXPKGS' `generic.nix` CANNOT BUILD 12 EITHER, so calling it
#      directly with a 12.x version+hash is not the escape hatch it looks
#      like. Its `postUnpack` runs
#      `rm -r package/dist/reflink.*node package/dist/vendor`, and pnpm 12
#      ships neither path. Measured: the build dies in unpackPhase with
#      `rm: cannot remove 'package/dist/vendor': No such file or
#      directory`. Its `installPhase` would then symlink `bin/pnpm.mjs`,
#      which in 12 is only the Corepack entry that SPAWNS the native
#      binary — so even past the `rm` the result would be a launcher for
#      an executable that is not in the closure.
#
#   3. THE MAJOR GUARD IN ./pnpm-major.nix IS NOT THE ANSWER HERE. That
#      guard exists because nixpkgs' `passthru.majorVersion` reads the
#      ARGUMENT version and does not follow an `overrideAttrs`, so a
#      pnpm_11 derivation re-pointed at a 12.x sidecar would announce
#      `majorVersion = "11"`. Its throw message says to "add a pnpm_12
#      attribute and move it there" — this file IS that attribute, and it
#      reaches the version by a different route entirely rather than by
#      defeating the guard.
#
# WHAT THIS IS INSTEAD: the per-platform prebuilt-binary shape, the same
# one overlays/chatgpt-codex.nix uses and for the same reason — there is
# no nixpkgs base package to inherit from and the artifact is a
# self-contained executable. It is standalone `stdenv.mkDerivation` over
# the `@pnpm/exe.<platform>` tarball, NOT an `overrideAttrs`, and the
# sidecar carries per-platform {url, hash} pairs the way
# overlays/generic/bun.nix's does.
#
# BOTH PLATFORMS ARE MANDATORY, not a nicety — the same trap bun.nix
# documents. This repo's REQUIRED status checks include an
# aarch64-darwin leg, so a sidecar carrying only x86_64-linux does not
# degrade gracefully on darwin, it fails that leg at EVALUATION.
# `meta.platforms` is derived from the sidecar's system keys so the two
# can never disagree.
#
# THE VERSION IS SHARED, THE TARBALLS ARE NOT. `@pnpm/exe.*` is published
# in lockstep with `pnpm` (12.2.1 wrapper -> 12.2.1 exe, via
# optionalDependencies), which is what makes one `version` key correct
# for every platform entry. Do NOT read `@pnpm/exe.linux-x64`'s own
# `dist-tags.latest` to decide the version — it currently reads 12.0.0
# while 12.2.1 is published, so it lags the real release and would pin
# this package backwards. The version check below reads the WRAPPER's
# `latest-12` dist-tag, which is the tag that actually tracks the
# release, and the URL templates interpolate it into every platform.
#
# The URL comes from the `assets` binding + the sidecar's version, and
# only the HASH comes from the sidecar — same resolution as bun.nix and
# dns-root-hints. The sidecar is a GENERATED artifact (mkUpdateScript
# writes it out of the `platforms` templates below), so deriving the
# fetch URL back out of it would close a loop and let a hand-edited
# sidecar silently re-point what we fetch.
#
# NAMESPACED ONLY, like its siblings. This writes
# `pkgs.ai.generic.pnpm_12` and never a top-level `pkgs.pnpm_12`. There
# is no bare nixpkgs attribute of that name to shadow today, but the
# additive contract is what lets consumers adopt the overlay without
# auditing it — and nixpkgs will eventually add its own `pnpm_12`, at
# which point shadowing would become a silent conflict rather than a
# loud one.
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
  inherit (final.stdenv.hostPlatform) system;
  ourPkgs = import inputs.nixpkgs {inherit system;};
  inherit (ourPkgs) fetchurl lib stdenv;
  vu = import ../lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./pnpm_12-sources.json);

  # npm package name per Nix system. Single source for the fetch URLs,
  # the updateScript's URL templates and `meta.platforms`.
  #
  # Only the two systems this repo's CI actually gates are pinned.
  # Upstream also publishes win32-x64, win32-arm64, linux-arm64 and the
  # two `-musl` variants; adding one is a row here plus a sidecar entry,
  # and nothing else in this file changes.
  assets = {
    "aarch64-darwin" = "exe.darwin-arm64";
    "x86_64-linux" = "exe.linux-x64";
  };
  assetUrl = asset: ver: "https://registry.npmjs.org/@pnpm/${asset}/-/${asset}-${ver}.tgz";

  # URL from `assets` + the sidecar's VERSION; only the HASH from the
  # sidecar — the resolution the header describes, and the one bun.nix
  # uses. Reading `url` out of the sidecar too would close a loop: the
  # sidecar is a GENERATED artifact (mkUpdateScript writes it from the
  # `platforms` templates below, which are these same `assets`), so a
  # hand-edited `url` would silently re-point what we fetch while the
  # templates still said otherwise.
  platformSrc =
    if !(assets ? ${system} && sources ? ${system})
    then throw "pnpm_12: no source pinned for ${system} in overlays/generic/pnpm_12-sources.json"
    else
      fetchurl {
        url = assetUrl assets.${system} sources.version;
        inherit (sources.${system}) hash;
      };

  # THE MAJOR GUARD, which ./pnpm-major.nix carries for 10 and 11 and
  # which this file discussed at length in its header without actually
  # having. Nothing downstream catches it: `installCheckPhase` below
  # compares the binary's `--version` to `finalAttrs.version`, i.e. the
  # sidecar against itself, so a sidecar pinned at 13.x would build a
  # perfectly green `pkgs.ai.generic.pnpm_12` that IS pnpm 13.
  #
  # The failure mode differs from pnpm-major.nix's (there it is
  # `passthru.majorVersion` lying) but the consequence is the same: an
  # attribute whose name no longer describes what it runs.
  sidecarMajor = lib.versions.major sources.version;
in
  assert lib.assertMsg (sidecarMajor == "12") ''
    pnpm_12: overlays/generic/pnpm_12-sources.json records version "${sources.version}" (major ${sidecarMajor}), but this attribute is pnpm_12.
    Either point the sidecar back at a 12.x release, or add a pnpm_${sidecarMajor} attribute and move it there.
  '';
    stdenv.mkDerivation (finalAttrs: {
      pname = "pnpm";
      inherit (sources) version;

      # fetchurl of the npm registry tarball with NO --unpack, so the
      # recorded hash is the FLAT FILE's and mkUpdateScript stays at its
      # `unpack = false` default. stdenv's unpackPhase expands it.
      src = platformSrc;

      # Every `@pnpm/exe.*` tarball unpacks to a single `package/`
      # directory holding the binary, `package.json`, LICENSE and
      # THIRD-PARTY-NOTICES.
      sourceRoot = "package";

      # NOT decoration, and NOT only about size. Without it fixupPhase
      # strips `$out/bin/pnpm`, and on darwin that REWRITES the Mach-O:
      # measured against the real 12.2.1 darwin-arm64 artifact, 21 bytes
      # change inside `LC_CODE_SIGNATURE`, replacing the CodeDirectory
      # identifier with the output basename.
      #
      # It survives today only because the signature is ad-hoc (flags
      # 0x20002, one CodeDirectory slot, no CMS) and llvm-strip re-signs
      # after rewriting. That is llvm-strip's behavior saving us, not a
      # property of the file — if `$STRIP` ever resolved to cctools
      # `strip` instead, the ad-hoc signature would be destroyed and
      # `$out/bin/pnpm --version` would be SIGKILLed on arm64, on a
      # REQUIRED check that cannot be exercised from Linux.
      #
      # `overlays/chatgpt-codex.nix` sets this for the same reason. A
      # prebuilt binary we did not link is not ours to strip.
      dontStrip = true;

      # Linux only. The darwin artifact is a Mach-O we do not modify, so
      # its upstream signature stays intact; rewriting it would invalidate
      # that signature and buy nothing.
      nativeBuildInputs =
        [ourPkgs.installShellFiles]
        ++ lib.optionals stdenv.hostPlatform.isLinux [ourPkgs.autoPatchelfHook];

      # `libgcc_s.so.1` is the only NEEDED entry glibc does not itself
      # provide (the rest are librt/libpthread/libm/libdl/libc). Measured
      # with `patchelf --print-needed` on exe.linux-x64 12.2.1.
      #
      # Unlike overlays/claude-code.nix, autoPatchelfHook is SAFE here:
      # that binary is a Bun single-exec carrying the application in a
      # trailer after the ELF data, which section rewriting corrupts. This
      # one is an ordinary dynamically-linked Rust executable with nothing
      # appended.
      buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];

      installPhase = ''
        runHook preInstall
        install -Dm755 pnpm $out/bin/pnpm

        # `pn`, `pnpx` and `pnx` as upstream defines them for Unix. The
        # published wrapper ships these as `#!/bin/sh` scripts rather than
        # links, because the binary only self-detects its launch name on
        # Windows — on Unix `pnpx` must literally pass `dlx` through.
        #
        # Upstream's copies exec a BARE `pnpm` off PATH, which would make
        # them resolve to whatever pnpm the caller happens to have. These
        # exec this derivation's own binary by absolute path instead.
        #
        # printf rather than a heredoc on purpose: a heredoc body inside a
        # Nix indented string has to survive common-indentation stripping
        # AND keep its terminator at column 0, which is exactly the shape
        # that silently produces a mangled script. Nothing here needs
        # escaping — Nix only interpolates `''${`, so the `$@` below
        # reaches printf verbatim.
        mkAlias() {
          printf '#!%s\nexec "%s"%s "$@"\n' \
            "${stdenv.shell}" "$out/bin/pnpm" "$2" > "$out/bin/$1"
          chmod 755 "$out/bin/$1"
        }
        mkAlias pn ""
        mkAlias pnpx " dlx"
        mkAlias pnx " dlx"
        runHook postInstall
      '';

      # Shell completions, which pnpm_10 and pnpm_11 get for free from
      # nixpkgs' generic.nix `postInstall` and which this standalone
      # derivation would otherwise silently DROP — a user moving 11 -> 12
      # would just lose tab completion with nothing to point at.
      #
      # REGISTERED FROM preFixup INTO postFixupHooks, which looks
      # indirect and is the only ordering that works. Generating
      # completions RUNS the binary (upstream ships none), and on Linux
      # the binary is not runnable until autoPatchelfHook has set its
      # interpreter. That hook registers itself as
      # `postFixupHooks+=(autoPatchelfPostFixup)`, and `runHook
      # postFixup` evaluates the postFixup VARIABLE before the hooks
      # array — so a plain `postFixup` runs too early and dies with
      # "cannot execute: required file not found" (measured twice).
      # Appending here, after the setup hook has already registered
      # autoPatchelf's, orders ours second.
      #
      # Real files rather than `<(...)`: process substitution produced
      # zero-size output in the sandbox and tripped
      # installShellCompletion's own size check. The command itself is
      # fine — 254 bytes of bash completion outside the sandbox.
      #
      # NOTE the emitted script invokes a BARE `pnpm` (it runs
      # `pnpm completion-server` per completion). Left alone
      # deliberately, unlike the aliases above: a completion should
      # complete for whichever pnpm is on the user's PATH, not pin
      # itself to this store path.
      preFixup = ''
        pnpmInstallCompletions() {
          export HOME="$TMPDIR"
          for sh in bash fish zsh; do
            "$out/bin/pnpm" completion "$sh" > "$TMPDIR/pnpm.$sh"
          done
          installShellCompletion --cmd pnpm \
            --bash "$TMPDIR/pnpm.bash" \
            --fish "$TMPDIR/pnpm.fish" \
            --zsh "$TMPDIR/pnpm.zsh"
        }
        postFixupHooks+=(pnpmInstallCompletions)
      '';

      # A prebuilt binary either execs or it does not, so an honest
      # `--version` is a complete check that the install produced a
      # runnable `$out/bin/pnpm` — and on Linux it is specifically the
      # proof that autoPatchelfHook found an interpreter and libgcc_s.
      #
      # The version equality is not decoration: the sidecar's `version` is
      # what builds the URL, so a mismatch means npm served a tarball for
      # a different release than the one we asked for.
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck
        got=$($out/bin/pnpm --version)
        if [ "$got" != "${finalAttrs.version}" ]; then
          echo "pnpm_12: binary reports $got, sidecar pins ${finalAttrs.version}" >&2
          exit 1
        fi
        # `pnpx` is the alias most likely to rot, because it is the one
        # that injects a subcommand rather than forwarding verbatim.
        $out/bin/pnpx --help >/dev/null
        runHook postInstallCheck
      '';

      passthru.updateScript = vu.mkUpdateScript {
        pkgs = ourPkgs;
        platforms = builtins.mapAttrs (_: assetUrl) assets;
        pname = "pnpm_12";
        sourcesFile = "overlays/generic/pnpm_12-sources.json";
        # npm's dist-tags already express "latest within major 12", so the
        # check reads the tag directly instead of filtering the full
        # package document by major. This reads the WRAPPER package, not
        # `@pnpm/exe.*` — see the header for why that distinction matters.
        #
        # `// empty` matters: a missing dist-tag makes `jq -r` print the
        # string "null", which would sail past mkUpdateScript's emptiness
        # guard and send the prefetch after `exe.linux-x64-null.tgz`.
        # Emitting nothing instead makes a retired `latest-12` fail loud
        # on the guard.
        #
        # Absolute store paths: this string is interpolated into a
        # writeShellScript wrapper, which the update pipeline invokes
        # directly and which therefore cannot assume a PATH.
        versionCheck.cmd = "${ourPkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/pnpm | ${ourPkgs.jq}/bin/jq -r '.[\"dist-tags\"][\"latest-12\"] // empty'";
      };

      meta = {
        description = "Fast, disk-space-efficient JavaScript package manager (12.x)";
        homepage = "https://pnpm.io/";
        changelog = "https://github.com/pnpm/pnpm/releases/tag/v${finalAttrs.version}";
        license = lib.licenses.mit;
        mainProgram = "pnpm";
        # Derived from the sidecar's system keys, so a platform can never
        # be claimed here without a pinned source behind it.
        platforms = builtins.attrNames (builtins.removeAttrs sources ["version"]);
        sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      };
    })
