{lib}: let
  inherit (lib) mkOption types;
  points = ["files" "linkCheck" "materialized" "secrets" "shell"];
  pointType = types.enum points;
  strings = types.listOf types.str;
  defaulted = type: default: mkOption {inherit type default;};
  nativeLists = types.submodule {
    options = {
      devenv = defaulted strings [];
      hm = defaulted strings [];
    };
  };
  nativeNames = types.submodule {
    options = {
      devenv = defaulted (types.nullOr types.str) null;
      hm = defaulted (types.nullOr types.str) null;
    };
  };
  entryType = types.submodule {
    options = {
      after = defaulted (types.listOf pointType) ["files"];
      afterNodes = defaulted nativeLists {};
      before = defaulted (types.listOf pointType) ["shell"];
      beforeNodes = defaulted nativeLists {};
      command = mkOption {type = types.lines;};
      enable = defaulted types.bool true;
      name = defaulted nativeNames {};
      runWhenDisabled = defaulted types.bool false;
    };
  };
  nativeName = backend: key: entry:
    if entry.name.${backend} != null
    then entry.name.${backend}
    else if backend == "hm"
    then "ai2-${key}"
    else "ai2:${key}";
  pointNodes = backend: secretNodes: point:
    (
      if backend == "hm"
      then {
        files = ["linkGeneration"];
        linkCheck = ["checkLinkTargets"];
        materialized = ["ai2-files-ready"];
        secrets = secretNodes;
        shell = ["ai2-ready"];
      }
      else {
        files = ["ai2:files-linked"];
        linkCheck = ["ai2:link-check"];
        materialized = ["ai2:files-ready"];
        secrets = secretNodes;
        shell = ["devenv:enterShell"];
      }
    ).${
      point
    };
  devenvAfter = secretNodes: entry:
    lib.unique (
      lib.concatMap (pointNodes "devenv" secretNodes) entry.after
      ++ entry.afterNodes.devenv
      ++ lib.optional (
        builtins.elem "linkCheck" entry.before
        && !(builtins.elem "devenv:files:cleanup" entry.beforeNodes.devenv)
      ) "devenv:files:cleanup"
    );
  fromNode = node: path:
    if builtins.head path == node
    then path
    else fromNode node (builtins.tail path);
  cycleFrom = edges: path: node:
    if builtins.elem node path
    then let
      loop = fromNode node path;
    in
      loop ++ [node]
    else
      lib.findFirst (cycle: cycle != null) null
      (map (next: cycleFrom edges (path ++ [node]) next) (edges.${node} or []));
  validate = {
    backend,
    entries,
    nativeFiles ? false,
    secretNodes,
  }: let
    keys = builtins.attrNames entries;
    names = map (key: nativeName backend key entries.${key}) keys;
    reserved =
      if backend == "hm"
      then ["ai2-files-ready" "ai2-ready" "checkLinkTargets" "linkGeneration"] ++ secretNodes
      else ["ai2:files-linked" "ai2:files-ready" "ai2:link-check" "devenv:enterShell" "devenv:files" "devenv:files:cleanup"] ++ secretNodes;
    invalid = lib.findFirst (key: builtins.match "[A-Za-z_][A-Za-z0-9_-]*" key == null) null keys;
    invalidDevenvName =
      lib.findFirst (key:
        backend == "devenv" && builtins.match "([A-Za-z0-9_-]+:)+[A-Za-z0-9_-]+" (nativeName backend key entries.${key}) == null)
      null
      keys;
    emptyCommand = lib.findFirst (key: lib.strings.trim entries.${key}.command == "") null keys;
    duplicate = lib.findFirst (name: builtins.length (builtins.filter (other: other == name) names) > 1) null names;
    blocked = lib.findFirst (name: builtins.elem name reserved) null names;
    edge = from: to: {inherit from to;};
    nodesFor = pointNodes backend secretNodes;
    pointEdges =
      if backend == "hm"
      then [
        (edge "checkLinkTargets" "linkGeneration")
        (edge "linkGeneration" "ai2-files-ready")
        (edge "ai2-files-ready" "ai2-ready")
      ]
      else
        [
          (edge "devenv:files:cleanup" "ai2:link-check")
        ]
        ++ (
          if nativeFiles
          then [
            (edge "ai2:link-check" "devenv:files")
          ]
          else [(edge "ai2:link-check" "ai2:files-linked")]
        )
        ++ lib.optional nativeFiles (edge "devenv:files" "ai2:files-linked")
        ++ [
          (edge "ai2:files-linked" "ai2:files-ready")
          (edge "ai2:files-ready" "devenv:enterShell")
        ];
    entryEdges = lib.concatMap (key: let
      entry = entries.${key};
      name = nativeName backend key entry;
    in
      map (node: edge node name) (
        if backend == "devenv"
        then devenvAfter secretNodes entry
        else lib.concatMap nodesFor entry.after ++ entry.afterNodes.hm
      )
      ++ lib.concatMap (point: map (node: edge name node) (nodesFor point)) entry.before
      ++ map (node: edge name node) entry.beforeNodes.${backend})
    keys;
    allEdges = pointEdges ++ entryEdges;
    nodes = lib.unique (map (item: item.from) allEdges ++ map (item: item.to) allEdges);
    adjacency = builtins.listToAttrs (map (node: {
        name = node;
        value = map (item: item.to) (builtins.filter (item: item.from == node) allEdges);
      })
      nodes);
    cycle = lib.findFirst (found: found != null) null (map (node: cycleFrom adjacency [] node) nodes);
  in
    if invalid != null
    then "ai.activation2: invalid entry name ${builtins.toJSON invalid}"
    else if invalidDevenvName != null
    then "ai.activation2.${invalidDevenvName}: invalid devenv name ${builtins.toJSON (nativeName backend invalidDevenvName entries.${invalidDevenvName})}"
    else if emptyCommand != null
    then "ai.activation2.${emptyCommand}: command must be nonempty"
    else if duplicate != null
    then "ai.activation2: duplicate ${backend} name ${duplicate}"
    else if blocked != null
    then "ai.activation2: reserved ${backend} name ${blocked}"
    else if cycle != null
    then "ai.activation2: cycle ${lib.concatStringsSep " -> " cycle}"
    else null;
in {
  inherit devenvAfter entryType nativeName pointNodes points validate;
}
