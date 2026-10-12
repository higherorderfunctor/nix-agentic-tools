# The extracted facts contract (dev/fragments/extracted/facts-contract.md).
# load, merge, children, get and expect need only lib, like reconcile; an
# option module can call them before `pkgs` exists; index takes `pkgs` itself.
{lib}: let
  inherit (import ../runtime-values {inherit lib;}) classify;
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  # Well-formed only: `decided` is provenance, nothing reads it as a date.
  # The pasted placeholder `YYYY-MM-DD` has no digits, so it is refused too.
  isoDate = value:
    builtins.isString value
    && builtins.match "[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])" value != null;
  wildcard = "<name>";
  keyOf = lib.concatStringsSep ".";
  segmentsMatch = pattern: path: lib.all lib.id (lib.zipListsWith (p: s: p == wildcard || p == s) pattern path);
  # A declared key covers its whole subtree; a strict prefix only leads to one.
  covers = pattern: path: builtins.length pattern <= builtins.length path && segmentsMatch pattern path;
  leads = pattern: path: builtins.length path < builtins.length pattern && segmentsMatch pattern path;

  types = {
    bool.combine = "and";
    bool.fits = builtins.isBool;
    count.combine = "equal";
    count.fits = value: builtins.isInt value && value >= 0;
    list.combine = "equal";
    list.fits = builtins.isList;
    object.combine = "equal";
    object.fits = builtins.isAttrs;
    set.combine = "intersection";
    set.fits = value: builtins.isList value && lib.all builtins.isString value;
    string.combine = "equal";
    string.fits = builtins.isString;
  };
  everyType = builtins.attrNames types;
  # The closed combine vocabulary, less `prefer:<system>`: the types each
  # combine applies to and, for a reducer, how it reduces every system's value.
  combiners = let
    reducer = types: apply: {inherit apply types;};
  in {
    and = reducer ["bool"] (lib.all lib.id);
    equal.types = everyType;
    ignore.types = everyType;
    intersection = reducer collections (values: lib.foldl' (acc: value: lib.filter (element: builtins.elem element value) acc) (builtins.head values) (builtins.tail values));
    max = reducer ["count"] (values: lib.foldl' lib.max (builtins.head values) values);
    min = reducer ["count"] (values: lib.foldl' lib.min (builtins.head values) values);
    or = reducer ["bool"] (lib.any lib.id);
    per-platform.types = everyType;
    union = reducer collections (values: lib.unique (builtins.concatLists values));
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
      else if builtins.isAttrs node && lib.any (pattern: leads pattern path) patterns
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

    vocabulary = combiners // lib.genAttrs (map (system: "prefer:${system}") systems) (_: {types = everyType;});
    checkDecision = key: row: let
      declared = declarations ? ${key};
      type = declarations.${key}.type or null;
      combine = row.combine or null;
      known = builtins.isString combine && vocabulary ? ${combine};
    in
      lib.optional (!declared) "row for an undeclared key"
      ++ lib.optional (!known) "unknown combine ${builtins.toJSON combine}"
      ++ lib.optional (known && declared && !builtins.elem type vocabulary.${combine}.types) "combine ${combine} does not apply to type ${builtins.toJSON type}"
      ++ lib.optional (!nonBlank (row.reason or null) || builtins.match "[[:space:]]*TODO(:.*|[[:space:]]*)" row.reason != null) "reason must be non-blank and not a TODO placeholder"
      ++ lib.optional (!isoDate (row.decided or null)) "decided must be an ISO date (YYYY-MM-DD)"
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
        else types.${type}.combine or "equal";
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
        mistyped = lib.filter (system: !(types.${type}.fits or (_: false)) bySystem.${system}) (builtins.attrNames bySystem);
        prepared = lib.mapAttrs (_: prepare) bySystem;
        values = builtins.attrValues prepared;
        agreed = lib.all (value: value == builtins.head values) values;
        preferred = lib.removePrefix "prefer:" combine;
        value =
          if combine == "equal"
          then lib.optionalAttrs agreed {value = builtins.head values;}
          else if lib.hasPrefix "prefer:" combine
          then
            if prepared ? ${preferred}
            then {value = prepared.${preferred};}
            else lib.optionalAttrs (builtins.length values == 1) {value = builtins.head values;}
          else lib.optionalAttrs (combiners.${combine} ? apply) {value = finish (combiners.${combine}.apply values);};
        failure = kind: details: fix: {
          inherit details fix kind;
          key = instanceKey;
        };
        combined = lib.optionalAttrs (mistyped == []) value;
        # What left the entry without a value, for `get` to throw.
        cause = lib.findFirst (failure: failure.kind != "missing-system") null failures;
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
      in {
        inherit failures;
        entry =
          {
            inherit bySystem combine type;
            inherit (declaration) source;
          }
          // combined
          // lib.optionalAttrs (!(combined ? value) && cause != null) {failure = builtins.removeAttrs cause ["key"];};
      };
      results = lib.mapAttrs perInstance instances;
    in {
      entries = lib.optionalAttrs (combine != "ignore") (lib.mapAttrs (_: result: result.entry) results);
      failures =
        lib.optional (instances == {} && !emptied && required != []) {
          inherit key;
          details = "absent from every raw";
          fix = "delete the declaration for `${key}`";
          kind = "declared-gone";
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
          details = reasons;
          fix = "correct the decisions.json row for `${key}`";
          kind = "bad-decision";
        })
      decisionReasons)
      ++ map (key: {
        inherit key;
        details = "credential-shaped and undeclared";
        fix = "declare `${key}` in facts.json, or rename it upstream of extraction";
        kind = "undeclared-secret";
      })
      secrets;
  };
  # A key without a combined value throws its failure and fix; a
  # per-platform key has none, and is told to read per system instead.
  get = aggregate: key: let
    entry = aggregate.${key} or (throw "extracted fact `${key}` is not in the aggregate: it is undeclared, or declared and absent from every raw (declared-gone). Declare it in facts.json and extract it, or delete the declaration");
    problem =
      entry.failure or {
        details = entry.bySystem;
        fix = "per-platform: no combined value; read bySystem from the index, or add a decisions.json row that combines it";
        kind = entry.combine;
      };
  in
    entry.value or (throw "extracted fact `${key}` has no combined value (${problem.kind}): ${builtins.toJSON problem.details}. Fix: ${problem.fix}");
in {
  inherit get merge;

  children = aggregate: pattern: let
    segments = lib.splitString "." pattern;
    positions = lib.concatLists (lib.imap0 (index: segment: lib.optional (segment == wildcard) index) segments);
    matches = lib.filter (key: let
      path = lib.splitString "." key;
    in
      builtins.length path == builtins.length segments && segmentsMatch segments path)
    (builtins.attrNames aggregate);
  in
    if builtins.length positions != 1
    then throw "lib.extracted.children: `${pattern}` must contain exactly one <name> segment"
    else
      lib.listToAttrs (map (key: {
          name = builtins.elemAt (lib.splitString "." key) (builtins.head positions);
          value = get aggregate key;
        })
        matches);

  # The only reader of an owner's `extracted/` directory: its declarations,
  # its decisions, and the raw of every configured system it holds. Merged
  # against every configured system, so an absent raw is `missing-system`.
  load = {
    dir,
    secretHints ? {},
  }: let
    read = file: builtins.fromJSON (builtins.readFile (dir + "/${file}"));
    present = file: builtins.pathExists (dir + "/${file}");
    configured = import ../../config/systems.nix;
    systems = builtins.filter (system: present "${system}.json") configured;
  in
    if !present "facts.json"
    then throw "lib.extracted.load: ${toString dir}/facts.json is missing; an owner's extracted/ directory declares its keys there"
    else
      merge {
        inherit secretHints;
        declarations = read "facts.json";
        decisions = lib.optionalAttrs (present "decisions.json") (read "decisions.json");
        raws = lib.genAttrs systems (system: read "${system}.json");
        systems = configured;
      }
      // {inherit systems;};

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
        expected = builtins.removeAttrs need ["key"];
        kind = "expectation";
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
