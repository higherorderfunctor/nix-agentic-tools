# pnpm-fetcher-parity check — structural guard for the Gap 4 /
# Mode D bug class documented in
# docs/update-pipeline-transitive-hash-gap.md.
#
# Every overlay package that ships a `pnpmDeps` produced by
# `fetchPnpmDeps` MUST bind that fetcher to the same `pnpm`
# interpreter its parent buildPhase will use. If the fetcher
# defaults to nixpkgs' floating `pnpmLatest` while the parent
# pins (or also defaults to) a different `pnpm`, the fetcher's
# offline-store layout won't match what buildPhase reads →
# `ERR_PNPM_NO_OFFLINE_TARBALL` at build time (the bug that
# produced PR #160).
#
# Mechanics:
#   1. For each tracked package, locate the pnpm derivation in
#      `drv.pnpmDeps.nativeBuildInputs` (the fetcher's pnpm —
#      `fetch-pnpm-deps/default.nix:79` places its `pnpm` arg
#      directly there).
#   2. Locate the pnpm derivation in `drv.nativeBuildInputs`
#      (the parent buildPhase's pnpm — passed via
#      `mkDerivation`'s `nativeBuildInputs` or inherited from
#      the upstream nixpkgs derivation we `overrideAttrs`).
#   3. Compare `outPath`. Equal → no drift. Unequal → fail with
#      a drift report naming the offender and both pnpm versions.
#
# No equivalent `npm-fetcher-parity` is added: `fetchNpmDeps`
# uses a static Rust pre-fetcher with no nodejs binding, so the
# same bug class doesn't exist there.
{
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Overlay packages that ship a `pnpmDeps` built from
  # `fetchPnpmDeps`. Each must be reachable as a top-level
  # `self.packages.${system}.<name>` (see flake.nix's
  # grouped-namespace flattening at `pkgs.ai.mcpServers.*`).
  #
  # ENUMERATED, THOUGH THE RULE IN THE HEADER IS INTENSIONAL. The rule is
  # "every overlay package that ships a pnpmDeps", and discovering that
  # set — `filter (n: pkgSet.${n} ? pnpmDeps) (attrNames pkgSet)` — is
  # both possible and correct. It was written, run, and rejected on cost;
  # this list is what it found, plus nothing.
  #
  # Why it was rejected (measured 2026-07-25 on x86_64-linux, warm
  # store):
  #
  #   - The intensional filter forces EVERY package in
  #     `self.packages.${system}` to weak head normal form. A
  #     `stdenv.mkDerivation` result only reaches that form through
  #     `derivationStrict`, which is strict in
  #     all of its arguments — so `drv ? pnpmDeps` is not a cheap
  #     structural probe, it is a full evaluation of the derivation.
  #   - That drags IFD in with it. Run under
  #     `--option allow-import-from-derivation false` the intensional
  #     form dies with `cannot build '…-source.drv^out' during
  #     evaluation`; the two-name form evaluates clean. The offender is
  #     the `importCargoLock { lockFile = "${src}/Cargo.lock"; }` pattern
  #     used by fblog and git-branchless — and
  #     dev/fragments/overlays/overlay-pattern.md records that CI's
  #     warm-ifd step does NOT cover that shape. So the intensional form
  #     turns a structural check into one that must fetch sources over
  #     the network at eval time, un-warmed, when built on its own
  #     (`nix build .#checks.<sys>.pnpm-fetcher-parity`).
  #   - Eval cost: 2.88s user intensional vs 0.82s user for this list,
  #     with the store already warm. The gap is worse cold.
  #
  # `nix flake check` evaluates every package anyway, so in THAT context
  # the intensional form is nearly free — but the check is also built
  # standalone, and losing hermetic evaluation is not worth trading for
  # list maintenance. Revisit if warm-ifd ever covers sidecar-versioned
  # packages.
  #
  # So: when you add an overlay package that builds with pnpm, add it
  # here. oxlint was missing for exactly this reason (it was in parity —
  # fetcher and buildPhase both pnpm 10.34.5, identical store path — so
  # nothing broke, but the parity was unprotected).
  pnpmPackages = [
    "context7-mcp"
    "effect-mcp"
    "oxlint"
  ];

  # Pull pnpm out of a derivation's nativeBuildInputs by pname.
  # Both `fetchPnpmDeps`'s `pnpm` arg and consumer derivations'
  # explicit `nativeBuildInputs = [... pnpm ...]` land here.
  findPnpm = inputs:
    lib.findFirst (i: (i.pname or "") == "pnpm") null inputs;

  mkCheck = name: let
    drv = self.packages.${system}.${name};
    fetcherPnpm = findPnpm (drv.pnpmDeps.nativeBuildInputs or []);
    buildPnpm = findPnpm (drv.nativeBuildInputs or []);
  in
    if fetcherPnpm == null
    then {
      inherit name;
      reason = "no pnpm in pnpmDeps.nativeBuildInputs (unexpected — fetchPnpmDeps always threads its pnpm arg here)";
    }
    else if buildPnpm == null
    then {
      inherit name;
      reason = "no pnpm in nativeBuildInputs (unexpected — buildPhase must have pnpm available)";
    }
    else if fetcherPnpm.outPath == buildPnpm.outPath
    then null
    else {
      inherit name;
      fetcher = "${fetcherPnpm.pname}-${fetcherPnpm.version or "?"} (${fetcherPnpm.outPath})";
      build = "${buildPnpm.pname}-${buildPnpm.version or "?"} (${buildPnpm.outPath})";
    };

  drifts = lib.filter (x: x != null) (map mkCheck pnpmPackages);
in {
  pnpm-fetcher-parity = pkgs.runCommand "pnpm-fetcher-parity" {} (
    if drifts == []
    then "echo 'ok — every pnpmDeps fetcher uses the same pnpm as its consuming buildPhase' > $out"
    else let
      report = lib.concatStringsSep "\n" (map (
          d:
            if d ? reason
            then "  ${d.name}: ${d.reason}"
            else ''
              ${d.name}:
                fetcher pnpm: ${d.fetcher}
                build   pnpm: ${d.build}
            ''
        )
        drifts);
    in ''
      echo "FAIL: ${toString (builtins.length drifts)} package(s) bind fetchPnpmDeps to a different pnpm than the buildPhase:" >&2
      cat >&2 <<'DRIFT'
      ${report}
      DRIFT
      echo "" >&2
      echo "Fix: pass 'pnpm = ourPkgs.pnpm_<N>;' explicitly to fetchPnpmDeps so the" >&2
      echo "fetcher's offline-store layout matches the pnpm that buildPhase will read." >&2
      echo "See docs/update-pipeline-transitive-hash-gap.md § Mode D and Gap 4." >&2
      exit 1
    ''
  );
}
