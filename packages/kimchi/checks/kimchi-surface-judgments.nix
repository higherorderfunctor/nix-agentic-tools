# Keep recognized judgment failures in a successful packet output for CI artifacts.
{
  lib,
  pkgs,
  self,
  ...
}: let
  extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  inherit (extracted.load {dir = ../extracted;}) aggregate;
  regionRegistry = extracted.get aggregate "regionRegistry";
  facts = pkgs.writeText "kimchi-judgment-facts.json" (builtins.toJSON {
    regionRegistry.fields = regionRegistry.fields;
    requestCallers = extracted.get aggregate "requestCallers";
  });
  system = pkgs.stdenv.hostPlatform.system;
  scripts = ../extract/judgments;
  typescript = "${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js";
  packets = pkgs.runCommand "kimchi-surface-judgment-packets" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.nodejs}/bin/node ${scripts}/check.mjs \
      --facts ${facts} \
      --verdicts ${../surface-judgments.json} \
      --tree ${self.ciPackages.${system}.kimchi.passthru.extractionSources.kimchi} \
      --typescript ${typescript} --system ${system} --out "$out"
  '';
in {
  checks.kimchi-surface-judgments = pkgs.runCommand "kimchi-surface-judgments-check" {passthru = {inherit packets;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.nodejs}/bin/node ${./surface-judgments.test.mjs} \
      --typescript ${typescript} --scripts ${scripts} --jq ${pkgs.jq}/bin/jq \
      --fixtures ${./fixtures/surface-judgments}
    ${pkgs.coreutils}/bin/cat ${packets}/diagnostics.txt
    ${pkgs.jq}/bin/jq -e '.ok' ${packets}/status.json > /dev/null
    ${pkgs.coreutils}/bin/cp ${packets}/diagnostics.txt "$out"
  '';
}
