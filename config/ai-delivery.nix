# Pure delivery facts for the warning readers: per surface, runtime and
# backend, whether the runtime delivers it, and for each part it does not, the
# reason and the input options a request arrives through. Neither production
# warning reader evaluates a module to import this.
{lib}: let
  schema = import ./ai-delivery-schema.nix {inherit lib;};
  inherit (schema) key keyedSurfaces modes sharedSurfaces writersOf;
  facts = import ./ai-delivery-facts.nix {inherit lib;};
  inherit (facts) absent;
  optionPaths = import ../lib/ai/option-paths.nix {inherit lib;};
  inherit (optionPaths) records;
  delivered = row: builtins.elem row.mode (records.${row.ecosystem}.surfaceSupport.${row.surface}.backends or []);
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
    schema.ecosystems)
  sharedSurfaces);
  handRows =
    schema.validateHand
    (lib.mapAttrsToList (cell: row: row // identity cell) facts.hand);
  # Every other cell delivers, unless its record withholds the surface and no
  # native writer serves it.
  derivedRows = map (cell:
    identity cell
    // (
      if supportAbsences ? ${cell} && !builtins.elem cell facts.nativeWriters
      then supportAbsences.${cell}
      else {primitive = "delivered";}
    ))
  (lib.subtractLists (builtins.attrNames facts.hand) schema.expectedKeys);
  staticGaps = row: let
    support = records.${row.ecosystem}.surfaceSupport.${row.surface} or {};
    paths =
      [["ai" row.surface]]
      ++ lib.optional ((support.backends or []) != []) (optionPaths.pool row.ecosystem row.surface);
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
  assemble = row: let
    cell = key row;
    children =
      (facts.supplements.${cell} or [])
      ++ staticGaps row
      ++ lib.optional (row.primitive != "notApplicable" && supportAbsences ? ${cell}) supportAbsences.${cell};
  in
    row
    // {inputOptions = facts.inputOptions row.surface row.ecosystem;}
    // lib.optionalAttrs (children != []) {additionalWriters = children;};
  rows = schema.validateRows (lib.sort (a: b: key a < key b) (map assemble (derivedRows ++ handRows)));
  definitions = lib.foldl' (acc: row:
    lib.recursiveUpdate acc
    (lib.setAttrByPath [row.surface row.ecosystem row.mode] (builtins.removeAttrs row ["ecosystem" "mode" "surface"]))) {}
  rows;
in
  builtins.seq rows {
    inherit definitions key keyedSurfaces modes rows writersOf;
  }
