# Drift check — the committed packages/glab/extracted.json must
# match the config-key schema the packaged glab source actually declares.
# Same contract as packages/claude-code/checks/claude-code-extracted.nix and
# packages/kiro-cli/checks/kiro-cli-extracted.nix.
#
# Blocking: the HM/devenv modules generate their typed `settings` options
# from the committed sidecar, so a stale one means an option surface that
# silently disagrees with the binary — the failure mode the extraction
# exists to prevent.
#
# This check catches STALENESS only. It cannot catch a WRONG extract: the
# update pipeline regenerates the sidecar inside the same version-bump PR,
# so a bad extract is committed as the new truth and this goes green over
# it. Correctness is the job of the shape guards inside
# `passthru.extracted` (see packages/glab/packages/ai/devTools/glab/package.nix) — the scope/key/
# env-var assertions, and the Go dump's panic on an unknown Scope or
# ValueType constant.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (import ../../../lib/extracted {inherit pkgs;}) mkDriftCheck;
    extracted = self.ciPackages.${system}.glab.passthru.extracted;
    committed = ../extracted.json;
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "glab";
      sidecar = "packages/glab/extracted.json";
    };
}
