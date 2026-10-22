# The `environment` surface of extracted.json from the release's CodeQL
# database: the ../ql/environment pack through `codeql.runQueries`, then
# ./environment.jq over the two decoded result sets. `transform` is the jq
# step as a script, so a check can apply it to a fixture's results. See
# ../docs/kimchi-codeql-environment.md.
{
  # The release's `passthru.codeql` (../lib/codeql.nix).
  codeql,
  pkgs,
}: let
  inherit (pkgs) lib;
  queries = pkgs.ai.devTools.codeql.mkQueryPack {
    name = "nix-agentic-tools/kimchi-environment";
    src = ../ql/environment;
  };
  # `kimchi-codeql-environment <results>`: the surface from a runner output
  # directory, or a failure naming every "fail" row.
  transform = import ../../../lib/strict-shell-application.nix pkgs {
    name = "kimchi-codeql-environment";
    runtimeInputs = [pkgs.jq];
    text = ''
      if [ "$#" -ne 1 ]; then
        echo "usage: kimchi-codeql-environment <results>" >&2
        exit 2
      fi
      jq -S -n -f ${./environment.jq} \
        --slurpfile reads "$1/EnvironmentReads.json" \
        --slurpfile overwrites "$1/LaunchOverwrites.json"
    '';
  };
  results = codeql.runQueries {
    name = "environment";
    inherit queries;
  };
in {
  inherit queries results transform;
  # The pinned release reads 237 variables. A surface far below that is a
  # source root the extractor skipped, not a release that stopped reading.
  surface = pkgs.runCommand "kimchi-codeql-environment.json" {nativeBuildInputs = [pkgs.jq];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.getExe transform} ${results} > "$out"
    jq -e '.variables | length >= 100' "$out" > /dev/null || {
      echo "kimchi-codeql-environment: environment surface fell below 100 variables" >&2
      exit 1
    }
  '';
}
