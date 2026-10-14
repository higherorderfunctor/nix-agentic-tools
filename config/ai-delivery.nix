# Pure committed delivery data plus independent consumer facts. Neither
# production warning reader evaluates a module to import this policy.
{lib}: let
  schema = import ./ai-delivery-schema.nix {inherit lib;};
  inherit (schema) ecosystems expectedKeys imperativePrimitives keyedSurfaces modes primitives sharedSurfaces surfaces writersOf;
  facts = import ./ai-delivery-facts.nix {inherit lib;};
  generated = import ./ai-delivery-generated.nix;
  inherit (facts) absent key;
  inherit (import ../lib/ai/option-paths.nix {inherit lib;}) records;
  delivered = row: builtins.elem row.mode (records.${row.ecosystem}.surfaceSupport.${row.surface}.backends or []);
  # Native writers may remain when the normalized surface is unsupported
  # (Kiro hooks/settings). Their absence becomes a diagnostic child, while a
  # cell without a native writer becomes a primary notApplicable row.
  identity = cell: let
    parts = lib.splitString "/" cell;
  in {
    ecosystem = builtins.elemAt parts 1;
    mode = builtins.elemAt parts 2;
    surface = builtins.elemAt parts 0;
  };
  supportAbsences = builtins.listToAttrs (lib.concatMap (surface:
    lib.concatMap (ecosystem:
      lib.concatMap (mode: let
        row = {inherit ecosystem mode surface;};
        support = records.${ecosystem}.surfaceSupport.${surface} or {};
      in
        lib.optional (!delivered row) (lib.nameValuePair (key row)
          ((absent (support.reason or "${ecosystem}'s surfaceSupport does not consume this shared surface."))
            // {inputOptions = [["ai" surface]];})))
      modes)
    ecosystems)
  sharedSurfaces);
  handRows =
    schema.validateSupport records
    (lib.mapAttrsToList (cell: row: row // identity cell) facts.hand);
  staticGaps = row: let
    support = records.${row.ecosystem}.surfaceSupport.${row.surface} or {};
    paths =
      [["ai" row.surface]]
      ++ lib.optional ((support.backends or []) != [])
      (["ai" row.ecosystem]
        ++ lib.optionals (builtins.elem row.surface ["environmentVariables" "shell"])
        records.${row.ecosystem}.launcherOptionsPath
        ++ [row.surface]);
  in
    lib.optionals (delivered row) (map (gap:
        (absent gap.reason)
        // {
          inputOptions =
            map (path: path ++ (gap.path or []))
            (
              if gap.rootOnly or false
              then [(builtins.head paths)]
              else paths
            );
        })
      (lib.filter (gap:
        !(gap.each or false)
        && !(gap.effective or false)
        && !(gap ? when)
        && builtins.isString gap.reason
        && builtins.elem row.mode (gap.backends or modes))
      (support.gaps or [])));
  primaryKeys = map key (generated.rows ++ handRows);
  absentRows =
    lib.mapAttrsToList (cell: row: row // identity cell)
    (builtins.removeAttrs supportAbsences primaryKeys);
  handKeys = map key handRows;
  derivedKeys = map key (generated.rows ++ absentRows);
  assemble = row: let
    cell = key row;
    children =
      (row.additionalWriters or [])
      ++ (facts.supplements.${cell} or [])
      ++ staticGaps row
      ++ lib.optional (row.primitive != "notApplicable" && supportAbsences ? ${cell}) supportAbsences.${cell};
    annotateChild = child:
      builtins.removeAttrs
      (facts.annotate (child // {inherit (row) ecosystem mode surface;}))
      ["ecosystem" "mode" "surface"];
  in
    facts.annotate row
    // facts.metadata row
    // lib.optionalAttrs (children != []) {additionalWriters = map annotateChild children;};
  validateRows = schema.validateRows {inherit derivedKeys handKeys;};
  rows = validateRows (lib.sort (a: b: key a < key b) (map assemble (generated.rows ++ absentRows ++ handRows)));
  definitions = lib.foldl' (acc: row:
    lib.recursiveUpdate acc
    (lib.setAttrByPath [row.surface row.ecosystem row.mode] (builtins.removeAttrs row ["ecosystem" "mode" "surface"]))) {}
  rows;
in
  builtins.seq rows {
    inherit definitions ecosystems expectedKeys imperativePrimitives key keyedSurfaces modes primitives rows surfaces validateRows writersOf;
    imperativeWriters = lib.filter (writer: builtins.elem writer.primitive imperativePrimitives) (lib.concatMap writersOf rows);
  }
