{
  lib,
  library ? null,
  modules,
  moduleArguments ? {},
  specialArguments ? {},
  job,
}: let
  effectiveLib = result.nixqlLibrary;
  model = job.moduleModel or null;
  trusted =
    library
    != null
    && model != null
    && library.narHash == job.target.fingerprint.libVersion
    && library.narHash == model.libHash
    && model.bundleHash == job.identities.model
    && builtins.any (root: root.path == library.path && root.rootContentIdentity == library.narHash) job.target.sourceRoots;
  result = import ./adapters/evalModules.nix {
    inherit lib library modules moduleArguments specialArguments;
    moduleBindings =
      if trusted
      then job.moduleBindings or []
      else [];
  };
  inherit (job) identities request;
  key = namespace: parts:
    "nixql:v1:${namespace}:" + effectiveLib.concatMapStrings (part: "${toString (builtins.stringLength part)}:${part}") parts;
  optionKey = key "option" [identities.context (builtins.toJSON request.path) identities.request];
  option = effectiveLib.attrByPath request.path null result.options;
  exists = option != null && effectiveLib.isOption option;
  selected = builtins.elem request.facet ["definitions" "selection"];
  definitions = option.definitionsWithLocations;
  labels =
    if selected
    then map (definition: definition.file) definitions
    else if request.facet == "declarations"
    then option.declarations
    else [];
  definitionKey = i: key "definition" [optionKey (toString i)];
  origin = i: key "origin" [identities.request (toString i)];
  row = relation: values: [relation values];
  observation = kind: subject: let
    identity = key "observation" [identities.request kind subject];
  in [
    (row "nx_observations" [identity identities.request "pre-apply-metadata" "observed"])
    (row "nx_observation_${kind}s" [identity subject])
  ];
  count = 1 + builtins.length labels;
  outcome =
    if !exists || (request.facet == "priority" && !option.isDefined)
    then ["failed" "option-unavailable" 0]
    else if request.facet == "selection" && request.maxDepth == 0 && labels != []
    then ["failed" "depth-limit" 0]
    else if count > request.maxNodes
    then ["failed" "node-limit" 0]
    else ["complete" "" count];
  metadata =
    effectiveLib.optionals (builtins.elem request.facet ["isDefined" "priority" "selection"]) [
      (row "nx_option_metadata" [optionKey "isDefined" (builtins.toJSON option.isDefined)])
    ]
    ++ effectiveLib.optionals (builtins.elem request.facet ["priority" "selection"] && option.isDefined) [
      (row "nx_option_priority" [optionKey (toString option.highestPrio)])
    ]
    ++ effectiveLib.concatLists (effectiveLib.imap0 (i: label:
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
          if selected
          then row "nx_definitions" [(definitionKey i) optionKey i (origin i)]
          else row "nx_option_declarations" [optionKey i (origin i)]
        )
      ]
      ++ effectiveLib.optionals selected (observation "definition" (definitionKey i))
      ++ effectiveLib.optional (request.facet == "selection" && (builtins.elemAt definitions i) ? priority)
      (row "nx_definition_order" [(definitionKey i) (toString (builtins.elemAt definitions i).priority)]))
    labels);
in {
  protocolVersion = 1;
  facts =
    [(row "nx_request_results" ([identities.request] ++ outcome))]
    ++ effectiveLib.optionals (builtins.head outcome == "complete") (
      [(row "nx_options" [optionKey identities.context (builtins.toJSON request.path)])]
      ++ observation "option" optionKey
      ++ metadata
      ++ effectiveLib.optionals (request.facet == "selection") (map (binding:
        row "nx_module_lib_bindings" [identities.request binding.functionAnchor binding.formalAnchor model.libHash model.bundleHash])
      result.nixqlModuleBindings)
    );
}
