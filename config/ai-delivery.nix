# Pure delivery facts for the warning readers: per surface, runtime and
# backend, whether the runtime delivers it, and for each part it does not, the
# reason and the input options a request arrives through. Neither production
# warning reader evaluates a module to import this.
{lib}: let
  schema = import ./ai-delivery-schema.nix {inherit lib;};
  inherit (schema) key keyedSurfaces modes sharedSurfaces writersOf;
  facts = import ./ai-delivery-facts.nix {inherit lib;};
  inherit (facts) absent;
  reasonsFor = import ../lib/ai/app/supportReasons.nix;
  settingsFields = (import ../lib/ai/ai-common.nix {inherit lib;}).normalizedSettingsFields;
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
          ((absent (support.reason or (reasonsFor ecosystem).surface))
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
  settingsGaps = ecosystem: support:
    map (field:
      (absent (reasonsFor ecosystem).settingsField) // {inputOptions = [["ai" "settings" field]];})
    (lib.subtractLists (support.fields or []) settingsFields);
  # A gap outside `each` names one field of the portable root.
  staticGaps = row: let
    support = records.${row.ecosystem}.surfaceSupport.${row.surface} or {};
  in
    lib.optionals (delivered row) (
      map (gap: (absent gap.reason) // {inputOptions = [(["ai" row.surface] ++ gap.path)];})
      (lib.filter (gap: !(gap.each or false) && !(gap ? when) && builtins.isString gap.reason)
        (support.gaps or []))
      ++ lib.optionals (row.surface == "settings") (settingsGaps row.ecosystem support)
    );
  assemble = row: let
    cell = key row;
    children =
      staticGaps row
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
    inherit definitions key keyedSurfaces modes rows settingsGaps writersOf;
  }
