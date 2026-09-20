# Pure committed delivery data plus independent consumer facts. Neither
# production warning reader evaluates a module to import this policy.
{lib}: let
  schema = import ./ai-delivery-schema.nix {inherit lib;};
  inherit (schema) ecosystems expectedKeys imperativePrimitives modes primitives surfaces writersOf;
  facts = import ./ai-delivery-facts.nix {inherit lib;};
  generated = import ./ai-delivery-generated.nix;
  inherit (facts) key;
  handKeys = builtins.attrNames facts.hand;
  derivedKeys = map key generated.rows;
  identity = cell: let
    parts = lib.splitString "/" cell;
  in {
    ecosystem = builtins.elemAt parts 1;
    mode = builtins.elemAt parts 2;
    surface = builtins.elemAt parts 0;
  };
  assemble = row: let
    cell = key row;
    children = (row.additionalWriters or []) ++ (generated.supplements.${cell} or []) ++ (facts.supplements.${cell} or []);
    annotateChild = child:
      builtins.removeAttrs
      (facts.annotate (child // {inherit (row) ecosystem mode surface;}))
      ["ecosystem" "mode" "surface"];
  in
    facts.annotate row
    // facts.metadata row
    // lib.optionalAttrs (children != []) {additionalWriters = map annotateChild children;};
  handRows = lib.mapAttrsToList (cell: row: row // identity cell) facts.hand;
  validateRows = schema.validateRows {inherit derivedKeys handKeys;};
  rows = validateRows (lib.sort (a: b: key a < key b) (map assemble (generated.rows ++ handRows)));
  definitions = lib.foldl' (acc: row:
    lib.recursiveUpdate acc
    (lib.setAttrByPath [row.surface row.ecosystem row.mode] (builtins.removeAttrs row ["ecosystem" "mode" "surface"]))) {}
  rows;
in
  builtins.seq rows {
    inherit definitions ecosystems expectedKeys imperativePrimitives key modes primitives rows surfaces validateRows writersOf;
    imperativeWriters = lib.filter (writer: builtins.elem writer.primitive imperativePrimitives) (lib.concatMap writersOf rows);
  }
