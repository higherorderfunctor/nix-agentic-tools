# Hand-authored vocabulary, writer schema and matrix partition contract.
{lib}: let
  ecosystems = import ../lib/ai/runtimes.nix;
  modes = ["devenv" "hm"];
  surfaces = ["agents" "context" "environmentVariables" "hooks" "lspServers" "mcpServers" "permissions" "rules" "settings" "skills"];
  # Pools whose root entries a runtime can withdraw one name at a time
  # (`ai.<runtime>.<pool>.<name> = null`). The others compose root and
  # per-runtime values, so a root request for them has no per-runtime remedy.
  keyedSurfaces = ["agents" "environmentVariables" "lspServers" "mcpServers" "rules" "skills"];
  primitives = ["notApplicable" "ownLeaves" "ownPathDeclarative" "ownPathManaged" "ownWrapper" "upstream"];
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
    && (!(builtins.elem writer.primitive ["notApplicable" "upstream"]) || nonBlank (writer.reason or ""))
    && (writer.primitive != "upstream" || nonBlank (writer.reverifyCommand or ""))
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
  expectedKeys = lib.concatMap (surface: lib.concatMap (ecosystem: map (mode: "${surface}/${ecosystem}/${mode}") modes) ecosystems) surfaces;
  validateRows = {
    derivedKeys,
    handKeys,
  }: rows:
    assert lib.assertMsg (lib.all (row: lib.all (field: builtins.hasAttr field row) ["ecosystem" "mode" "surface"]) rows) "ai-delivery: every row must declare surface, ecosystem, and mode";
    assert lib.assertMsg (lib.all (row: lib.all validWriter (writersOf row)) rows) "ai-delivery: incomplete or invalid writer (required fields, primitive, reason, reverifyCommand, probe, inputOptions as key lists, absentWriter, constantGate, declarationIndependent, or exemption)";
    assert lib.assertMsg (
      lib.sort builtins.lessThan (map key rows)
      == lib.sort builtins.lessThan expectedKeys
      && lib.sort builtins.lessThan (derivedKeys ++ handKeys) == lib.sort builtins.lessThan expectedKeys
      && lib.intersectLists derivedKeys handKeys == []
    ) "ai-delivery: derived and hand-authored rows must partition every surface/ecosystem in BOTH hm and devenv exactly once"; rows;
in {
  inherit ecosystems expectedKeys imperativePrimitives key keyedSurfaces modes primitives surfaces validateRows validWriter writersOf;
}
