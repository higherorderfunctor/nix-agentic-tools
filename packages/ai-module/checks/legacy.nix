# PR 3 chunk 2: the engine imports legacy ownership ledgers (PR 3 plan, section 2.2).
# legacy.py runs the import cases on the engine itself, then executes each
# backend's generated prune: an L136-shaped steering copy now declared as a
# link, and a unit nothing declares any more, both retire before the backend
# links anything.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  backends = import ./backends.nix {inherit harness lib pkgs;};
  generated =
    lib.mapAttrs (backend: sink: let
      prune = sink.entry (backends.evaluate backend {
        files2."steering/kept.md".content.text = "linked\n";
        legacyLedgers = [
          {
            codec = "dir";
            ledger = "materialize/steering.manifest";
            path = "steering";
          }
        ];
      }) "prune";
    in {
      inherit (prune) before;
      command = sink.command prune;
    })
    backends.sinks;
  fixture = builtins.toJSON generated;
in {
  checks.ai-module-legacy = pkgs.runCommandLocal "ai-module-legacy" {passthru = {inherit fixture;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./legacy.py} ${../lib/files}/engine.py \
      ${pkgs.writeText "ai-module-legacy.json" fixture} ${pkgs.bash}/bin/bash ${pkgs.writeText "hm-run.sh" harness.hmRunShim}
    ${pkgs.coreutils}/bin/printf 'PASS: ai-module legacy import\n' > "$out"
  '';
}
