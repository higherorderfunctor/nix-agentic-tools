# Cache-hit parity check — regression test that verifies
# overlay packages produce byte-identical store paths
# regardless of which nixpkgs a consumer brings. Drift means
# the overlay binds build inputs to the consumer's pkgs set,
# so cachix substituters (which serve paths built against
# this repo's pinned nixpkgs) won't match consumer requests.
#
# How the check works:
#   A) `self.packages.${system}.<pkg>` — built against
#      `inputs.nixpkgs` (this repo's pin). This is the path
#      CI pushes to nix-agentic-tools.cachix.org.
#   B) `consumerPkgs.<group>.<pkg>` — built against
#      `inputs.nixpkgs-test` (a deliberately different pin,
#      see flake.nix) with `self.overlays.default` applied.
#      This simulates what a consumer with a different
#      nixpkgs gets.
#   C) `followedPkgs.generic.fblog` — built with the overlay's
#      `inputs.nixpkgs` substituted by `inputs.nixpkgs-test`.
#      This simulates a consumer setting `inputs.nixpkgs.follows`
#      and must differ from A, proving that configuration defeats
#      cache-hit parity.
#
# If A == B for every package, the overlay successfully
# instantiates its own pkgs from `inputs.nixpkgs` instead of
# threading through the consumer's `final`/`prev`. If A != B
# for any package, that package will cache-miss for consumers.
#
# Mapping: flake.nix flattens the grouped overlay namespaces
# (pkgs.ai, pkgs.ai.mcpServers, pkgs.ai.lspServers, pkgs.gitTools)
# into top-level `self.packages.${system}.*` for CLI ergonomics.
# The consumer side keeps the grouped shape, so each package has
# a known source namespace we compare against.
{
  inputs,
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Simulate a consumer with a different nixpkgs pin. The
  # `nixpkgs-test` input deliberately tracks a different channel
  # from our primary `nixpkgs` input. Any overlay using `final.X`
  # for build inputs would close over THIS pkgs set instead of
  # our `inputs.nixpkgs`-instantiated one.
  consumerPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [self.overlays.default];
  };

  # Simulate a consumer rewriting this flake's nixpkgs input with `follows`.
  # Unlike consumerPkgs above, the overlay itself sees nixpkgs-test as its own
  # pin, so its deliberately isolated `ourPkgs` builds move with the consumer.
  followedOverlay = import ../overlays {
    inputs = inputs // {nixpkgs = inputs.nixpkgs-test;};
  };
  followedPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [followedOverlay];
  };

  # The set of packages to compare, and the `consumerPath` attr-path under
  # `consumerPkgs` for each, comes from the merged `config.checks.cacheHitParity`
  # registry — exposed as `self.cacheHitParityTargets` and declared across
  # lib/checks.nix (the option) + config/cache-hit-parity-targets.nix (the rows,
  # plus the notes on which package classes are intentionally excluded). Each
  # registry row is `{ consumerPath = [ ... ]; }`; the standalone side is always
  # `self.packages.${system}.<name>`.

  # For packages wrapped by `ensureUnfreeCheck` (overlays/default.nix:guard),
  # the top-level outPath is a `final.symlinkJoin` of the real derivation.
  # The symlinkJoin is built by whichever pkgs set is doing the eval, so
  # its outPath naturally differs between our pin and the consumer pin.
  # But that wrapper is a small symlink farm — the heavy real build lives
  # at `drv.paths[0]`, which IS built from `ourPkgs` and must stay
  # byte-identical for cachix to serve consumers. Cache-hit parity
  # applies to the INNER path for wrapped derivations.
  realOutPath = drv:
    if drv ? paths && builtins.isList drv.paths && builtins.length drv.paths == 1
    then toString (builtins.head drv.paths)
    else drv.outPath;

  # fblog is a real Rust build whose output is known to move across these pins.
  # It is the positive control that keeps the unsupported `follows` consumer
  # configuration visible instead of letting the ordinary A/B parity check
  # silently bless it.
  followsControl = {
    name = "fblog";
    standalone = realOutPath self.packages.${system}.fblog;
    followed = realOutPath followedPkgs.generic.fblog;
  };
  followsDrifts = followsControl.standalone != followsControl.followed;

  mkCheck = {
    name,
    consumerLookup,
  }: let
    standalone = realOutPath self.packages.${system}.${name};
    consumer = realOutPath (consumerLookup consumerPkgs);
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  # A row may declare `platforms`. Absent (the default, null) means "every
  # supported system", which is every row but gluetun's. A platform-gated
  # package is not merely unbuildable elsewhere — overlays/default.nix
  # omits the ATTRIBUTE, so `self.packages.<system>.<name>` would abort
  # this whole check with attribute-missing rather than report drift.
  # Skipping costs no coverage: the package is still compared on every
  # system it exists on, and the ok message names what was skipped so a
  # row that has quietly stopped being checked anywhere is visible.
  targetsForSystem =
    lib.filterAttrs
    (_: t: t.platforms == null || lib.elem system t.platforms)
    self.cacheHitParityTargets;

  skipped = lib.attrNames (
    removeAttrs self.cacheHitParityTargets (lib.attrNames targetsForSystem)
  );

  allChecks = lib.mapAttrsToList (name: t:
    mkCheck {
      inherit name;
      consumerLookup = p: lib.getAttrFromPath t.consumerPath p;
    })
  targetsForSystem;

  allDrifts = lib.filter (x: x != null) allChecks;

  skippedNote =
    lib.optionalString (skipped != [])
    " — skipped on ${system} (platform-gated): ${lib.concatStringsSep ", " skipped}";

  # agnix's CLI / LSP / MCP variants are ONE build: overlays/agnix.nix
  # compiles all three binaries, and the -lsp/-mcp attrs only re-point
  # meta.mainProgram, so the three must share a single derivation.
  # nixpkgs injects NIX_MAIN_PROGRAM=meta.mainProgram into the build
  # env, so setting mainProgram via `overrideAttrs` (which re-runs
  # mkDerivation) forks the drv hash into three full Rust compiles. The
  # mkCheck pass above cannot catch this — each variant matches itself
  # across both pins regardless of the fork — so assert drvPath parity
  # across the three siblings directly.
  agnixVariants = ["agnix" "agnix-lsp" "agnix-mcp"];
  agnixDrvPaths = map (n: self.packages.${system}.${n}.drvPath) agnixVariants;
  agnixSiblingOk =
    builtins.all (d: d == builtins.head agnixDrvPaths) agnixDrvPaths;

  # Semble is an external pinned-package exception: both roles must retain the
  # exact llm-agents.nix derivation, including through a divergent consumer.
  # The MCP role changes only eval-time meta.mainProgram.
  sembleVariants = ["semble" "semble-mcp"];
  sembleDrvPaths = map (n: self.packages.${system}.${n}.drvPath) sembleVariants;
  sembleSiblingOk =
    builtins.all (d: d == builtins.head sembleDrvPaths) sembleDrvPaths;
  sembleUpstream = inputs.llm-agents.packages.${system}.semble;
  sembleUpstreamOk =
    self.packages.${system}.semble.drvPath
    == sembleUpstream.drvPath
    && self.packages.${system}.semble.outPath == sembleUpstream.outPath;
