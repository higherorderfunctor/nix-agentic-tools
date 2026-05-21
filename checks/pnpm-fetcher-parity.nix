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
  pnpmPackages = [
    "context7-mcp"
    "effect-mcp"
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
