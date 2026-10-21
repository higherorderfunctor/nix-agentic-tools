# The `network` fact: every outbound network call site in Kimchi and pi, from
# the query pack under ../ql/network with the model packs under ../ql/models,
# run through ./codeql.nix `runQueries` and reshaped by ./network.jq. See
# ../docs/kimchi-codeql-network.md for the models, the bundle shapes and the
# target kinds. x86_64-linux only, as the engine is.
{
  codeql,
  pkgs,
}: let
  inherit (codeql) engine;
  queries = engine.mkQueryPack {
    name = "nix-agentic-tools/kimchi-network";
    src = ../ql/network;
  };
  models = map (name:
    engine.mkModelPack {
      name = "nix-agentic-tools/kimchi-${name}-models";
      src = ../ql/models + "/${name}";
    }) ["sdk" "undici"];

  # `factOf name on`: the fact of `on`, a `databaseOf` result, as JSON.
  factOf = name: on: let
    results = codeql.runQueries {inherit models name on queries;};
  in
    pkgs.runCommand "kimchi-codeql-${name}-fact" {nativeBuildInputs = [pkgs.jq];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      jq --sort-keys -f ${./network.jq} ${results}/NetworkCallSites.json > "$out"
    '';
in {
  inherit factOf;
  fact = factOf "network" codeql.database;
}
