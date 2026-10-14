# Shared option vocabulary, writer schema and matrix partition contract.
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
  primitives = ["notApplicable" "ownLeaves" "ownPathDeclarative" "ownPathManaged" "ownWrapper"];
  imperativePrimitives = ["ownLeaves" "ownPathManaged"];
  key = row: "${row.surface}/${row.ecosystem}/${row.mode}";
  writersOf = row: [row] ++ lib.concatMap (writer: writersOf (writer // {inherit (row) ecosystem mode surface;})) (row.additionalWriters or []);
  nonBlank = value: builtins.isString value && builtins.match "[[:space:]]*" value == null;
  validWriter = writer:
    lib.all (field: builtins.hasAttr field writer) ["primitive" "pruneTrigger" "target" "writerAttr"]
    && builtins.elem writer.primitive primitives
    && nonBlank writer.pruneTrigger
    && builtins.isList writer.writerAttr
    && lib.all nonBlank writer.writerAttr
    && (
      if writer.primitive == "notApplicable"
      then writer.target == null && writer.writerAttr == []
      else nonBlank writer.target && writer.writerAttr != []
    )
    && (writer.primitive != "notApplicable" || nonBlank (writer.reason or ""))
    && (!(builtins.elem writer.primitive imperativePrimitives)
      || (
        writer ? probe
        && lib.all (field: builtins.hasAttr field writer.probe) ["base" "empty" "nonEmpty" "option"]
        && writer.probe.option != []
        && writer.probe.nonEmpty != writer.probe.empty
      ))
    && lib.all (path: builtins.isList path && path != [] && lib.all nonBlank path) (writer.inputOptions or [])
    && (!(writer ? absentWriter) || (nonBlank (writer.absentWriter.reason or "") && nonBlank (writer.absentWriter.evidence or "")))
    && !(writer ? absentWriter && writer ? exemption)
    && (!(writer ? constantGate) || nonBlank writer.constantGate)
    && (!(writer ? declarationIndependent) || nonBlank writer.declarationIndependent)
    && (!(writer ? exemption) || (nonBlank (writer.exemption.reason or "") && nonBlank (writer.exemption.evidence or "")));
  # A native writer can coexist with a normalized gap; a hand-authored
  # normalized absence or launcher claim cannot contradict its declaration.
  validateSupport = records: rows:
    map (row: let
      backends = records.${row.ecosystem}.surfaceSupport.${row.surface}.backends or [];
    in
      assert lib.assertMsg (!(builtins.elem row.surface sharedSurfaces)
        || (row.primitive != "notApplicable") == builtins.elem row.mode backends)
      "ai-delivery: hand row ${key row} (${row.primitive}) contradicts runtime record ${row.ecosystem}.surfaceSupport.${row.surface}.backends = ${builtins.toJSON backends}"; row)
    rows;
  expectedKeys = lib.concatMap (surface: lib.concatMap (ecosystem: map (mode: "${surface}/${ecosystem}/${mode}") modes) ecosystems) surfaces;
  validateRows = {
    derivedKeys,
    handKeys,
  }: rows:
    assert lib.assertMsg (lib.all (row: lib.all (field: builtins.hasAttr field row) ["ecosystem" "mode" "surface"]) rows) "ai-delivery: every row must declare surface, ecosystem, and mode";
    assert lib.assertMsg (lib.all (row: lib.all validWriter (writersOf row)) rows) "ai-delivery: incomplete or invalid writer (required fields, primitive, reason, probe, inputOptions as key lists, absentWriter, constantGate, declarationIndependent, or exemption)";
    assert lib.assertMsg (
      lib.sort builtins.lessThan (map key rows)
      == lib.sort builtins.lessThan expectedKeys
      && lib.sort builtins.lessThan (derivedKeys ++ handKeys) == lib.sort builtins.lessThan expectedKeys
      && lib.intersectLists derivedKeys handKeys == []
    ) "ai-delivery: derived and hand-authored rows must partition every surface/ecosystem in BOTH hm and devenv exactly once"; rows;
in {
  inherit ecosystems expectedKeys imperativePrimitives key keyedSurfaces modes primitives sharedSurfaces surfaces validateRows validateSupport validWriter writersOf;
}