in {
  cache-hit-parity = pkgs.runCommand "cache-hit-parity" {} ''
    ${
      if allDrifts == [] && followsDrifts && agnixSiblingOk && sembleSiblingOk && sembleUpstreamOk
      then "echo 'ok — no unintended drift detected (every overlay package produces byte-identical store paths against both nixpkgs pins; the follows positive control drifts as expected; agnix and Semble variants share one build; Semble matches upstream)${skippedNote}' > $out"
      else
        lib.optionalString (allDrifts != []) (let
          drifts = builtins.concatStringsSep "\n" (map (d: ''
              ${d.name}:
                standalone (inputs.nixpkgs):     ${d.standalone}
                consumer   (inputs.nixpkgs-test): ${d.consumer}
            '')
            allDrifts);
        in ''
          echo "FAIL: ${toString (builtins.length allDrifts)} package(s) bind build inputs to the consumer's nixpkgs and will NOT hit cachix:" >&2
          cat >&2 <<'DRIFT'
          ${drifts}
          DRIFT
          echo "" >&2
          echo "Each affected package must use 'ourPkgs = import inputs.nixpkgs { ... }'" >&2
          echo "instead of routing build inputs through the consumer-provided 'final'/'prev'." >&2
          echo "See .claude/rules/overlays.md 'Overlay Cache-Hit Parity' section for the full pattern." >&2
        '')
        + lib.optionalString (!followsDrifts) ''
          echo 'FAIL: the follows positive control did not drift from the cache-published path:' >&2
          echo '  standalone (${followsControl.name}): ${builtins.unsafeDiscardStringContext followsControl.standalone}' >&2
          echo '  followed   (${followsControl.name}): ${builtins.unsafeDiscardStringContext followsControl.followed}' >&2
          echo 'A consumer rewriting this flake input must not appear cache-compatible.' >&2
        ''
        + lib.optionalString (!agnixSiblingOk) (
          "echo 'FAIL: agnix cli/lsp/mcp variants do NOT share one derivation:' >&2\n"
          + lib.concatStrings (lib.imap0 (
              i: n: "echo '  ${n}: ${builtins.elemAt agnixDrvPaths i}' >&2\n"
            )
            agnixVariants)
          + "echo 'They are one build (overlays/agnix.nix compiles all three binaries).' >&2\n"
          + "echo 'Set mainProgram with `agnix // {meta = agnix.meta // {mainProgram = ...;};}`,' >&2\n"
          + "echo 'NOT overrideAttrs: nixpkgs injects NIX_MAIN_PROGRAM=meta.mainProgram into the' >&2\n"
          + "echo 'build env, so overrideAttrs forks the hash into 3 redundant Rust compiles.' >&2\n"
        )
        + lib.optionalString (!sembleSiblingOk) (
          "echo 'FAIL: semble and semble-mcp do NOT share one derivation:' >&2\n"
          + lib.concatStrings (lib.imap0 (
              i: n: "echo '  ${n}: ${builtins.elemAt sembleDrvPaths i}' >&2\n"
            )
            sembleVariants)
          + "echo 'The MCP role must be a plain attr/meta overlay, never overrideAttrs.' >&2\n"
        )
        + lib.optionalString (!sembleUpstreamOk) (
          "echo 'FAIL: pkgs.ai.semble does not match the pinned llm-agents.nix output.' >&2\n"
          + "echo 'Re-export the upstream derivation directly; do not rebuild or override it.' >&2\n"
        )
        + "exit 1\n"
    }
  '';
}
