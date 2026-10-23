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
  definitionKey = i: key "definition" [optionKey (toString i)];
  origin = i: key "origin" [identities.request (toString i)];
  row = relation: args: [relation args];
  observation = kind: subject: let
    identity = key "observation" [identities.request kind subject];
  in [
    (row "nx_observations" [identity identities.request "pre-apply-metadata" "observed"])
    (row "nx_observation_${kind}s" [identity subject])
  ];
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
      lib.concatLists (lib.imap0 (i: label:
        [
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
            then row "nx_definitions" [(definitionKey i) optionKey i (origin i)]
            else row "nx_option_declarations" [optionKey i (origin i)]
          )
        ]
        ++ lib.optionals (request.facet == "definitions") (observation "definition" (definitionKey i)))
      labels);
in {
  protocolVersion = 1;
  facts =
    [(row "nx_request_results" ([identities.request] ++ outcome))]
    ++ lib.optionals observed ([
        (row "nx_options" [optionKey identities.context (builtins.toJSON request.path)])
      ]
      ++ observation "option" optionKey
      ++ metadata);
}
