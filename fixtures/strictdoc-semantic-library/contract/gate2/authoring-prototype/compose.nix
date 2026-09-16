# Composition sees a list of contributions before any keyed merge.
{lib}: {
  contributions,
  edits ? [],
  required ? [],
}: let
  fail = message: throw "gate2 composition: ${message}";
  digest = value: builtins.hashString "sha256" (builtins.toJSON value);
  definitions = lib.concatMap (entry:
    map (definition: {
      inherit definition;
      inherit (entry) origin;
    })
    ((entry.bundle.declarations or []) ++ entry.bundle.rules ++ entry.bundle.views))
  contributions;
  ids = builtins.sort builtins.lessThan (lib.unique (map (d: d.definition.id) definitions));
  original = map (id: let
    same = builtins.filter (d: d.definition.id == id) definitions;
    hashes = lib.unique (map (d: digest d.definition) same);
  in
    if builtins.length hashes != 1
    then fail "conflicting definitions for ${id}"
    else {
      inherit id;
      inherit ((builtins.head same)) definition;
      expect = builtins.head hashes;
      origins = map (d: d.origin) same;
    })
  ids;
  originalIds = map (d: d.id) original;
  editsValid = lib.all (edit:
    if !(builtins.elem edit.id originalIds)
    then fail "edit of unknown ${edit.id}"
    else if builtins.length (builtins.filter (e: e.id == edit.id) edits) != 1
    then fail "competing edits for ${edit.id}"
    else if edit.expect != (builtins.head (builtins.filter (d: d.id == edit.id) original)).expect
    then fail "stale edit for ${edit.id}"
    else if !(builtins.elem edit.action ["disable" "replace"])
    then fail "unknown edit action"
    else if (edit.reason or "") == ""
    then fail "edit requires reason"
    else if edit.action == "replace" && edit.rule.id != edit.id
    then fail "replacement changed logical identity"
    else true)
  edits;
  effective = lib.concatMap (d: let
    matched = builtins.filter (e: e.id == d.id) edits;
  in
    if matched == []
    then [d]
    else let
      edit = builtins.head matched;
    in
      if edit.action == "disable"
      then []
      else [(d // {definition = edit.rule;})])
  original;
  effectiveIds = map (d: d.id) effective;
  dependencies = d:
    (d.definition.after or [])
    ++ lib.concatMap (input:
      if lib.hasPrefix "view:" input.from
      then [(lib.removePrefix "view:" input.from)]
      else [])
    (builtins.attrValues (d.definition.inputs or {}));
  visit = path: id:
    if builtins.elem id path
    then fail "dependency cycle at ${id}"
    else if !(builtins.elem id effectiveIds)
    then fail "missing dependency ${id}"
    else let
      d = builtins.head (builtins.filter (item: item.id == id) effective);
    in
      lib.all (visit (path ++ [id])) (dependencies d);
  compatibleDependencies = lib.all (d:
    lib.all (id: let
      old = builtins.filter (x: x.id == id) original;
      current = builtins.filter (x: x.id == id) effective;
      isSingleton = x:
        x.definition.contract
        == "sdoc-policy.count/v1"
        && x.definition.config.min == 1
        && x.definition.config.max == 1;
    in
      if old != [] && current != [] && isSingleton (builtins.head old)
      then
        if
          isSingleton (builtins.head current)
          && (builtins.head old).definition.config == (builtins.head current).definition.config
        then true
        else fail "replacement lost singleton guarantee ${id}"
      else true) (d.definition.after or []))
  effective;
  # Bounded known-contract protection, not a generic compatibility interpreter.
  # Only required definitions originally declaring native-dag get this guard.
  nativeMeaning = definition:
    (definition.contract or null)
    == "sdoc-policy.native-dag/v1"
    && (definition.scope or null) == "model"
    && (definition.config or null) == {}
    && (definition.inputs or null)
    == {
      candidate = {
        from = "candidate";
        schema = "sdoc-policy.model/v1";
      };
    }
    && lib.all (capability: builtins.elem capability (definition.needs or []))
    ["model.resolved-parent-child/v1" "native.all-role-dag/v1"];
  requiredMeaning = lib.all (id: let
    before = builtins.filter (d: d.id == id) original;
    after = builtins.filter (d: d.id == id) effective;
  in
    if before == [] || after == []
    then fail "missing required rule ${id}"
    else if ((builtins.head before).definition.contract or null) == "sdoc-policy.native-dag/v1"
    then
      if nativeMeaning (builtins.head before).definition && nativeMeaning (builtins.head after).definition
      then true
      else fail "required native DAG meaning changed for ${id}"
    else true)
  required;
  valid =
    compatibleDependencies
    && requiredMeaning
    && lib.all (id:
      if builtins.elem id effectiveIds
      then true
      else fail "missing required rule ${id}")
    required
    && lib.all (visit []) effectiveIds;
in
  builtins.deepSeq original (builtins.seq editsValid (builtins.seq valid {
    inherit edits;
    definitions = map (d: d.definition) effective;
    provenance =
      map (d: {
        inherit (d) id origins expect;
        effectiveDigest = digest d.definition;
      })
      effective;
    digest = digest (map (d: d.definition) effective);
  }))
