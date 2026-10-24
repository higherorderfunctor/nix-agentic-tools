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
  graph = request.domain == "module-graph";
  occurrence = path: let
    pathJson = builtins.toJSON path;
  in {
    module = key "module" [identities.request identities.context pathJson];
    origin = key "origin" [identities.request pathJson];
  };
  emit = path: entry: let
    identity = occurrence path;
    children = effectiveLib.imap0 (i: child: emit (path ++ [i]) child) entry.imports;
    total = folded: child: folded + child.count;
    deepest = folded: child:
      if child.depth > folded
      then child.depth
      else folded;
  in {
    count = 1 + builtins.foldl' total 0 children;
    depth =
      if children == []
      then 0
      else 1 + builtins.foldl' deepest 0 children;
    rows =
      [
        (row "nx_origins" [
          identity.origin
          entry.file
          (
            if builtins.hasContext entry.file
            then "source"
            else "synthetic"
          )
        ])
        (row "nx_modules" [identity.module identities.context entry.key identity.origin entry.disabled])
      ]
      ++ observation "module" identity.module
      ++ effectiveLib.optional (builtins.length path == 1) (
        row "nx_module_roots" [identities.context (builtins.head path) identity.module]
      )
      ++ effectiveLib.optional (builtins.length path > 1) (
        row "nx_module_imports" [
          (occurrence (effectiveLib.init path)).module
          (effectiveLib.last path)
          identity.module
        ]
      )
      ++ effectiveLib.concatMap (child: child.rows) children;
  };
  graphEntries = effectiveLib.imap0 (i: entry: emit [i] entry) result.graph;
  total = folded: entry: folded + entry.count;
  deepest = folded: entry:
    if entry.depth > folded
    then entry.depth
    else folded;
  graphCount = builtins.foldl' total 0 graphEntries;
  graphDepth = builtins.foldl' deepest 0 graphEntries;
  graphOutcome =
    if !(result ? graph)
    then ["failed" "graph-unavailable" 0]
    else if 1 + graphCount > request.maxNodes
    then ["failed" "node-limit" 0]
    else if graphDepth > request.maxDepth
    then ["failed" "depth-limit" 0]
    else ["complete" "" (1 + graphCount)];
  graphRows = observation "context" identities.context ++ effectiveLib.concatMap (entry: entry.rows) graphEntries;
  count = 1 + builtins.length labels;
  outcome =
    if graph
    then graphOutcome
    else if !exists || (request.facet == "priority" && !option.isDefined)
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
      if graph
      then graphRows
      else
        [(row "nx_options" [optionKey identities.context (builtins.toJSON request.path)])]
        ++ observation "option" optionKey
        ++ metadata
        ++ effectiveLib.optionals (request.facet == "selection") (map (binding:
          row "nx_module_lib_bindings" [identities.request binding.functionAnchor binding.formalAnchor model.libHash model.bundleHash])
        result.nixqlModuleBindings)
    );
}
