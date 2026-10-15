# Runtime declarations are the only authority for normalized delivery support.
# An omitted surface is unsupported; a declared surface keeps its option tree
# on both backends, even when its writer exists on only one.
{lib}: {
  appRecord,
  backend,
  config,
  entries,
  message,
  nonEmpty,
  options,
  present,
  sharedSurfaces,
}: let
  runtime = appRecord.name;
  cfg = config.ai.${runtime};
  namespaces = import ./optionNamespaces.nix {inherit lib;};
  declarations = appRecord.surfaceSupport or {};
  supported = surface: (declarations.${surface}.backends or []) != [];
  defaultReason = "${runtime}'s surfaceSupport does not consume this shared surface.";
  # A runtime unit's path relative to `ai.<runtime>`, inside its namespace.
  runtimePath = surface: namespaces.pool appRecord surface ++ [surface];
  # Generated keyed folds have their own provenance; only consumer overrides
  # of an undelivered normalized pool need a second diagnostic unit.
  normalizedUnits = surface: let
    path = ["ai" runtime] ++ namespaces.pool appRecord surface ++ ["normalized" surface];
    option = lib.attrByPath path null options;
  in
    lib.optional (option
      != null
      && option.highestPrio < 1500
      && lib.any (definition: definition.file != toString ./mkBackendTransform.nix) option.definitionsWithLocations) {inherit path;};
  units = surface:
    [
      {
        path = ["ai" surface];
        root = true;
        value = config.ai.${surface};
      }
    ]
    ++ lib.optional (supported surface && lib.hasAttrByPath (runtimePath surface) cfg) {
      path = ["ai" runtime] ++ runtimePath surface;
      root = false;
      value = lib.getAttrFromPath (runtimePath surface) cfg;
    };
  gapWarnings = surface: gap: let
    candidates =
      if gap.each or false
      then entries surface
      else units surface;
    gapPath = gap.path or [];
    warnings = entry: let
      value = lib.attrByPath gapPath null entry.value;
      args =
        entry
        // {
          inherit backend cfg config value;
          entryValue = entry.value;
        };
      # Scalar overrides inherit on null. An effective gap diagnoses the
      # winning root/runtime input once, rather than both declarations.
      selected =
        !(gap.effective or false)
        || (!entry.root)
        == (lib.attrByPath (runtimePath surface ++ gapPath) null cfg != null);
      active =
        builtins.elem backend (gap.backends or ["devenv" "hm"])
        && (!(gap.rootOnly or false) || entry.root)
        && selected
        && (
          if gapPath == []
          then present entry.path
          else nonEmpty value
        )
        && (gap.when or (_: true)) args;
      reason =
        if builtins.isFunction gap.reason
        then gap.reason args
        else gap.reason;
    in
      lib.optional active (message (entry.path ++ gapPath) reason);
  in
    lib.concatMap warnings candidates;
  surfaceWarnings = surface: let
    declaration = declarations.${surface} or {};
    delivered = builtins.elem backend (declaration.backends or []);
  in
    if !delivered
    then
      lib.concatMap (unit:
        lib.optional (present unit.path)
        (message unit.path (declaration.reason or defaultReason))) (units surface ++ normalizedUnits surface)
    else lib.concatMap (gapWarnings surface) (declaration.gaps or []);
in {
  warnings = lib.concatMap surfaceWarnings sharedSurfaces;
}
