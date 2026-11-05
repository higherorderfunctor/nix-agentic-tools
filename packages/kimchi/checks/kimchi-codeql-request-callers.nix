# Hand-written rows, checked through the release database builder and query runner.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru) codeql network;
  fixture = ./fixtures/request-callers;
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    kimchi-codeql-request-callers = let
      results = network.resultsOf "request-callers-fixture" (codeql.databaseOf "request-callers-fixture" (fixture + "/source"));
    in
      pkgs.runCommand "kimchi-codeql-request-callers-check" {nativeBuildInputs = [pkgs.diffutils pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        jq -S -f ${../lib/request-callers.jq} ${results}/RequestCallers.json > actual.json
        jq -cS '.[]' actual.json > actual.jsonl
        if ! diff -u ${fixture}/expected/requestCallers.jsonl actual.jsonl; then
          echo "Request caller rows removed (-) or added (+) above; inspect both callSite.file and site.file for cross-file cases." >&2
          echo "Read those files in checks/fixtures/request-callers/source/kimchi/src; the case comment on each file's first line names the wrong implementation." >&2
          echo "Fix RequestCallers.ql, or update hand-written expected/requestCallers.jsonl by hand after reading the fixture source." >&2
          exit 1
        fi
        cp actual.json "$out"
      '';
  };
}
