{
  lib,
  modules,
  moduleArguments ? {},
  specialArguments ? {},
  job,
}: let
  result = import ./adapters/evalModules.nix {inherit lib modules moduleArguments specialArguments;};
  inherit (job) identities request;
  key = namespace: parts:
    "nixql:v1:${namespace}:" + lib.concatMapStrings (part: "${toString (builtins.stringLength part)}:${part}") parts;
  optionKey = key "option" [identities.context (builtins.toJSON request.path) identities.request];
  option = lib.attrByPath request.path null result.options;
  exists = option != null && lib.isOption option;
  labels =
    if request.facet == "definitions"
    then map (definition: definition.file) option.definitionsWithLocations
    else if request.facet == "declarations"
    then option.declarations
    else [];
  origin = i: key "origin" [identities.request (toString i)];
  row = relation: args: [relation args];
  observed = exists && (request.facet != "priority" || option.isDefined);
  outcome =
    if observed
    then ["complete" "" (1 + builtins.length labels)]
    else ["failed" "option-unavailable" 0];
  metadata =
    if request.facet == "priority"
    then [
      (row "nx_option_metadata" [optionKey "isDefined" "true"])
      (row "nx_option_priority" [optionKey (toString option.highestPrio)])
    ]
    else if request.facet == "isDefined"
    then [(row "nx_option_metadata" [optionKey "isDefined" (builtins.toJSON option.isDefined)])]
    else
      lib.concatLists (lib.imap0 (i: label: [
          (row "nx_origins" [
            (origin i)
            label
            (
              if builtins.hasContext label
              then "source"
              else "synthetic"
            )
          ])
          (
            if request.facet == "definitions"
            then row "nx_definitions" [(key "definition" [optionKey (toString i)]) optionKey i (origin i)]
            else row "nx_option_declarations" [optionKey i (origin i)]
          )
        ])
        labels);
in {
  protocolVersion = 1;
  facts =
    [(row "nx_request_results" ([identities.request] ++ outcome))]
    ++ lib.optionals observed ([
        (row "nx_options" [optionKey identities.context (builtins.toJSON request.path)])
        (row "nx_observations" [(key "observation" [identities.request]) identities.request "option" optionKey "pre-apply-metadata" "observed"])
      ]
      ++ metadata);
}
