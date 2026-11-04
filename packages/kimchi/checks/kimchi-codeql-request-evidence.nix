# Hand-written expected rows exercise the release pack and database builder.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru) codeql requestEvidence;
  fixture = ./fixtures/request-evidence;
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    kimchi-codeql-request-evidence = let
      facts = requestEvidence.factsOf "request-evidence-fixture" (codeql.databaseOf "request-evidence-fixture" (fixture + "/source"));
    in
      pkgs.runCommand "kimchi-codeql-request-evidence-check" {nativeBuildInputs = [pkgs.diffutils pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        for fact in regionRegistry requestGuards resourceDefinitions; do
          jq -S . ${fixture}/expected/"$fact.json" > expected.json
          diff -u expected.json ${facts}/"$fact.json"
        done
        ${pkgs.nodejs}/bin/node ${fixture}/report.test.mjs \
          ${../extract/egress}/generate.mjs ${../sources.json}
        cp -R ${facts} "$out"
      '';
  };
}
