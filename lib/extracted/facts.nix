# The extracted facts contract (dev/fragments/extracted/facts-contract.md).
# merge, get, getFor and expect need only nixpkgs lib, like reconcile, so an
# option module can call them before `pkgs` exists; index takes `pkgs` itself.
{lib}: let
  inherit (import ../runtime-values {inherit lib;}) classify;
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  wildcard = "<name>";
  keyOf = lib.concatStringsSep ".";
  segmentsMatch = pattern: path: lib.all lib.id (lib.zipListsWith (p: s: p == wildcard || p == s) pattern path);
  # A declared key covers its whole subtree; a strict prefix only leads to one.
  covers = pattern: path: builtins.length pattern <= builtins.length path && segmentsMatch pattern path;
  leads = pattern: path: builtins.length path < builtins.length pattern && segmentsMatch pattern path;

  fits = {
    bool = builtins.isBool;
    count = value: builtins.isInt value && value >= 0;
    list = builtins.isList;
    object = builtins.isAttrs;
    set = value: builtins.isList value && lib.all builtins.isString value;
    string = builtins.isString;
  };
  defaultCombine = {
    bool = "and";
    count = "equal";
    list = "equal";
    object = "equal";
    set = "intersection";
    string = "equal";
  };
  # Combines limited to some types; every other combine applies to all types.
  combineTypes = {
    and = ["bool"];
    intersection = ["list" "set"];
    max = ["count"];
    min = ["count"];
    or = ["bool"];
    union = ["list" "set"];
  };
  combiners = {
    and = lib.all lib.id;
    intersection = values: lib.foldl' (acc: value: lib.filter (element: builtins.elem element value) acc) (builtins.head values) (builtins.tail values);
    max = values: lib.foldl' lib.max (builtins.head values) values;
    min = values: lib.foldl' lib.min (builtins.head values) values;
    or = lib.any lib.id;
    union = values: lib.unique (builtins.concatLists values);
  };
  collections = ["list" "set"];

  # Every match of a declared pattern in one raw tree. A wildcard over an
  # existing but empty object records `emptied`: its children disappeared,
  # which is not a failure.
  find = path: node: segments:
    if segments == []
    then [
      {
        inherit path;
        value = node;
      }
    ]
    else if !builtins.isAttrs node
    then []
    else let
      segment = builtins.head segments;
      rest = builtins.tail segments;
    in
      if segment == wildcard
      then
        if node == {}
        then [
          {
            inherit path;
            emptied = true;
          }
        ]
        else lib.concatLists (lib.mapAttrsToList (name: child: find (path ++ [name]) child rest) node)
      else if node ? ${segment}
      then find (path ++ [segment]) node.${segment} rest
      else [];
