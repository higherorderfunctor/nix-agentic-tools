# Normalized nodes have optional struct, map, list and open fields. Explicit
# open nodes accept unknown children; map nodes accept arbitrary names while
# still inspecting each value. Childless flat-path leaves are open because
# path-only schemas cannot distinguish opaque leaves from freeform containers.
{lib}: let
  inherit (builtins) attrNames head isAttrs isList stringLength substring tail;
  digits = ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"];
  dropDigits = s:
    if s != "" && builtins.elem (substring 0 1 s) digits
    then dropDigits (substring 1 (stringLength s - 1) s)
    else s;
  stripBranches = path: let
    parts = lib.splitString "|" path;
  in
    lib.concatStrings ([(head parts)] ++ map dropDigits (tail parts));
  # Quoted JSON segments preserve literal dots; unquoted [] markers may be
  # glued to a name. This is also the syntax printed in suppression remedies.
  splitPath = path: let
    expand = segment:
      if segment == "[]"
      then ["[]"]
      else if lib.hasSuffix "[]" segment
      then expand (lib.removeSuffix "[]" segment) ++ ["[]"]
      else [segment];
  in
    lib.concatMap (part:
      if isList part
      then [(builtins.fromJSON (head part))]
      else lib.concatMap expand (builtins.filter (segment: segment != "") (lib.splitString "." part)))
    (builtins.split ''("(\\.|[^"\\])*")'' path);
  renderPath = lib.foldl' (acc: segment:
    if segment == "[]"
    then acc + "[]"
    else
      acc
      + lib.optionalString (acc != "") "."
      + (
        if segment == "*"
        then "*"
        else if builtins.match "[A-Za-z_][A-Za-z0-9_'-]*" segment != null
        then segment
        else builtins.toJSON segment
      )) "";
  insert = node: segments:
    if segments == []
    then node
    else let
      key = head segments;
    in
      node // {${key} = insert (node.${key} or {}) (tail segments);};
  normalizeTree = trie:
    {
      struct = lib.mapAttrs (_: normalizeTree) (builtins.removeAttrs trie ["*" "[]"]);
      open = trie == {};
    }
    // lib.optionalAttrs (trie ? "*") {map = normalizeTree trie."*";}
    // lib.optionalAttrs (trie ? "[]") {list = normalizeTree trie."[]";};
  fromPaths = {
    paths,
    names ? [],
  }:
    normalizeTree (lib.foldl' (node: path: insert node (splitPath (stripBranches path)))
      (lib.genAttrs names (_: {}))
      (
        if isAttrs paths
        then attrNames paths
        else paths
      ));
  suggest = key: candidates: let
    size = stringLength key;
    threshold =
      if size <= 4
      then 1
      else if size <= 8
      then 2
      else 3;
    scores =
      map (name: {
        inherit name;
        distance = lib.strings.levenshtein (lib.toLower key) (lib.toLower name);
      }) (builtins.filter (name: (let
        delta = stringLength name - size;
      in
        (
          if delta < 0
          then -delta
          else delta
        )
        <= threshold))
      candidates);
    best =
      lib.foldl' (acc: candidate:
        if candidate.distance <= threshold && (acc == null || candidate.distance < acc.distance)
        then candidate
        else acc)
      null
      scores;
  in
    if best == null
    then null
    else best.name;
  find = known: value: let
    walk = node: path: patternPath: current:
      if isList current
      then
        if node ? list
        then lib.concatMap (entry: walk node.list (path ++ ["[]"]) (patternPath ++ ["[]"]) entry) current
        else []
      else if isAttrs current && !(lib.isDerivation current)
      then
        lib.concatMap (key:
          if (node.struct or {}) ? ${key}
          then walk node.struct.${key} (path ++ [key]) (patternPath ++ [key]) current.${key}
          else if node ? map
          then walk node.map (path ++ [key]) (patternPath ++ ["*"]) current.${key}
          else if node.open or false
          then []
          else [
            {
              inherit key;
              path = path ++ [key];
              patternPath = patternPath ++ [key];
              siblings = attrNames (node.struct or {});
            }
          ]) (attrNames current)
      else [];
  in
    lib.unique (walk known [] [] value);
  entryStatus = known: segments:
    if segments == []
    then "declared"
    else let
      key = head segments;
      rest = tail segments;
    in
      if key == "[]" && known ? list
      then entryStatus known.list rest
      else if (known.struct or {}) ? ${key}
      then entryStatus known.struct.${key} rest
      else if known ? map
      then let
        status = entryStatus known.map rest;
      in
        if key != "*" && status == "declared"
        then "map"
        else status
      else if known.open or false
      then "freeform"
      else null;
in {
  inherit fromPaths;
  # Shared by Claude and Kiro's allowUnrecognizedSettings option descriptions.
  allowlistSyntax = ''
    Entries are dotted paths relative to the settings document. Use `*` for
    user-named map entries (`"services.*.newField"`) and glued `[]` for list
    elements (`"entries[].newField"`). Quote a literal segment containing dots
    inside the string (`"\"chat.futureSetting\""`). Warnings print the exact
    entry to add.
  '';
  inspect = {
    known,
    value,
    optionPath ? [],
    allowed ? [],
    allowOptionPath ? [],
    notes ? {},
  }: let
    entries =
      map (raw: {
        inherit raw;
        path = splitPath raw;
      })
      allowed;
    allFindings = find known value;
    matches = entry: finding: entry.path == finding.path || entry.path == finding.patternPath;
    findings = builtins.filter (finding:
      !(lib.any (entry: matches entry finding) entries))
    allFindings;
    statuses = map (entry: entry // {status = entryStatus known entry.path;}) entries;
    stale = builtins.filter (entry: entry.status != null) statuses;
    unused = builtins.filter (entry: entry.status == null && !(lib.any (matches entry) allFindings)) statuses;
    describe = finding: let
      suggestion = suggest finding.key finding.siblings;
      note = notes.${head finding.path} or null;
    in
      "${lib.showOption (optionPath ++ finding.path)}: unrecognized key"
      + lib.optionalString (suggestion != null) "; did you mean `${lib.showOption (optionPath ++ lib.init finding.path ++ [suggestion])}`?"
      + lib.optionalString (allowOptionPath != [])
      "\nTo suppress this warning, add ${lib.generators.toPretty {multiline = false;} [(renderPath finding.patternPath)]} to ${lib.showOption allowOptionPath}."
      + lib.optionalString (note != null) "\n${note}";
  in {
    inherit value;
    warnings =
      map describe findings
      ++ map (entry:
        "${lib.showOption allowOptionPath}: stale allowlist entry `${entry.raw}` "
        + (
          if entry.status == "declared"
          then "is already declared"
          else if entry.status == "map"
          then "is accepted under a user-named map"
          else "is under an unchecked freeform container"
        )
        + "; remove it.")
      stale
      ++ map (entry: "${lib.showOption allowOptionPath}: allowlist entry `${entry.raw}` matches no unrecognized setting; remove it or quote dotted segments.")
      unused;
  };
}
