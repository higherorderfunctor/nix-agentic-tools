# Shared option vocabulary and the row contract for the delivery facts.
{lib}: let
  ecosystems = import ../lib/ai/runtimes.nix;
  modes = ["devenv" "hm"];
  # Reading declaration metadata is pure: no module evaluation or pkgs needed.
  sharedOptions =
    (import ../lib/ai/sharedOptions.nix {
      inherit lib;
      config = null;
      options = null;
      pkgs = null;
    }).options.ai;
  sharedSurfaces = sharedOptions.internal.sharedSurfaces.default;
  # Permissions has no normalized root option: it inventories native policy
  # files only, whose vocabularies cannot be translated losslessly across apps.
  policyOnlySurfaces = ["permissions"];
  surfaces = lib.sort builtins.lessThan (sharedSurfaces ++ policyOnlySurfaces);
  keyedSurfaces = lib.filter (surface: sharedOptions.${surface}.keyedSurface or false) sharedSurfaces;
  key = row: "${row.surface}/${row.ecosystem}/${row.mode}";
  writersOf = row: [row] ++ lib.concatMap (writer: writersOf (writer // {inherit (row) ecosystem mode surface;})) (row.additionalWriters or []);
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  # A row either delivers its cell or states why not; the warning readers
  # print that reason and probe each input option.
  validWriter = writer:
    builtins.elem (writer.primitive or null) ["delivered" "notApplicable"]
    && (writer.primitive != "notApplicable" || nonBlank (writer.reason or ""))
    && lib.all (path: builtins.isList path && path != [] && lib.all nonBlank path) (writer.inputOptions or []);
  # A hand row is an absence on a policy-only surface. One on a shared surface
  # would silently replace the row derived from that runtime's record.
  validateHand = rows:
    assert lib.assertMsg (lib.all (row: builtins.elem row.surface policyOnlySurfaces) rows)
    "ai-delivery: hand row on a shared surface (${lib.concatMapStringsSep ", " key (lib.filter (row: !builtins.elem row.surface policyOnlySurfaces) rows)}); its row derives from the runtime record"; rows;
  expectedKeys = lib.concatMap (surface: lib.concatMap (ecosystem: map (mode: "${surface}/${ecosystem}/${mode}") modes) ecosystems) surfaces;
  validateRows = rows:
    assert lib.assertMsg (lib.all (row: lib.all validWriter (writersOf row)) rows) "ai-delivery: invalid row (primitive, reason, or inputOptions as key lists)";
    assert lib.assertMsg (lib.sort builtins.lessThan (map key rows) == lib.sort builtins.lessThan expectedKeys) "ai-delivery: rows must cover every surface/ecosystem in BOTH hm and devenv exactly once"; rows;
in {
  inherit ecosystems expectedKeys key keyedSurfaces modes sharedSurfaces validateHand validateRows writersOf;
}