in {
  merge = {
    declarations,
    decisions ? {},
    raws,
    secretHints ? {},
    systems,
  }: let
    rawFor = system: raws.${system} or {};
    patterns = map (lib.splitString ".") (builtins.attrNames declarations);

    # Undeclared nodes: everything neither under a declared key nor on the
    # way to one. Leaves are listed; the classifier sees string values and
    # string-to-string maps, its documented input.
    walk = path: node: let
      children = lib.optionals (builtins.isAttrs node) (lib.concatLists (lib.mapAttrsToList (name: walk (path ++ [name])) node));
    in
      if lib.any (pattern: covers pattern path) patterns
      then []
      else if lib.any (pattern: leads pattern path) patterns
      then children
      else [{inherit path node;}] ++ children;
    loose = lib.concatMap (system: lib.concatLists (lib.mapAttrsToList (name: walk [name]) (rawFor system))) systems;
    sortedKeys = nodes: lib.sort builtins.lessThan (lib.unique (map (entry: keyOf entry.path) nodes));
    undeclared = sortedKeys (lib.filter (entry: !builtins.isAttrs entry.node || entry.node == {}) loose);
    secrets = sortedKeys (lib.filter (entry:
      (builtins.isString entry.node || (builtins.isAttrs entry.node && lib.all builtins.isString (builtins.attrValues entry.node)))
      && classify {
        inherit (entry) path;
        hints = secretHints.${keyOf entry.path} or {};
      })
    loose);

    checkDecision = key: row: let
      declared = declarations ? ${key};
      type = declarations.${key}.type or null;
      combine = row.combine or null;
      known =
        builtins.isString combine
        && (builtins.elem combine ["equal" "ignore" "per-platform"]
          || combineTypes ? ${combine}
          || lib.any (system: combine == "prefer:${system}") systems);
    in
      lib.optional (!declared) "row for an undeclared key"
      ++ lib.optional (!known) "unknown combine ${builtins.toJSON combine}"
      ++ lib.optional (known && declared && combineTypes ? ${combine} && !builtins.elem type combineTypes.${combine}) "combine ${combine} does not apply to type ${builtins.toJSON type}"
      ++ lib.optional (!nonBlank (row.reason or null)) "reason must be non-blank"
      ++ lib.optional (!(builtins.isString (row.decided or null) && builtins.match "[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])" row.decided != null)) "decided must be an ISO date (YYYY-MM-DD)"
      ++ lib.optional (row ? ignore && !(builtins.elem type collections && builtins.isList row.ignore)) "ignore needs a list on a set or list key";
    decisionReasons = lib.mapAttrs checkDecision decisions;

    perPattern = pattern: let
      key = keyOf pattern;
      declaration = declarations.${key};
      inherit (declaration) type;
      required = declaration.systems or systems;
      decision = decisions.${key} or {};
      valid = decisions ? ${key} && decisionReasons.${key} == [];
      combine =
        if valid
        then decision.combine
        else defaultCombine.${type} or "equal";
      ignored = lib.optionals valid (decision.ignore or []);
      finish =
        if type == "set"
        then values: lib.sort builtins.lessThan (lib.unique values)
        else lib.id;
      prepare = value:
        finish (
          if ignored == []
          then value
          else lib.filter (element: !builtins.elem element ignored) value
        );
      found = lib.genAttrs systems (system: find [] (rawFor system) pattern);
      matches = lib.concatMap (system:
        map (match: match // {inherit system;}) (lib.filter (match: match ? value) found.${system}))
      systems;
      emptied = lib.any (system: lib.any (match: match ? emptied) found.${system}) systems;
      instances = lib.groupBy (match: keyOf match.path) matches;
      # A child absent on a system whose parent object lacks it too has
      # disappeared there, which is not a failure; the anchor is the path
      # through the last wildcard.
      anchorLength = lib.foldl' lib.max 0 (lib.imap1 (index: segment:
        if segment == wildcard
        then index
        else 0)
      pattern);
      perInstance = instanceKey: instanceMatches: let
        inherit (builtins.head instanceMatches) path;
        bySystem = lib.listToAttrs (map (match: lib.nameValuePair match.system match.value) instanceMatches);
        missing = lib.filter (system: !bySystem ? ${system} && lib.hasAttrByPath (lib.take anchorLength path) (rawFor system)) required;
        mistyped = lib.filter (system: !(fits.${type} or (_: false)) bySystem.${system}) (builtins.attrNames bySystem);
        prepared = lib.mapAttrs (_: prepare) bySystem;
        values = builtins.attrValues prepared;
        agreed = lib.all (value: value == builtins.head values) values;
        preferred = lib.removePrefix "prefer:" combine;
        value =
          if combine == "equal"
          then lib.optionalAttrs agreed {value = builtins.head values;}
          else if lib.hasPrefix "prefer:" combine
          then lib.optionalAttrs (prepared ? ${preferred}) {value = prepared.${preferred};}
          else lib.optionalAttrs (combiners ? ${combine}) {value = finish (combiners.${combine} values);};
        failure = kind: details: fix: {
          inherit details fix kind;
          key = instanceKey;
        };
      in {
        entry =
          {
            inherit bySystem combine type;
            inherit (declaration) source;
          }
          // lib.optionalAttrs (mistyped == []) value;
        failures =
          lib.optional (missing != []) (failure "missing-system" missing "extract `${instanceKey}` on ${lib.concatStringsSep ", " missing}, or narrow its declared `systems`")
          ++ lib.optional (mistyped != []) (failure "type-mismatch" (lib.genAttrs mistyped (system: bySystem.${system})) "correct the declared type of `${key}` (declared ${builtins.toJSON type})")
          ++ lib.optional (mistyped == [] && combine == "equal" && !agreed) (failure "divergent" bySystem (builtins.toJSON {
            ${key} = {
              combine = "per-platform";
              decided = "YYYY-MM-DD";
              reason = "TODO: why `${instanceKey}` differs across systems";
            };
          }));
      };
      results = lib.mapAttrs perInstance instances;
    in
      if combine == "ignore"
      then {
        entries = {};
        failures = [];
      }
      else {
        entries = lib.mapAttrs (_: result: result.entry) results;
        failures =
          lib.optional (instances == {} && !emptied && required != []) {
            inherit key;
            kind = "declared-gone";
            details = "absent from every raw";
            fix = "delete the declaration for `${key}`";
          }
          ++ lib.concatMap (result: result.failures) (builtins.attrValues results);
      };
    patternResults = map perPattern patterns;
  in {
    inherit undeclared;
    aggregate = lib.foldl' (acc: result: acc // result.entries) {} patternResults;
    failures =
      lib.concatMap (result: result.failures) patternResults
      ++ lib.concatLists (lib.mapAttrsToList (key: reasons:
        lib.optional (reasons != []) {
          inherit key;
          kind = "bad-decision";
          details = reasons;
          fix = "correct the decisions.json row for `${key}`";
        })
      decisionReasons)
      ++ map (key: {
        inherit key;
        kind = "undeclared-secret";
        details = "credential-shaped and undeclared";
        fix = "declare `${key}` in facts.json, or rename it upstream of extraction";
      })
      secrets;
  };

  get = aggregate: key:
    if aggregate.${key}.combine == "per-platform"
    then throw "extracted fact `${key}` is per-platform: read it with getFor <system>, or add a decisions.json row that combines it"
    else aggregate.${key}.value;

  getFor = system: aggregate: key: aggregate.${key}.bySystem.${system};

  expect = {
    aggregate,
    consumer,
    needs,
  }: {
    failures = lib.concatMap (need: let
      entry = aggregate.${need.key} or null;
      actual = entry.value or null;
      met =
        entry
        != null
        && (!(need ? contains) || (builtins.isList actual && builtins.elem need.contains actual))
        && (!(need ? value) || actual == need.value);
    in
      lib.optional (!met) {
        inherit actual consumer;
        inherit (need) key;
        kind = "expectation";
        expected = builtins.removeAttrs need ["key"];
      })
    needs;
  };

  index = pkgs: owners:
    pkgs.linkFarm "extracted-facts" (
      lib.mapAttrsToList (owner: result: {
        name = "${owner}.json";
        path = pkgs.writeText "${owner}.json" (builtins.toJSON result.aggregate);
      })
      owners
      ++ [
        {
          name = "index.json";
          path = pkgs.writeText "index.json" (builtins.toJSON (lib.mapAttrs (_: result: result.aggregate) owners));
        }
      ]
    );
}
